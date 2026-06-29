// InferenceEngine — wraps llama.cpp (CLlama, build 9430) for forward-from-caret
// token generation on Metal. Forward-only / prefix-growth hot path (FINDINGS Spike 1/2):
// never feed post-caret text; keep the cheap longest-prefix KV-cache path on SWA models.
//
// M0 — multi-sequence: the single llama_context now hosts multiple llama.cpp sequence IDs
// (cparams.n_seq_max). Ghost text owns seq 0 (preserved byte-identical to the pre-M0 path); the
// upcoming /v1 API + MCP path owns seq 1 (independent KV slot, so a long API prompt cannot evict
// the ghost-text prefix). State is tracked per seq (`cachedTokensBySeq` / `nPastBySeq`) and every
// batch we feed `llama_decode` now manually stamps the `seq_id` per token via `llama_batch_init`,
// replacing the legacy `llama_batch_get_one` (which is the seq-0 single-sequence helper). Per-call
// sampler configuration travels via `SamplingParams`; ghost callers pass `.ghostDefaults` which
// reproduces the pre-M0 hardcoded chain exactly.
import Foundation
import CLlama
import os
// INTEGRATOR-NOTE: CLlama fails to compile out of the box — llama.h does `#include "ggml.h"`,
// but ggml.h ships in the SEPARATE `ggml` Homebrew formula at /opt/homebrew/include, not in
// llama.cpp's includedir (pkg-config "llama" only emits -I.../llama.cpp/.../include). Add the
// ggml include path to the CLlama systemLibrary in Package.swift, e.g. cSettings/cxxSettings
// .unsafeFlags(["-I/opt/homebrew/include"]) or a -Xcc -I/opt/homebrew/include build flag.
// Verified: `swift build -Xcc -I/opt/homebrew/include` links the whole target cleanly.

enum InferenceError: Error, LocalizedError {
    case notLoaded
    case modelLoadFailed(String)
    case contextInitFailed
    case tokenizeFailed
    case decodeFailed(Int32)
    // M5: FIM (fill-in-middle) requires the model's three FIM tokens to bracket the prefix and
    // suffix; we can't silently front-trim that token stream when it exceeds n_ctx because the
    // dropped tokens would be fim_pre / fim_suf — framing the model was trained on. Routes catch
    // this and return HTTP 400 with a clear message instead of letting the model emit garbage.
    case fimContextOverflow(tokens: Int, cap: Int)

    var errorDescription: String? {
        switch self {
        case .notLoaded:                  return "No model is loaded."
        case .modelLoadFailed(let path):  return "llama failed to load the model file at \(path) — the GGUF may be corrupt or unsupported by this build."
        case .contextInitFailed:          return "llama failed to initialize the Metal context — the GPU/OS may not support this model's settings."
        case .tokenizeFailed:             return "Tokenization failed."
        case .decodeFailed(let code):     return "llama_decode failed (code \(code))."
        case .fimContextOverflow(let t, let cap): return "Context overflow: \(t) tokens exceed the \(cap)-token cap."
        }
    }
}

final class InferenceEngine: InferenceEngineProtocol {
    private(set) var isLoaded: Bool = false

    // llama.cpp handles (owned).
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?

    // GGUF `tokenizer.chat_template` populated on load (nil = no template, e.g. Base/pretrained
    // models). The /v1/chat/completions route consults this; ghost text never touches it.
    private(set) var modelChatTemplate: String? = nil

    // GGUF `general.architecture` (e.g. "gemma4"), read on load. Feeds ChatTemplate's built-in
    // fallback renderer when llama.cpp can't classify the model's baked-in Jinja template.
    private(set) var modelArchitecture: String? = nil

    // Whether /v1/chat/completions can actually render a prompt for this model — a dry-run of the
    // template (or an available architecture fallback), NOT mere template presence. Newer instruct
    // models ship Jinja templates llama.cpp's bare apply can't parse; advertising chat off presence
    // alone made /v1/models claim support, then 400 on the first request.
    private(set) var modelSupportsChat: Bool = false

    // M5 FIM: the three FIM token IDs (prefix / suffix / middle) when the loaded model is a
    // FIM-trained variant — Qwen-Coder, DeepSeek-Coder, CodeLlama, StarCoder all qualify. nil for
    // models without FIM training. /v1/completions consults this to gate the `suffix` field; the
    // ghost path doesn't (yet).
    struct FIMTokens: Equatable {
        let pre: Int32
        let suf: Int32
        let mid: Int32
    }
    private(set) var modelFIMTokens: FIMTokens? = nil
    var supportsFIM: Bool { modelFIMTokens != nil }

    // Tier 2b: control/chat-marker tokens to drop at sample time (logit = -inf) so scaffolding like
    // <|channel>, <|think|>, <start_of_turn>, <|assistant|>, ### Response can NEVER leak into the
    // visible ghost — structural, instead of scrubbing it post-hoc in TextSanitizer. Built once at
    // load: every CONTROL token EXCEPT the EOG stops (the decode loop needs those samplable to end
    // cleanly) and the FIM framing tokens (injected into the prompt, never to be re-emitted). Empty
    // for a clean base GGUF that exposes no such tokens → zero cost. Fed to a logit_bias sampler at
    // the head of the chain so top_k/top_p/temp only ever pick from displayable tokens.
    private(set) var maskedSpecialBias: [llama_logit_bias] = []

    // Pure (testable) Tier 2b policy: mask a token iff it is a SPECIAL token (CONTROL *or*
    // USER_DEFINED — the harmony reasoning markers <|channel>/<channel|> are USER_DEFINED, NOT
    // control, so is_control alone misses the main leak) that is NEITHER an EOG stop (the decode loop
    // must sample it to end cleanly) NOR a FIM framing token (injected into the prompt, never
    // re-emitted). Codifies the exemptions so a future change can't silently mask the stop (hangs
    // generation) or break FIM.
    static func shouldMaskSpecial(isSpecial: Bool, isEOG: Bool, isFIM: Bool) -> Bool {
        isSpecial && !isEOG && !isFIM
    }

    // Tier 2a: lazily-built flat table of every token's rendered bytes, for the required-prefix
    // (mid-word healing) sampler mask. off[i]..<off[i+1] are token i's bytes. ~1–2 MB; built once on
    // the first healed completion (a ~262k-token sweep), so normal generation never pays for it.
    private var tokenByteBuf: [UInt8] = []
    private var tokenByteOff: [Int32] = []
    private var tokenByteTableReady = false

    private func ensureTokenByteTable(nVocab: Int) {
        guard !tokenByteTableReady, let vocab else { return }
        var buf: [UInt8] = []; buf.reserveCapacity(nVocab * 4)
        var off: [Int32] = [0]; off.reserveCapacity(nVocab + 1)
        for t in 0..<nVocab { buf.append(contentsOf: tokenToPieceBytes(Int32(t), vocab: vocab)); off.append(Int32(buf.count)) }
        tokenByteBuf = buf; tokenByteOff = off; tokenByteTableReady = true
    }

    // Token `tok`'s bytes as a no-copy slice into the flat table. Empty when the table isn't built or
    // the id is out of range.
    private func tokenBytesSlice(_ tok: llama_token) -> ArraySlice<UInt8> {
        let i = Int(tok)
        guard i >= 0, i + 1 < tokenByteOff.count else { return [][...] }
        return tokenByteBuf[Int(tokenByteOff[i])..<Int(tokenByteOff[i + 1])]
    }

    private func tokenToPieceBytes(_ tok: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, tok, &buf, Int32(buf.count), 0, false)
        if n < 0 { buf = [CChar](repeating: 0, count: Int(-n)); n = llama_token_to_piece(vocab, tok, &buf, Int32(buf.count), 0, false) }
        guard n > 0 else { return [] }
        return (0..<Int(n)).map { UInt8(bitPattern: buf[$0]) }
    }

    // KV-cache reuse state (FR-CE-5), now keyed by llama.cpp sequence ID. `cachedTokensBySeq[seq]`
    // is the exact token stream currently committed to the KV cache for that seq, and
    // `nPastBySeq[seq]` is its length. generate() diffs the new prompt against the seq's cached
    // stream, trims the cache above the longest common prefix, and prefills only the diverging
    // suffix — the cheap prefix-growth path (Spike 1: ~65 ms warm vs ~180 ms cold). Both maps are
    // kept exactly in sync so a mid-prefill cancel leaves consistent state for the next call.
    //
    // Seq 0 is the ghost-text seq (CompletionCoordinator); seq 1 is the API/MCP seq. Both share
    // the same `model` (read-only after load) but have independent KV state, so a multi-thousand-
    // token API prompt does not evict the ghost prefix.
    private var cachedTokensBySeq: [Int32: [llama_token]] = [:]
    private var nPastBySeq: [Int32: Int32] = [:]

    // Cooperative cancel (FR-CE-4). Written by the coordinator (any thread), polled on chunk
    // boundaries in generate(). Guarded by os_unfair_lock so the cross-thread read/write isn't a data
    // race (benign on arm64 but UB unsynchronized). A single flag is shared across seqs because the
    // inferenceQueue is serial — only one generate is ever in flight at a time. The computed property
    // keeps every call site (`cancelRequested = …`, `if cancelRequested`) unchanged.
    private var _cancelLock = os_unfair_lock_s()
    private var _cancelRequested = false
    private var cancelRequested: Bool {
        get { os_unfair_lock_lock(&_cancelLock); defer { os_unfair_lock_unlock(&_cancelLock) }; return _cancelRequested }
        set { os_unfair_lock_lock(&_cancelLock); defer { os_unfair_lock_unlock(&_cancelLock) }; _cancelRequested = newValue }
    }

    // Tunables.
    private let contextSize: UInt32 = 4096
    private let batchSize: UInt32 = 512
    private let maxSeqCount: Int32 = 4   // ghost (0) + API (1) + headroom; cparams.n_seq_max
    private let prefillChunk: Int = 48   // tokens per prefill batch; cancel is checked between chunks (FR-CE-4)

    // Set to true via env SHADOWTYPE_GREEDY to force deterministic greedy sampling across both
    // ghost and API paths regardless of `SamplingParams.greedy`.
    private let useGreedyEnv = ProcessInfo.processInfo.environment["SHADOWTYPE_GREEDY"] != nil

    // Stop policy (Option 2): the old behaviour stopped at the FIRST sentence-ending punctuation,
    // which left most suggestions a single fragment. Default now runs on to a useful clause/phrase,
    // bounded by `maxWords` (and still by maxTokens/EOG/newline/onToken). Flip stopAtFirstSentence
    // back to true to restore the legacy "first sentence only" behaviour. These are consulted only
    // by the ghost path (params.useEngineStopPolicy == true).
    var stopAtFirstSentence = false
    var maxWords = 12

    // Soft sentence-aware stop (FR-CE-3, paired with the longer CompletionLength presets). Once this
    // many words have been emitted, the stream ends at the NEXT sentence boundary (`. ! ?`) instead of
    // running to the hard `maxWords` cap — so a long completion finishes a clause cleanly rather than
    // truncating mid-sentence. 0 disables it (the default; short/medium presets keep the legacy
    // word-cap-only behaviour). Set by AppDelegate.applyCompletionLength from the active preset.
    var stopAtSentenceAfterWords = 0

    // Context → "Context window size": the most recent prompt tokens fed to the model. Defaults to the
    // full context (`contextSize`); a smaller value front-trims the prompt to its last N tokens before
    // prefill, trading recall for memory/latency. Always clamped to the live n_ctx in generate().
    // Mirrored from @AppStorage by AppDelegate.syncToggles.
    var maxContextTokens: Int = 4096

    init() {}

    deinit { unload() }

    func load(modelPath: String) throws {
        guard !isLoaded else { return }

        // ggml loads its compute backends (Metal/CPU/BLAS) as runtime plugins, searching a path baked
        // into libggml at build time (the dev's Homebrew Cellar). A distributed .app has no such path,
        // so without this it logs "no backends are loaded" and every model load fails. Load the backend
        // .so's we bundle in Contents/Frameworks (see make-app.sh) from that directory. NOTE: the
        // GGML_BACKEND_PATH env var is dlopen()'d as a single FILE — pointing it at the Frameworks
        // DIRECTORY fails with "not a file" and loads nothing (issue #3). ggml_backend_load_all_from_path
        // enumerates the dir and loads each backend by name. Dev builds (`swift run`, no .app bundle)
        // lack the bundled backends and keep the working Homebrew Cellar fallback.
        if let fw = Bundle.main.privateFrameworksPath,
           FileManager.default.fileExists(atPath: fw + "/libggml-metal.so") {
            ggml_backend_load_all_from_path(fw)
        }

        llama_backend_init()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 999   // all layers on Metal

        guard let m = llama_model_load_from_file(modelPath, mparams) else {
            throw InferenceError.modelLoadFailed(modelPath)
        }
        self.model = m
        self.vocab = .init(llama_model_get_vocab(m))

        var cparams = llama_context_default_params()
        cparams.n_ctx = contextSize
        cparams.n_batch = batchSize
        // Multi-seq context: ghost on seq 0, API/MCP on seq 1. Headroom in case future surfaces
        // (a second API client, a parallel embedding job) want their own KV slot too. The header
        // recommends swa_full=true with n_seq_max > 1 to avoid SWA performance cliffs.
        cparams.n_seq_max = UInt32(maxSeqCount)
        cparams.swa_full = true
        // kv_unified=true shares ONE n_ctx-sized buffer across all sequences. With the default (false)
        // llama partitions n_ctx across n_seq_max, so the ghost seq only gets n_ctx/maxSeqCount (~1024
        // tokens at 4096/4): a long page-context + prefix prompt (e.g. a multi-paragraph Reddit/forum
        // post) overflows the partition and `llama_decode` returns 1 (no KV slot) — the ghost silently
        // dies on exactly the long-prose case it's most wanted. Unify so the ghost can use the full
        // window; ghost (0) and the occasional API/MCP seq (1) rarely both run near-full at once.
        cparams.kv_unified = true
        // Flash Attention speeds the prefill of long prefixes (the page-context / thread-aware case) on
        // Metal. AUTO enables it whenever the model+backend support it and is a safe no-op otherwise —
        // we set it explicitly rather than relying on the default so the intent is recorded.
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO

        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            self.model = nil
            throw InferenceError.contextInitFailed
        }
        self.ctx = c

        // Read the model's chat template (if any) once, while we still have a stable model handle.
        // Nil for raw/Base GGUFs; populated for instruct variants that ship a template in their
        // metadata. /v1/chat/completions reads this; ghost text doesn't.
        self.modelChatTemplate = ChatTemplate.read(model: m)
        self.modelArchitecture = ChatTemplate.readArchitecture(model: m)
        self.modelSupportsChat = self.modelChatTemplate.map {
            ChatTemplate.canApply(template: $0, architecture: self.modelArchitecture)
        } ?? false

        // M5 FIM: probe for fill-in-middle tokens. llama.cpp's vocab accessors return
        // LLAMA_TOKEN_NULL (-1) for models that don't expose them; we require all three (pre/suf/
        // mid) to be present before declaring FIM support — having `pre` without `suf` would be a
        // half-broken model and not worth special-casing.
        if let v = self.vocab {
            let pre = llama_vocab_fim_pre(v)
            let suf = llama_vocab_fim_suf(v)
            let mid = llama_vocab_fim_mid(v)
            if pre >= 0 && suf >= 0 && mid >= 0 {
                self.modelFIMTokens = FIMTokens(pre: pre, suf: suf, mid: mid)
            } else {
                self.modelFIMTokens = nil
            }
        }

        // Tier 2b: classify control tokens to mask at sample time (see maskedSpecialBias). One pass at
        // load. Skip EOG (the decode loop needs it to stop) and the FIM framing tokens (prompt-only).
        if let v = self.vocab {
            let n = llama_vocab_n_tokens(v)
            let fim = self.modelFIMTokens
            var bias: [llama_logit_bias] = []
            let controlBit = LLAMA_TOKEN_ATTR_CONTROL.rawValue
            let userBit = LLAMA_TOKEN_ATTR_USER_DEFINED.rawValue
            for id in Int32(0)..<n {
                let attr = llama_vocab_get_attr(v, id).rawValue
                let isSpecial = (attr & controlBit) != 0 || (attr & userBit) != 0
                let isFIM = fim.map { id == $0.pre || id == $0.suf || id == $0.mid } ?? false
                guard Self.shouldMaskSpecial(isSpecial: isSpecial,
                                             isEOG: llama_vocab_is_eog(v, id), isFIM: isFIM) else { continue }
                bias.append(llama_logit_bias(token: id, bias: -Float.infinity))
            }
            self.maskedSpecialBias = bias
        }

        // FR-CE-8: confirm the Metal backend initialised. llama.cpp logs "ggml_metal_init: ..."
        // to stderr during model load; this line ties that to our context so it's greppable.
        NSLog("Shadowtype: InferenceEngine loaded model (Metal, n_gpu_layers=999, n_ctx=\(llama_n_ctx(c)), n_seq_max=\(maxSeqCount), arch=\(modelArchitecture ?? "?"), chatTemplate=\(modelChatTemplate != nil ? "yes" : "no"), supportsChat=\(modelSupportsChat), fim=\(modelFIMTokens != nil ? "yes" : "no"), maskedControl=\(maskedSpecialBias.count))")

        self.cachedTokensBySeq.removeAll(keepingCapacity: false)
        self.nPastBySeq.removeAll(keepingCapacity: false)
        self.cancelRequested = false
        isLoaded = true
    }

    // INTEGRATOR-NOTE: CompletionCoordinator should call requestCancel() before issuing a new
    // generate() (debounce/keystroke supersede) and reset() is implied at the start of generate().
    // This is the cooperative-cancel hook for FR-CE-4; generate() itself also stops when onToken
    // returns false, so a synchronous caller can cancel purely via the closure.
    func requestCancel() {
        cancelRequested = true
    }

    // `onSample`, when provided, is invoked once per sampled CONTENT token (a token whose decoded
    // piece carries a visible, non-whitespace character), on the engine's inference thread, BEFORE that
    // token's word(s) are flushed via `onToken`. It reports the token's post-sampler probability and
    // whether it is the FIRST content token of this generation. The coordinator uses this for confidence
    // gating (suppress low-probability/flailing completions) — decoupled from word-flush boundaries so a
    // multi-token word doesn't smear the per-token signal.
    //
    // `seqID` selects which llama.cpp sequence this call belongs to (ghost = 0, API = 1). `params`
    // configures the sampler chain + stop policy. When `params.useEngineStopPolicy` is true the
    // legacy ghost decode loop runs (word buffering, sentence stops, maxWords); when false the raw
    // API decode loop runs (verbatim piece stream, stop-string scan, maxTokens-only termination).
    func generate(prompt: String, maxTokens: Int,
                  seqID: Int32 = 0,
                  params: SamplingParams = .ghostDefaults,
                  requiredPrefix: [UInt8]? = nil,
                  onToken: (String) -> Bool,
                  onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)? = nil) throws {
        guard isLoaded, let ctx, let vocab else { throw InferenceError.notLoaded }
        cancelRequested = false

        // --- Tokenize prompt -------------------------------------------------------------------
        // M5 FIM: when the caller passed a `fim` payload AND the loaded model exposes FIM tokens
        // (Qwen-Coder / DeepSeek-Coder / CodeLlama / StarCoder family), build a hand-assembled
        // token stream `[fim_pre, ...prefix, fim_suf, ...suffix, fim_mid]` instead of tokenizing
        // `prompt` verbatim. `prompt` is ignored in this branch — the API caller has already
        // moved its content into `fim.prefix`. A request with `fim` set but no FIM-capable model
        // throws so the API layer can return HTTP 400 with a clear message.
        var tokens: [llama_token]
        if let fim = params.fim {
            guard let fimToks = modelFIMTokens else {
                throw InferenceError.tokenizeFailed   // surfaced as 500 by API; routes pre-check supportsFIM
            }
            // Tokenize prefix + suffix WITHOUT BOS — the fim_pre token is the de-facto BOS in
            // FIM-trained models, and a duplicate BOS at position 0 breaks the encoding the model
            // saw at training time.
            let prefixToks = try tokenize(fim.prefix, addSpecial: false)
            let suffixToks = try tokenize(fim.suffix, addSpecial: false)
            tokens = [fimToks.pre]
            tokens.append(contentsOf: prefixToks)
            tokens.append(fimToks.suf)
            tokens.append(contentsOf: suffixToks)
            tokens.append(fimToks.mid)
        } else {
            tokens = try tokenize(prompt, addSpecial: true)
        }
        guard !tokens.isEmpty else { return }
        let nCtx = Int(llama_n_ctx(ctx))
        // Cap at the live context minus head-room, and further at the user's configured window. The
        // head-room is NOT cosmetic: the ghost decodes its generated tokens into THIS same seq's KV
        // after prefill, and with kv_unified the API/MCP seq shares the same n_ctx pool — so a prompt
        // filling to nCtx-4 leaves no room to generate (or for a co-resident seq) and llama_decode
        // returns 1 mid-stream. Reserve a generation+co-seq margin so a long prompt front-trims
        // gracefully instead of silently failing. (genReserve >> max ghost output of ~tens of tokens.)
        let genReserve = 256
        let cap = max(8, min(nCtx - genReserve, maxContextTokens))
        if tokens.count > cap {
            // M5 review #2: refuse to truncate when the prompt is a FIM token stream — front-trim
            // drops `fim_pre` first (and on tighter caps `fim_suf`), leaving the model with framing
            // it was never trained on. The API layer surfaces this as HTTP 400 with a hint to
            // shorten prefix or suffix. The non-FIM raw-prompt path tolerates front-trim because
            // a raw prompt has no positional invariants — keep the most-recent-context strategy
            // there (FINDINGS §cold; the deadline-drop hides the cold-prefill cost).
            if params.fim != nil {
                throw InferenceError.fimContextOverflow(tokens: tokens.count, cap: cap)
            }
            tokens = Array(tokens.suffix(cap))
        }

        // Per-seq cached stream + KV length. First call on a seq starts empty. The defer below
        // writes back to the per-seq dict on ANY exit (normal return, cancel-return, thrown
        // decodeFailed) so cachedTokensBySeq + nPastBySeq always describe the EXACT live KV
        // contents. Pre-fix, only the happy-path tail wrote back; a decode throw inside
        // ghostDecodeLoop / apiDecodeLoop reverted the dict to the pre-call state while the KV
        // already held the prefill tokens, producing position collisions on the next call.
        var cached = cachedTokensBySeq[seqID] ?? []
        var nPast = nPastBySeq[seqID] ?? 0
        defer {
            cachedTokensBySeq[seqID] = cached
            nPastBySeq[seqID] = nPast
        }

        // --- KV-cache reuse (FR-CE-5, the biggest latency lever) -------------------------------
        // Keep the longest common prefix already committed to the seq's KV cache; trim everything
        // above it and prefill only the divergent suffix. The common case (user keeps typing)
        // reuses the whole prior prefix and prefills ~2-3 tokens -> the warm ~65 ms path (Spike 1).
        let reuse = Self.reuseLength(cached: cached, new: tokens)
        if reuse < cached.count {
            let mem = llama_get_memory(ctx)
            if reuse == 0 {
                resetSeq(seqID, in: mem)
                cached = []
                nPast = 0
            } else if llama_memory_seq_rm(mem, seqID, Int32(reuse), -1) {
                cached.removeLast(cached.count - reuse)
                nPast = Int32(reuse)
            } else {
                // seq_rm returns false when a partial SWA tail can't be removed (the window has
                // rotated past `reuse`, FINDINGS Spike 5). Fall back to a clean cold prefill.
                resetSeq(seqID, in: mem)
                cached = []
                nPast = 0
            }
        }
        // else: strict extension — nothing to trim, the cache stays warm.

        // --- Chunked prefill of ONLY the divergent suffix (FR-CE-4: cancel between chunks) ------
        // Allocate a single batch buffer big enough for the largest chunk (prefillChunk) AND the
        // single-token decode that follows. Reuse it across iterations to avoid per-token allocs.
        // n_seq_max=1 here is the per-token "max seq IDs" — each of our tokens belongs to exactly
        // one seq (the `seqID` passed in), distinct from cparams.n_seq_max which is per-context.
        let batchCap = max(prefillChunk, 1)
        var batch = llama_batch_init(Int32(batchCap), 0, 1)
        defer { llama_batch_free(batch) }

        // Append to cached as each chunk commits so nPast/cached always describe the exact KV
        // contents; a mid-prefill cancel then leaves consistent state for the next call.
        var i = cached.count
        while i < tokens.count {
            if cancelRequested { return }   // defer above flushes cached/nPast on return
            let end = min(i + prefillChunk, tokens.count)
            let chunkLen = end - i
            // Fill the batch in place — token, position, seq stamp, logits flag for last token.
            for k in 0..<chunkLen {
                batch.token[k] = tokens[i + k]
                batch.pos[k] = nPast + Int32(k)
                batch.n_seq_id[k] = 1
                batch.seq_id[k]![0] = seqID
                batch.logits[k] = (k == chunkLen - 1) ? 1 : 0
            }
            batch.n_tokens = Int32(chunkLen)
            let rc = llama_decode(ctx, batch)
            if rc != 0 { throw InferenceError.decodeFailed(rc) }   // defer flushes the prefill we got through
            cached.append(contentsOf: tokens[i..<end])
            nPast += Int32(chunkLen)
            i = end
        }

        // --- Sampler chain (built from params; matches the pre-M0 hardcoded chain for ghost) ----
        let sparams = llama_sampler_chain_default_params()
        guard let smpl = llama_sampler_chain_init(sparams) else { return }   // defer flushes
        defer { llama_sampler_free(smpl) }
        // Tier 2b: drop control/chat-marker tokens before any other sampler sees them (structural
        // anti-leak; see maskedSpecialBias). FIRST in the chain — applies in BOTH the greedy and the
        // sampled paths — so top_k/top_p/temp pick only from displayable tokens. The sampler copies the
        // bias array, so the transient pointer is safe. No-op when empty (clean base GGUF).
        if !maskedSpecialBias.isEmpty {
            maskedSpecialBias.withUnsafeBufferPointer { buf in
                llama_sampler_chain_add(smpl, llama_sampler_init_logit_bias(
                    llama_vocab_n_tokens(vocab), Int32(buf.count), buf.baseAddress))
            }
        }
        if useGreedyEnv || params.greedy {
            llama_sampler_chain_add(smpl, llama_sampler_init_greedy())
        } else {
            // top_k (skip when <= 0 / very high — top_p alone is then the candidate gate).
            if params.topK > 0 {
                llama_sampler_chain_add(smpl, llama_sampler_init_top_k(params.topK))
            }
            // Repetition penalty (skip when == 1.0, the neutral value, to save a candidate scan).
            if params.repeatPenalty != 1.0 || params.repeatPenaltyLastN > 0 {
                llama_sampler_chain_add(smpl, llama_sampler_init_penalties(
                    params.repeatPenaltyLastN, params.repeatPenalty, 0.0, 0.0))
            }
            // top_p (skip when >= 1.0 since it would keep everything anyway).
            if params.topP < 1.0 {
                llama_sampler_chain_add(smpl, llama_sampler_init_top_p(params.topP, 1))
            }
            llama_sampler_chain_add(smpl, llama_sampler_init_temp(params.temperature))
            llama_sampler_chain_add(smpl, llama_sampler_init_dist(params.seed))
        }

        // --- Decode loop ------------------------------------------------------------------------
        // Reusable candidate buffer for manual sample-with-probability (avoids a per-token vocab-sized
        // alloc; the decode budget is tiny — maxTokens). `cur.data` is modified in place by the chain.
        let nVocab = Int(llama_vocab_n_tokens(vocab))
        var cand = [llama_token_data](repeating: llama_token_data(id: 0, logit: 0, p: 0), count: nVocab)

        if params.useEngineStopPolicy {
            // Tier 2a: build the byte table once before a healed (required-prefix) completion.
            if let rp = requiredPrefix, !rp.isEmpty { ensureTokenByteTable(nVocab: nVocab) }
            try ghostDecodeLoop(ctx: ctx, vocab: vocab, smpl: smpl, batch: &batch,
                                seqID: seqID, maxTokens: maxTokens,
                                cached: &cached, nPast: &nPast,
                                nVocab: nVocab, cand: &cand,
                                requiredPrefix: requiredPrefix,
                                onToken: onToken, onSample: onSample)
        } else {
            try apiDecodeLoop(ctx: ctx, vocab: vocab, smpl: smpl, batch: &batch,
                              seqID: seqID, maxTokens: maxTokens,
                              stops: params.stopStrings,
                              cached: &cached, nPast: &nPast,
                              nVocab: nVocab, cand: &cand,
                              onToken: onToken, onSample: onSample)
        }
        // No explicit writeback here — the defer at function entry handles it on every exit
        // path (normal completion, decode-loop throw, cancel-return, sampler-init failure).
    }

    // Ghost decode loop — preserves the pre-M0 behaviour exactly: word buffering, leading-newline
    // strip, sentence-aware stops, maxWords cap, confidence-prob reporting per content token.
    private func ghostDecodeLoop(ctx: OpaquePointer, vocab: OpaquePointer,
                                 smpl: UnsafeMutablePointer<llama_sampler>,
                                 batch: inout llama_batch,
                                 seqID: Int32, maxTokens: Int,
                                 cached: inout [llama_token], nPast: inout Int32,
                                 nVocab: Int, cand: inout [llama_token_data],
                                 requiredPrefix: [UInt8]? = nil,
                                 onToken: (String) -> Bool,
                                 onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)?) throws {
        // Tier 2a: bytes the model must still reproduce before its output becomes the ghost (mid-word
        // healing). While non-empty, the sampler is constrained to prefix-compatible tokens and the
        // consumed stem bytes are stripped from each emitted piece. Empty → behaviour is byte-identical
        // to the pre-2a path.
        var remaining: [UInt8] = requiredPrefix ?? []
        // Stream incrementally, but hold back the trailing in-progress word in `pending` so a hard
        // stop (maxTokens / cap) can drop a partial fragment and the ghost ends on a whole word
        // (FR-CE-3). A whitespace in a freshly decoded piece closes off whatever was pending, which
        // is then safe to flush. On a clean stop (newline / EOG / sentence boundary) we flush
        // `pending` verbatim because it is a complete unit up to that boundary.
        var emitted = 0
        var sawNonSpace = false   // suppress leading-whitespace-only output and never stop on a leading boundary char
        var flushedAny = false    // did this run hand the consumer any whole word yet?
        var wordCount = 0         // completed words flushed so far (a leading-space piece opens a new word)
        var pending = ""          // un-flushed trailing fragment (the possibly-incomplete current word)

        // Flush every settled word in `pending` (text up to and including each interior whitespace),
        // one whitespace-delimited chunk per onToken call so streaming stays incremental (the
        // consumer sees the ghost grow word-by-word, as before). Holds back only the trailing
        // (possibly-incomplete) word, which a hard stop will drop. Returns false on consumer cancel.
        func flushCompleteWords() -> Bool {
            guard sawNonSpace else { return true }   // don't emit leading-whitespace-only output
            while let firstSpace = pending.firstIndex(where: { $0.isWhitespace }) {
                let head = String(pending[...firstSpace])
                pending = String(pending[pending.index(after: firstSpace)...])
                if !head.isEmpty {
                    flushedAny = true
                    if !onToken(head) { return false }
                }
            }
            return true
        }

        while emitted < maxTokens {
            if cancelRequested { return }

            // Manual sample = apply(chain) + read the step's CONFIDENCE (peak prob) + accept ONCE. (The
            // llama_sampler_sample() shorthand already accepts internally, so the old extra accept here
            // was a double-accept; this path also exposes the peak probability for the confidence gate.)
            let (tok, confProb) = sampleWithProb(ctx: ctx, smpl: smpl, nVocab: nVocab, cand: &cand,
                                                 requiredRemaining: remaining[...])
            if llama_vocab_is_eog(vocab, tok) {            // clean stop: flush the trailing word too
                let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { _ = onToken(pending) }
                return
            }
            llama_sampler_accept(smpl, tok)
            let tokProb = (useGreedyEnv ? 1.0 : confProb)
            let hadContentBefore = sawNonSpace

            var piece = tokenToPiece(tok)
            // Tier 2a: consume the still-pending stem bytes from this token; only the post-stem text
            // flows into the ghost. The token is still decoded below so the KV cache advances. Byte
            // level so a multibyte char split across tokens consumes correctly; the post-stem remainder
            // begins on a char boundary (the stem is whole characters), so decoding it is always valid.
            if !remaining.isEmpty {
                let tb = tokenBytesSlice(tok)
                let consumed = min(tb.count, remaining.count)
                remaining = RequiredPrefix.advanced(remaining: remaining, byEmitting: tb)
                let post = tb.dropFirst(consumed)
                piece = post.isEmpty ? "" : String(decoding: Array(post), as: UTF8.self)
            }
            if !piece.isEmpty {
                // A new word starts whenever a piece opens with whitespace after we've seen content.
                if sawNonSpace, let first = piece.first, first.isWhitespace { wordCount += 1 }

                // Newline handling. A line break AFTER real content is a clean stop (end the ghost on
                // the line). But a LEADING newline — before any content has been emitted — is the
                // instruct model's "answer starts on a new line" habit; stopping there would emit an
                // empty ghost (the M2 "produces nothing" symptom on complete-looking prefixes). So
                // strip the leading newline(s)/whitespace and keep generating instead of stopping.
                if let nl = piece.firstIndex(where: { $0 == "\n" }) {
                    if sawNonSpace {
                        pending += piece[..<nl]
                        let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !tail.isEmpty { _ = onToken(pending) }
                        return
                    }
                    // Leading newline: drop it and fall through (the token is still decoded below so
                    // the KV cache advances; an all-whitespace piece becomes empty and no-ops cleanly).
                    piece = String(piece.drop(while: { $0.isWhitespace }))
                }

                // Sentence boundary: legacy "first sentence" mode stops here, including the punct.
                // Tier 1: context-aware, multilingual judge (decimals/abbrev/initials/non-Latin) — see
                // SentenceBoundary. `pending` is the before-context (the current word back to the last
                // whitespace) so "Mr." / "3.14" / "J." are disambiguated. Guarded by sawNonSpace so a
                // leading boundary never stops on an empty ghost.
                if stopAtFirstSentence, sawNonSpace,
                   let stopIdx = SentenceBoundary.firstStopIndex(in: piece, before: pending) {
                    pending += piece[...stopIdx]
                    let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tail.isEmpty { _ = onToken(pending) }
                    return
                }

                // Soft sentence-aware stop (longer presets): once enough words are out, end on the next
                // sentence boundary INCLUDING the punct, so the completion finishes a clause rather than
                // truncating at the hard word cap. Disabled when stopAtSentenceAfterWords == 0.
                if stopAtSentenceAfterWords > 0, wordCount >= stopAtSentenceAfterWords, sawNonSpace,
                   let stopIdx = SentenceBoundary.firstStopIndex(in: piece, before: pending) {
                    pending += piece[...stopIdx]
                    let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tail.isEmpty { _ = onToken(pending) }
                    return
                }

                pending += piece
                if piece.contains(where: { !$0.isWhitespace }) {
                    // Strip only leading NEWLINES/tabs (the instruct "answer on a new line" habit) before
                    // the first content — but KEEP a leading SPACE: it's the word separator the model
                    // emits (SentencePiece "▁word"), and dropping it glued the accepted word onto the
                    // prefix ("we" + "should" -> "weshould"). The coordinator reconciles it against the
                    // prefix so a prefix already ending in a space doesn't double up.
                    if !sawNonSpace {
                        pending = String(pending.drop(while: { $0 == "\n" || $0 == "\r" || $0 == "\t" }))
                    }
                    sawNonSpace = true
                }
                // Report the probability of every content-bearing token BEFORE flushing its word(s), so a
                // confidence gate can suppress before the first render. `isFirstContent` marks the token
                // that first produced visible output.
                if piece.contains(where: { !$0.isWhitespace }) {
                    onSample?(tokProb, !hadContentBefore)
                }
                if !flushCompleteWords() { return }   // cooperative cancel via closure (FR-CE-4)
            }

            // Word cap: stop once we've produced a useful clause; drop the trailing partial word.
            if sawNonSpace && wordCount >= maxWords { return }

            // Advance the KV cache by the just-sampled token (manual batch stamps seq).
            batch.token[0] = tok
            batch.pos[0] = nPast
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = seqID
            batch.logits[0] = 1
            batch.n_tokens = 1
            let rc = llama_decode(ctx, batch)
            if rc != 0 { throw InferenceError.decodeFailed(rc) }
            nPast += 1
            cached.append(tok)
            emitted += 1
        }
        // maxTokens reached: normally drop the trailing partial word so the ghost ends cleanly. But
        // if the whole budget produced a single un-flushed word (no interior whitespace), dropping it
        // would emit nothing and stall a caller that chains generate() forward-from-caret — so flush
        // it as a fallback to guarantee forward progress.
        if !flushedAny {
            let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { _ = onToken(pending) }
        }
    }

    // API/MCP decode loop — raw token-piece stream, no word buffering or sentence stops. Honors
    // maxTokens, EOG, cooperative cancel via onToken, and `stops` (substrings; first complete
    // match in the accumulated stream halts the generation, with the matching substring and any
    // text after it NOT emitted).
    //
    // Stop-string handling caveat: a stop string that spans across two tokens may have its leading
    // bytes already emitted before the match is detected (we scan AFTER each piece appends).
    // For M0 this is acceptable; clients see a slightly-truncated extra prefix of the stop. M1
    // can add a lookback buffer (hold back `max(stopLen) - 1` chars) if it becomes a real issue.
    private func apiDecodeLoop(ctx: OpaquePointer, vocab: OpaquePointer,
                               smpl: UnsafeMutablePointer<llama_sampler>,
                               batch: inout llama_batch,
                               seqID: Int32, maxTokens: Int,
                               stops: [String],
                               cached: inout [llama_token], nPast: inout Int32,
                               nVocab: Int, cand: inout [llama_token_data],
                               onToken: (String) -> Bool,
                               onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)?) throws {
        var emitted = 0
        var firstContentReported = false
        // A stop string can span several tokens (gemma emits "<end_of_turn>" as "<","end_of_turn",">")
        // and onToken can't be retracted, so StreamStopFilter holds back the last (maxStopLen-1) chars
        // until they're proven not to begin a stop. See its definition for the holdback rationale.
        var stopFilter = StreamStopFilter(stops: stops)

        while emitted < maxTokens {
            if cancelRequested { return }

            let (tok, confProb) = sampleWithProb(ctx: ctx, smpl: smpl, nVocab: nVocab, cand: &cand)
            if llama_vocab_is_eog(vocab, tok) {
                let tail = stopFilter.finish()
                if !tail.isEmpty { _ = onToken(tail) }
                return
            }
            llama_sampler_accept(smpl, tok)

            let piece = tokenToPiece(tok)
            if !piece.isEmpty {
                onSample?(useGreedyEnv ? 1.0 : confProb, !firstContentReported)
                firstContentReported = true
                let (chunk, stopped) = stopFilter.push(piece)
                if !chunk.isEmpty, !onToken(chunk) { return }
                if stopped { return }
            }

            // Advance the KV cache by the just-sampled token (manual batch stamps seq).
            batch.token[0] = tok
            batch.pos[0] = nPast
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = seqID
            batch.logits[0] = 1
            batch.n_tokens = 1
            let rc = llama_decode(ctx, batch)
            if rc != 0 { throw InferenceError.decodeFailed(rc) }
            nPast += 1
            cached.append(tok)
            emitted += 1
        }
        // maxTokens reached without a stop/EOG: release the held-back tail (it never began a stop).
        let tail = stopFilter.finish()
        if !tail.isEmpty { _ = onToken(tail) }
    }

    func unload() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil
        model = nil
        vocab = nil
        modelChatTemplate = nil
        modelArchitecture = nil
        modelSupportsChat = false
        modelFIMTokens = nil
        cachedTokensBySeq.removeAll(keepingCapacity: false)
        nPastBySeq.removeAll(keepingCapacity: false)
        isLoaded = false
    }

    // MARK: - KV-cache helpers (FR-CE-5)

    // Full reset for one seq: drop its entire KV cache. Used for a cold prefill and as the fallback
    // when a partial SWA trim is refused (see generate()). Partial reuse instead trims only above
    // the common prefix: llama_memory_seq_rm(mem, seqID, reuseLength, -1).
    private func resetSeq(_ seqID: Int32, in memory: OpaquePointer?) {
        guard let memory else { return }
        _ = llama_memory_seq_rm(memory, seqID, 0, -1)
    }

    // How many leading tokens of `new` are already committed to the KV cache holding `cached` —
    // the longest common prefix, but never the entire `new` stream: we keep at most new.count-1 so
    // the final token is always (re)evaluated to produce fresh sampling logits even when the prompt
    // is otherwise unchanged. Forward-only (FINDINGS Spike 1/2): a strict extension keeps the whole
    // prior prefix; any divergence or backspace-shrink trims back to the branch point.
    // llama_token is a typealias for Int32; the parameter is spelled Int32 so this stays callable
    // from the test target without importing CLlama.
    static func reuseLength(cached: [Int32], new: [Int32]) -> Int {
        guard !new.isEmpty else { return 0 }
        let maxKeep = new.count - 1
        var i = 0
        while i < cached.count, i < maxKeep, cached[i] == new[i] { i += 1 }
        return i
    }

    // First stop-string occurrence in `s` across any of `stops`. Returns the index of the EARLIEST
    // match (the one nearest the start), so a stop that appears later is ignored in favor of an
    // earlier one. Returns nil when no stop is present.
    static func firstStopMatch(in s: String, stops: [String]) -> String.Index? {
        var earliest: String.Index? = nil
        for stop in stops where !stop.isEmpty {
            if let r = s.range(of: stop) {
                if let e = earliest {
                    if r.lowerBound < e { earliest = r.lowerBound }
                } else {
                    earliest = r.lowerBound
                }
            }
        }
        return earliest
    }

    // Streaming stop-string filter for the API decode loop. A stop string can span several tokens
    // (gemma emits "<end_of_turn>" as "<", "end_of_turn", ">"), and an emitted piece cannot be
    // retracted — so we hold back the last (maxStopLen-1) chars of the running output until they're
    // proven not to begin a stop. `push` returns the chunk safe to emit now plus whether a stop hit;
    // `finish` releases the held tail at a clean end (EOG / maxTokens). Pure + testable: no model.
    struct StreamStopFilter {
        private let stops: [String]
        private let maxStopLen: Int
        private var acc = ""          // all chars seen (the stop-scan window)
        private var emitted = 0       // chars already returned to the caller

        init(stops: [String]) {
            self.stops = stops.filter { !$0.isEmpty }
            self.maxStopLen = self.stops.map { $0.count }.max() ?? 0
        }

        // Feed one decoded piece. Returns (chunkToEmitNow, stopped). When stopped is true the stop
        // string (and anything after) has been dropped and the loop should end.
        mutating func push(_ piece: String) -> (chunk: String, stopped: Bool) {
            let tentative = acc + piece
            if let stopStart = InferenceEngine.firstStopMatch(in: tentative, stops: stops) {
                let off = tentative.distance(from: tentative.startIndex, to: stopStart)
                acc = String(tentative.prefix(off))
                return (drain(flush: true), true)
            }
            acc = tentative
            return (drain(flush: false), false)
        }

        // Release the held-back tail (no stop ever completed). Call once at a clean end.
        mutating func finish() -> String { drain(flush: true) }

        private mutating func drain(flush: Bool) -> String {
            let total = acc.count
            let safeEnd = flush ? total : max(emitted, total - max(0, maxStopLen - 1))
            guard safeEnd > emitted else { return "" }
            let s = acc.index(acc.startIndex, offsetBy: emitted)
            let e = acc.index(acc.startIndex, offsetBy: safeEnd)
            emitted = safeEnd
            return String(acc[s..<e])
        }
    }

    // MARK: - Helpers

    // Sample one token from the last-evaluated logits and return it together with the model's
    // CONFIDENCE for that step — the PEAK of the post-sampler distribution (the top token's prob),
    // NOT the sampled token's prob. Replicates the llama_sampler_sample() shorthand (apply chain ->
    // read selected) but WITHOUT the internal accept (the caller accepts once).
    //
    // Why peak-prob and not the sampled token's prob: the chain ends in `dist` (stochastic), so the
    // SELECTED token is frequently NOT the top token under temperature. The confidence gate asks
    // "is the model flailing?" — a property of how peaked the distribution is, independent of the
    // random draw. Gating on the sampled token's prob hid confident completions whenever the draw
    // landed on a lower-probability token (the "low first-token confidence -> hide everything" bug).
    // Falls back to the plain sampler (conf 0) if logits are unavailable or nothing was selected.
    private func sampleWithProb(ctx: OpaquePointer,
                                smpl: UnsafeMutablePointer<llama_sampler>,
                                nVocab: Int,
                                cand: inout [llama_token_data],
                                requiredRemaining: ArraySlice<UInt8> = [][...]) -> (llama_token, Float) {
        guard nVocab > 0, let logits = llama_get_logits_ith(ctx, -1) else {
            return (llama_sampler_sample(smpl, ctx, -1), 0)
        }
        // Tier 2a: when a stem is pending, drop (logit = -inf) every candidate whose bytes aren't
        // prefix-compatible with the remaining stem — done in the candidate fill the loop already runs,
        // so it's near-free, and only while a stem is being satisfied (the first 1–3 tokens).
        let constrained = !requiredRemaining.isEmpty
        for i in 0..<nVocab {
            var lg = logits[i]
            if constrained,
               !RequiredPrefix.isAdmissible(tokenBytes: tokenBytesSlice(llama_token(i)), remaining: requiredRemaining) {
                lg = -.infinity
            }
            cand[i] = llama_token_data(id: llama_token(i), logit: lg, p: 0)
        }
        return cand.withUnsafeMutableBufferPointer { buf -> (llama_token, Float) in
            var cur = llama_token_data_array(
                data: buf.baseAddress, size: nVocab, selected: -1, sorted: false)
            llama_sampler_apply(smpl, &cur)
            guard cur.selected >= 0, let data = cur.data else {
                return (llama_sampler_sample(smpl, ctx, -1), 0)
            }
            // Peak of the surviving (post-top_k/top_p/temp, softmaxed by `dist`) candidates. cur.size
            // is bounded by top_k (40), so this scan is cheap on the hot path.
            var peakProb: Float = 0
            for i in 0..<cur.size { let p = data[i].p; if p > peakProb { peakProb = p } }
            return (data[Int(cur.selected)].id, peakProb)
        }
    }


    // Pure helper (testable without llama): split an accumulated suggestion into the part that ends
    // on a whole-word boundary (everything up to and including the last whitespace) and the trailing
    // in-progress fragment. On a hard stop the fragment is dropped; on a clean stop it's appended.
    // A string with no interior whitespace is treated as entirely "in progress".
    static func splitTrailingPartial(_ s: String) -> (complete: String, partial: String) {
        guard let lastSpace = s.lastIndex(where: { $0.isWhitespace }) else { return ("", s) }
        return (String(s[...lastSpace]), String(s[s.index(after: lastSpace)...]))
    }

    private func tokenize(_ text: String, addSpecial: Bool) throws -> [llama_token] {
        guard let vocab else { throw InferenceError.notLoaded }
        let utf8 = Array(text.utf8)
        let cap = Int32(utf8.count) + 8
        var out = [llama_token](repeating: 0, count: Int(cap))
        let n = utf8.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                src.baseAddress!.withMemoryRebound(to: CChar.self, capacity: utf8.count) { cstr in
                    llama_tokenize(vocab, cstr, Int32(utf8.count), dst.baseAddress, cap, addSpecial, true)
                }
            }
        }
        if n < 0 { throw InferenceError.tokenizeFailed }
        out.removeLast(out.count - Int(n))
        return out
    }

    private func tokenToPiece(_ tok: llama_token) -> String {
        guard let vocab else { return "" }
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, tok, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, tok, &buf, Int32(buf.count), 0, false)
        }
        if n <= 0 { return "" }
        return buf.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: Int(n)) {
                String(decoding: UnsafeBufferPointer(start: $0, count: Int(n)), as: UTF8.self)
            }
        }
    }
}
