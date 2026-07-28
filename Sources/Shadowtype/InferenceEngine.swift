// InferenceEngine — wraps the pinned llama.cpp build for forward-from-caret
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

enum InferenceError: Error, LocalizedError {
    case notLoaded
    case cancelled
    case modelLoadFailed(String)
    case contextInitFailed
    case tokenizeFailed
    case decodeFailed(Int32)
    // M5: FIM (fill-in-middle) requires the model's three FIM tokens to bracket the prefix and
    // suffix; we can't silently front-trim that token stream when it exceeds n_ctx because the
    // dropped tokens would be fim_pre / fim_suf — framing the model was trained on. Routes catch
    // this and return HTTP 400 with a clear message instead of letting the model emit garbage.
    case fimContextOverflow(tokens: Int, cap: Int)
    // The requested `max_tokens` reserves so much of the context for generation that the over-cap
    // prompt would have to be front-trimmed to a stub. Answering from a stub looks like a model
    // failure, so the request is refused; routes should surface it as HTTP 400 (fixable by the
    // caller: shorten the prompt or lower max_tokens).
    case promptWindowExhausted(tokens: Int, cap: Int, maxTokens: Int)
    // The caller passed an explicit `contextTokenCap` (today only the /v1 API path, which asks for the
    // engine's REAL window rather than the ghost's small one) and the prompt still doesn't fit. There is
    // no larger window left to fall back to, so front-trimming here would silently drop the head of a
    // request the caller believes was honored — for a chat prompt that is the system message. Refuse
    // instead; routes surface it as HTTP 400. The ghost and rewrite paths pass no cap and keep trimming.
    case contextOverflow(tokens: Int, cap: Int)

    var errorDescription: String? {
        switch self {
        case .notLoaded:                  return "No model is loaded."
        case .cancelled:                  return "Generation was cancelled."
        case .modelLoadFailed(let path):  return "llama failed to load the model file at \(path) — the GGUF may be corrupt or unsupported by this build."
        case .contextInitFailed:          return "llama failed to initialize the Metal context — the GPU/OS may not support this model's settings."
        case .tokenizeFailed:             return "Tokenization failed."
        case .decodeFailed(let code):     return "llama_decode failed (code \(code))."
        case .fimContextOverflow(let t, let cap): return "Context overflow: \(t) tokens exceed the \(cap)-token cap."
        case .promptWindowExhausted(let t, let cap, let mt):
            return "Prompt is \(t) tokens but only \(cap) fit alongside max_tokens=\(mt) — shorten the prompt or lower max_tokens."
        case .contextOverflow(let t, let cap):
            return "Prompt is \(t) tokens but the context window fits \(cap) — shorten the prompt."
        }
    }
}

final class InferenceEngine: InferenceEngineProtocol {
    struct MetadataSnapshot: Equatable {
        let isLoaded: Bool
        let contextWindowTokens: Int
        let modelChatTemplate: String?
        let modelArchitecture: String?
        let modelSupportsChat: Bool
        let supportsFIM: Bool
    }

    private var metadataLock = os_unfair_lock_s()
    private var _metadata = MetadataSnapshot(
        isLoaded: false,
        contextWindowTokens: 4096,
        modelChatTemplate: nil,
        modelArchitecture: nil,
        modelSupportsChat: false,
        supportsFIM: false
    )

    var metadataSnapshot: MetadataSnapshot {
        os_unfair_lock_lock(&metadataLock)
        defer { os_unfair_lock_unlock(&metadataLock) }
        return _metadata
    }

    private func publishMetadata(_ snapshot: MetadataSnapshot) {
        os_unfair_lock_lock(&metadataLock)
        _metadata = snapshot
        os_unfair_lock_unlock(&metadataLock)
    }

    var isLoaded: Bool { metadataSnapshot.isLoaded }

    // llama.cpp handles (owned).
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?

    // GGUF `tokenizer.chat_template` populated on load (nil = no template, e.g. Base/pretrained
    // models). The /v1/chat/completions route consults this; ghost text never touches it.
    private var loadedModelChatTemplate: String? = nil
    var modelChatTemplate: String? { metadataSnapshot.modelChatTemplate }

    // GGUF `general.architecture` (e.g. "gemma4"), read on load. Feeds ChatTemplate's built-in
    // fallback renderer when llama.cpp can't classify the model's baked-in Jinja template.
    private var loadedModelArchitecture: String? = nil
    var modelArchitecture: String? { metadataSnapshot.modelArchitecture }

    // Whether /v1/chat/completions can actually render a prompt for this model — a dry-run of the
    // template (or an available architecture fallback), NOT mere template presence. Newer instruct
    // models ship Jinja templates llama.cpp's bare apply can't parse; advertising chat off presence
    // alone made /v1/models claim support, then 400 on the first request.
    private var loadedModelSupportsChat: Bool = false
    var modelSupportsChat: Bool { metadataSnapshot.modelSupportsChat }

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
    var supportsFIM: Bool { metadataSnapshot.supportsFIM }

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

    // Tier 2a: flat table of every token's rendered bytes, for the required-prefix (mid-word healing)
    // sampler mask. off[i]..<off[i+1] are token i's bytes. ~1–2 MB, a ~262k-token sweep with two
    // allocations per token. Built once at the END of load(), NOT lazily on the first healed
    // completion: lazily it landed between prefill and the first sampled token — squarely inside the
    // latency budget of the very completion that needed it — and mid-word healing is default-ON, so
    // that is the common case, not a rare one.
    //
    // unload() MUST clear all three. CompletionCoordinator.reloadModel is unload+load on the SAME
    // engine instance, so after a Settings model swap a surviving table returns the PREVIOUS model's
    // bytes: the ghost renders old-vocab byte strings, and when the new vocab is larger the ids past
    // the stale table return an empty slice, which RequiredPrefix.isAdmissible rejects — -inf on every
    // candidate, i.e. empty ghosts until relaunch, with nothing logged.
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

    // Candidate buffer for sampleWithProb, hoisted out of generate(): on a 262k-token vocab this is a
    // ~3.1 MB allocation that the old per-call `var cand` paid on EVERY generate — i.e. on every
    // keystroke that fires a ghost. Resized only when the vocab size changes (a model swap). Safe to
    // share because the inferenceQueue is serial: exactly one generate() is ever in flight, and it is
    // the only reader/writer. Passed `inout` into the decode loops, which never touch `self.cand`
    // themselves, so the inout access never overlaps a second access to this property.
    private var cand: [llama_token_data] = []

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

    // Per-sequence cooperative cancellation. A ghost keystroke targets seq 0 only, so it cannot
    // truncate an unrelated API decode on seq 1. API requests additionally carry the coordinator's
    // per-request token, which survives time spent queued and returns false from onToken when cancelled.
    final class CancellationRegistry {
        struct Request: Hashable {
            let seqID: Int32
            let id: UInt64
        }

        private var lock = os_unfair_lock_s()
        private var nextID: UInt64 = 0
        private var active: [Int32: Request] = [:]
        private var cancelled: Set<Request> = []

        func begin(seqID: Int32) -> Request? {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            nextID &+= 1
            let request = Request(seqID: seqID, id: nextID)
            active[seqID] = request
            return request
        }

        func cancel(seqID: Int32) {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            if let request = active[seqID] {
                cancelled.insert(request)
            }
        }

        func isCancelled(_ request: Request) -> Bool {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return cancelled.contains(request)
        }

        func end(_ request: Request) {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            if active[request.seqID] == request { active[request.seqID] = nil }
            cancelled.remove(request)
        }

        func reset() {
            os_unfair_lock_lock(&lock)
            active.removeAll()
            cancelled.removeAll()
            os_unfair_lock_unlock(&lock)
        }
    }
    private let cancellations = CancellationRegistry()

    static func requireAPIContinuation(_ shouldContinue: Bool) throws {
        if !shouldContinue { throw InferenceError.cancelled }
    }

    // Tunables.
    private let contextSize: UInt32 = 4096
    private let batchSize: UInt32 = 512
    private let maxSeqCount: Int32 = 4   // ghost (0) + API (1) + selection rewrite (2) + headroom; cparams.n_seq_max
    // Tokens per llama_decode during prefill, and the only cancel-latency knob we have: cancel is
    // polled BETWEEN chunks (FR-CE-4), and llama_set_abort_callback is a documented no-op for
    // GPU-offloaded work — which is all of it here (n_gpu_layers = 999). The old value of 48 bought
    // finer cancel granularity at the cost of starving the GPU: it, not cparams.n_batch (512), governs
    // the real batch width, so a 1024-token cold prefill was ~22 Metal graph builds + submits + waits
    // at a tenth of the configured batch. 256 is 4 dispatches for that same prefill; worst-case cancel
    // latency becomes one 256-token chunk, still well under a frame.
    private let prefillChunk: Int = 256

    // NOT overriding n_threads / n_threads_batch, deliberately. The tempting argument — "a background
    // menu-bar app should not run a core-count-wide thread pool against the user's foreground work" —
    // rests on a false premise: llama does NOT size these from the core count. `llama_context_default_params`
    // sets both to GGML_DEFAULT_N_THREADS, which is a hard-coded 4 (ggml.h). So a "narrower than default"
    // override changes nothing on Pro/Max-class CPUs (4 P-cores' worth either way) and only HALVES the
    // base M-series Macs to 2 — the machines with the least headroom, in the direction that could cost
    // latency. Every layer is Metal-offloaded (n_gpu_layers = 999), so the CPU side is sampling plus a
    // few non-offloaded ops and probably does not care either way; "probably" is the point. This is a
    // measurable question and InferenceEnginePerfTests exists for it — set these once there is a
    // before/after number, not before.

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

    // The window the context was actually created with, independent of the ghost's `maxContextTokens`
    // setting. `llama_n_ctx` once a context exists (it can differ from `contextSize` — llama rounds it
    // to the batch/seq layout), otherwise the size the next load will request. The API path sizes its
    // per-call cap from this so a 3000-token editor request is no longer front-trimmed to the ghost's
    // 1024-token setting, and /v1/health advertises it instead of the old hardcoded 4096.
    var contextWindowTokens: Int {
        metadataSnapshot.contextWindowTokens
    }

    private static let initializeBackendOnce: Void = {
        llama_backend_init()
    }()

    init() {}

    deinit { unload() }

    func load(modelPath: String) throws {
        guard !isLoaded else { return }

        _ = Self.initializeBackendOnce

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
        // Multi-seq context: ghost on seq 0, API/MCP on seq 1, selection rewrite on seq 2 (its few-shot
        // prompt diverges at token 0, so sharing seq 0 evicted the ghost's cached prefix). One slot of
        // headroom left in case a future surface wants its own KV slot too. The header recommends
        // swa_full=true with n_seq_max > 1 to avoid SWA performance cliffs.
        cparams.n_seq_max = UInt32(maxSeqCount)
        cparams.swa_full = true
        // kv_unified=true shares ONE n_ctx-sized buffer across all sequences. With the default (false)
        // llama partitions n_ctx across n_seq_max, so the ghost seq only gets n_ctx/maxSeqCount (~1024
        // tokens at 4096/4): a long page-context + prefix prompt (e.g. a multi-paragraph Reddit/forum
        // post) overflows the partition and `llama_decode` returns 1 (no KV slot) — the ghost silently
        // dies on exactly the long-prose case it's most wanted. Unify so the ghost can use the full
        // window; ghost (0) and the occasional API/MCP (1) or selection-rewrite (2) seq rarely both run
        // near-full at once.
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
        self.loadedModelChatTemplate = ChatTemplate.read(model: m)
        self.loadedModelArchitecture = ChatTemplate.readArchitecture(model: m)
        self.loadedModelSupportsChat = self.loadedModelChatTemplate.map {
            ChatTemplate.canApply(template: $0, architecture: self.loadedModelArchitecture)
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

            // Tier 2a: build the token-byte table here, on the load thread, instead of on the first
            // healed completion — see tokenByteBuf. Same one-pass cost, paid where nobody is waiting
            // on a ghost. unload() cleared it, so this always rebuilds for the newly loaded vocab.
            ensureTokenByteTable(nVocab: Int(n))
        }

        // FR-CE-8: confirm the Metal backend initialised. llama.cpp logs "ggml_metal_init: ..."
        // to stderr during model load; this line ties that to our context so it's greppable.
        NSLog("Shadowtype: InferenceEngine loaded model (Metal, n_gpu_layers=999, n_ctx=\(llama_n_ctx(c)), n_threads=\(llama_n_threads(c)), n_seq_max=\(maxSeqCount), arch=\(loadedModelArchitecture ?? "?"), chatTemplate=\(loadedModelChatTemplate != nil ? "yes" : "no"), supportsChat=\(loadedModelSupportsChat), fim=\(modelFIMTokens != nil ? "yes" : "no"), maskedControl=\(maskedSpecialBias.count))")

        self.cachedTokensBySeq.removeAll(keepingCapacity: false)
        self.nPastBySeq.removeAll(keepingCapacity: false)
        cancellations.reset()
        publishMetadata(MetadataSnapshot(
            isLoaded: true,
            contextWindowTokens: Int(llama_n_ctx(c)),
            modelChatTemplate: loadedModelChatTemplate,
            modelArchitecture: loadedModelArchitecture,
            modelSupportsChat: loadedModelSupportsChat,
            supportsFIM: modelFIMTokens != nil
        ))
    }

    // INTEGRATOR-NOTE: CompletionCoordinator should call requestCancel() before issuing a new
    // generate() (debounce/keystroke supersede) and reset() is implied at the start of generate().
    // This is the cooperative-cancel hook for FR-CE-4; generate() itself also stops when onToken
    // returns false, so a synchronous caller can cancel purely via the closure.
    func requestCancel() {
        cancellations.cancel(seqID: 0)
    }

    // `onSample`, when provided, is invoked once per sampled CONTENT token (a token whose decoded
    // piece carries a visible, non-whitespace character), on the engine's inference thread, BEFORE that
    // token's word(s) are flushed via `onToken`. It reports the step's RAW top-1 probability (the peak of
    // the model's own distribution, before the sampler chain distorts it — see sampleWithProb) and
    // whether it is the FIRST content token of this generation. The coordinator uses this for confidence
    // gating (suppress low-probability/flailing completions) — decoupled from word-flush boundaries so a
    // multi-token word doesn't smear the per-token signal.
    //
    // `seqID` selects which llama.cpp sequence this call belongs to (ghost = 0, API = 1,
    // selection rewrite = 2). `params`
    // configures the sampler chain + stop policy. When `params.useEngineStopPolicy` is true the
    // legacy ghost decode loop runs (word buffering, sentence stops, maxWords); when false the raw
    // API decode loop runs (verbatim piece stream, stop-string scan, maxTokens-only termination).
    //
    // Witness for the protocol's uncapped call shape (ghost seq 0, rewrite seq 2). A nil cap is
    // "use the engine-wide maxContextTokens", i.e. byte-identical to the pre-cap behaviour.
    func generate(prompt: String, maxTokens: Int,
                  seqID: Int32, params: SamplingParams,
                  requiredPrefix: [UInt8]?,
                  onToken: (String) -> Bool,
                  onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)?) throws {
        try generate(prompt: prompt, maxTokens: maxTokens, seqID: seqID, params: params,
                     contextTokenCap: nil, requiredPrefix: requiredPrefix,
                     onToken: onToken, onSample: onSample)
    }
    //
    // `contextTokenCap` overrides the engine-wide `maxContextTokens` for THIS call only. Ghost and
    // rewrite pass nil and keep the user's "Context window size"; the API path passes the real window
    // (see contextWindowTokens) so an editor's long request is not silently cut down to the ghost's
    // setting. A non-nil cap also makes an over-cap prompt an ERROR rather than a front-trim — see
    // InferenceError.contextOverflow.
    func generate(prompt: String, maxTokens: Int,
                  seqID: Int32 = 0,
                  params: SamplingParams = .ghostDefaults,
                  contextTokenCap: Int?,
                  requiredPrefix: [UInt8]? = nil,
                  onToken: (String) -> Bool,
                  onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)? = nil) throws {
        guard isLoaded, let ctx, let vocab else { throw InferenceError.notLoaded }
        guard let cancellationRequest = cancellations.begin(seqID: seqID) else {
            throw InferenceError.cancelled
        }
        defer { cancellations.end(cancellationRequest) }

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
        let residentTokens = Self.residentTokenCount(
            nPastBySeq: nPastBySeq,
            excluding: seqID
        )
        let sequenceCapacity = max(0, nCtx - residentTokens)
        let reserve = Self.generationReserve(maxTokens: maxTokens)
        guard sequenceCapacity >= reserve + 8 else {
            throw InferenceError.promptWindowExhausted(
                tokens: tokens.count,
                cap: max(0, sequenceCapacity - reserve),
                maxTokens: maxTokens
            )
        }
        // Cap at the live context minus head-room, and further at the user's configured window. The
        // head-room is NOT cosmetic: both decode loops append every generated token to THIS same seq's
        // KV after prefill, and with kv_unified the API/MCP seq shares the same n_ctx pool — so a
        // prompt filling to nCtx-4 leaves no room to generate (or for a co-resident seq) and
        // llama_decode returns 1 mid-stream. The reserve tracks the tokens this call will ACTUALLY
        // generate (see generationReserve): it used to be a flat 256 while /v1 admits max_tokens up to
        // 2048, so a prompt at the cap plus 2048 generated tokens overran the 4096 pool and the stream
        // died mid-response with a 500.
        let cap = Self.promptCap(nCtx: sequenceCapacity, maxTokens: maxTokens,
                                 maxContextTokens: contextTokenCap ?? maxContextTokens)
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
            // A large `maxTokens` can squeeze the prompt window below anything usable (max_tokens 4000
            // against a 4096 context leaves ~32 tokens). Front-trimming there would answer from a stub
            // of the prompt and look like a model failure, so fail the request instead — the caller can
            // shorten the prompt or lower max_tokens. Only the RESERVE may trigger this: a user who
            // deliberately set a small "Context window size" still gets the trim they asked for.
            if sequenceCapacity - Self.generationReserve(maxTokens: maxTokens) < Self.minPromptWindow {
                throw InferenceError.promptWindowExhausted(tokens: tokens.count, cap: cap, maxTokens: maxTokens)
            }
            // An explicit cap means the caller already asked for the largest window there is, so the
            // over-cap prompt is a genuine overflow rather than the ghost's deliberate recall/latency
            // trade. Front-trimming it would drop the HEAD — the system message of a chat request — and
            // still answer HTTP 200, which is the silent-truncation bug this refuses to reintroduce.
            if contextTokenCap != nil {
                throw InferenceError.contextOverflow(tokens: tokens.count, cap: cap)
            }
            // The raw path front-trims (most-recent-context wins), but NOT with a plain suffix: that
            // dropped the BOS that tokenize(addSpecial: true) put at index 0, and Gemma-3 — the
            // shipping default — is trained with a mandatory BOS. Keep slot 0 whenever this vocab
            // actually prepends one, and anchor the window so the head stays byte-stable between
            // re-anchors (see trimToWindow).
            tokens = Self.trimToWindow(tokens, cap: cap, keepFirst: llama_vocab_get_add_bos(vocab))
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
            if cancellations.isCancelled(cancellationRequest) {
                throw InferenceError.cancelled
            }
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

        // Seed the repetition-penalty window with the tail of the PROMPT. llama_sampler_accept was
        // only ever called for tokens THIS call generated, so with repeatPenaltyLastN 64 and maxTokens
        // 16-24 the window started empty and never held a single prompt token: nothing at sampling
        // time discouraged the ghost from echoing the words the user had just typed (the coordinator
        // compensates after the fact by HIDING the whole suggestion — isPrefixDuplicate — where one
        // logit adjustment would have produced a good one), while the penalty still punished
        // legitimate short-range repetition inside a 12-word completion. Chronological order matters:
        // llama.cpp's penalties sampler keeps a ring buffer of the last `penalty_last_n` accepted
        // tokens, so the most recent prompt token must be accepted LAST. Only when a penalties sampler
        // is actually in the chain — the greedy branch adds none, and penalty_last_n == 0 is a
        // documented no-op in its apply.
        if !(useGreedyEnv || params.greedy) {
            for t in Self.penaltyPrimeTokens(prompt: tokens, lastN: params.repeatPenaltyLastN) {
                llama_sampler_accept(smpl, t)
            }
        }

        // --- Decode loop ------------------------------------------------------------------------
        // Reusable candidate buffer for manual sample-with-probability (avoids a per-token vocab-sized
        // alloc; the decode budget is tiny — maxTokens). `cur.data` is modified in place by the chain.
        // The buffer itself is a stored property (see `cand`) so it also survives across generate()
        // calls; refill is per-token anyway, so only the size has to match the live vocab.
        let nVocab = Int(llama_vocab_n_tokens(vocab))
        let needsCandidates = Self.requiresCandidateSampling(
            hasSampleObserver: onSample != nil,
            hasRequiredPrefix: !(requiredPrefix ?? []).isEmpty
        )
        if needsCandidates, cand.count != nVocab {
            cand = [llama_token_data](repeating: llama_token_data(id: 0, logit: 0, p: 0), count: nVocab)
        }

        if params.useEngineStopPolicy {
            try ghostDecodeLoop(ctx: ctx, vocab: vocab, smpl: smpl, batch: &batch,
                                seqID: seqID, maxTokens: maxTokens,
                                cached: &cached, nPast: &nPast,
                                nVocab: nVocab, cand: &cand,
                                requiredPrefix: requiredPrefix,
                                cancellationRequest: cancellationRequest,
                                onToken: onToken, onSample: onSample)
        } else {
            try apiDecodeLoop(ctx: ctx, vocab: vocab, smpl: smpl, batch: &batch,
                              seqID: seqID, maxTokens: maxTokens,
                              stops: params.stopStrings,
                              cached: &cached, nPast: &nPast,
                              nVocab: nVocab, cand: &cand,
                              cancellationRequest: cancellationRequest,
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
                                 cancellationRequest: CancellationRegistry.Request,
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
        var wordCount = 0         // words so far: a leading-space piece opens one, and in a space-less
                                  // script (CJK/kana/Thai) each character IS one
        var pending = ""          // un-flushed trailing fragment (the possibly-incomplete current word)
        var utf8Decoder = UTF8StreamDecoder()

        // Flush every settled word in `pending` (text up to and including each interior whitespace),
        // one whitespace-delimited chunk per onToken call so streaming stays incremental (the
        // consumer sees the ghost grow word-by-word, as before). Holds back only the trailing
        // (possibly-incomplete) word, which a hard stop will drop. Returns false on consumer cancel.
        //
        // A space-less-script character (CJK / kana / Thai …) closes a word too: those languages emit
        // no interior whitespace, so a whitespace-only rule streamed NOTHING for them — the entire
        // completion escaped through the `!flushedAny` fallback at the very end of the run, with no
        // early first-token render to beat the deadline drop.
        func flushCompleteWords() -> Bool {
            guard sawNonSpace else { return true }   // don't emit leading-whitespace-only output
            while let boundary = pending.firstIndex(where: {
                $0.isWhitespace || SentenceBoundary.isSpacelessScript($0)
            }) {
                let head = String(pending[...boundary])
                pending = String(pending[pending.index(after: boundary)...])
                if !head.isEmpty {
                    flushedAny = true
                    if !onToken(head) { return false }
                }
            }
            return true
        }

        while emitted < maxTokens {
            if cancellations.isCancelled(cancellationRequest) {
                throw InferenceError.cancelled
            }

            // Manual sample = apply(chain) + read the step's CONFIDENCE (peak prob) + accept ONCE. (The
            // llama_sampler_sample() shorthand already accepts internally, so the old extra accept here
            // was a double-accept; this path also exposes the peak probability for the confidence gate.)
            let detailedSample = Self.requiresCandidateSampling(
                hasSampleObserver: onSample != nil,
                hasRequiredPrefix: !remaining.isEmpty
            )
            let tok: llama_token
            let confProb: Float
            let alreadyAccepted: Bool
            if detailedSample {
                (tok, confProb, alreadyAccepted) = sampleWithProb(
                    ctx: ctx,
                    smpl: smpl,
                    nVocab: nVocab,
                    cand: &cand,
                    computeConfidence: onSample != nil,
                    requiredRemaining: remaining[...]
                )
            } else {
                tok = llama_sampler_sample(smpl, ctx, -1)
                confProb = 0
                alreadyAccepted = true
            }
            if llama_vocab_is_eog(vocab, tok) {            // clean stop: flush the trailing word too
                pending += utf8Decoder.finish()
                let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { _ = onToken(pending) }
                return
            }
            if !alreadyAccepted { llama_sampler_accept(smpl, tok) }
            let hadContentBefore = sawNonSpace

            var pieceBytes = tokenToPieceBytes(tok, vocab: vocab)
            // Tier 2a: consume the still-pending stem bytes from this token; only the post-stem text
            // flows into the ghost. The token is still decoded below so the KV cache advances. Byte
            // level so a multibyte char split across tokens consumes correctly; the post-stem remainder
            // begins on a char boundary (the stem is whole characters), so decoding it is always valid.
            if !remaining.isEmpty {
                let tb = tokenBytesSlice(tok)
                let consumed = min(tb.count, remaining.count)
                remaining = RequiredPrefix.advanced(remaining: remaining, byEmitting: tb)
                let post = tb.dropFirst(consumed)
                pieceBytes = Array(post)
            }
            var piece = utf8Decoder.push(pieceBytes)
            if !piece.isEmpty {
                // A new word starts whenever a piece opens with whitespace after we've seen content.
                if sawNonSpace, let first = piece.first, first.isWhitespace { wordCount += 1 }
                // …and every space-less-script character IS a word: those scripts never produce a
                // leading-whitespace piece, so the rule above left wordCount at 0 forever and both the
                // maxWords cap and stopAtSentenceAfterWords were unreachable for CJK/Japanese/Thai —
                // the generation ran to maxTokens every time.
                wordCount += piece.reduce(0) { $0 + (SentenceBoundary.isSpacelessScript($1) ? 1 : 0) }

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
                    onSample?(confProb, !hadContentBefore)
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
    // Stop matching is byte-oriented and holds back only maxStopByteLen - 1 bytes, so a delimiter
    // split across token pieces is removed without retaining or rescanning the full response.
    private func apiDecodeLoop(ctx: OpaquePointer, vocab: OpaquePointer,
                               smpl: UnsafeMutablePointer<llama_sampler>,
                               batch: inout llama_batch,
                               seqID: Int32, maxTokens: Int,
                               stops: [String],
                               cached: inout [llama_token], nPast: inout Int32,
                               nVocab: Int, cand: inout [llama_token_data],
                               cancellationRequest: CancellationRegistry.Request,
                               onToken: (String) -> Bool,
                               onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)?) throws {
        var emitted = 0
        var firstContentReported = false
        // A stop string can span several tokens (gemma emits "<end_of_turn>" as "<","end_of_turn",">")
        // and onToken can't be retracted, so StreamStopFilter holds back the last delimiter-length bytes
        // until they're proven not to begin a stop. See its definition for the holdback rationale.
        var stopFilter = StreamStopFilter(stops: stops)
        var utf8Decoder = UTF8StreamDecoder()

        while emitted < maxTokens {
            if cancellations.isCancelled(cancellationRequest) {
                throw InferenceError.cancelled
            }

            let tok: llama_token
            let confProb: Float
            let alreadyAccepted: Bool
            if onSample != nil {
                (tok, confProb, alreadyAccepted) = sampleWithProb(
                    ctx: ctx,
                    smpl: smpl,
                    nVocab: nVocab,
                    cand: &cand,
                    computeConfidence: true
                )
            } else {
                tok = llama_sampler_sample(smpl, ctx, -1)
                confProb = 0
                alreadyAccepted = true
            }
            if llama_vocab_is_eog(vocab, tok) {
                let tail = utf8Decoder.push(stopFilter.finish()) + utf8Decoder.finish()
                if !tail.isEmpty { try Self.requireAPIContinuation(onToken(tail)) }
                return
            }
            if !alreadyAccepted { llama_sampler_accept(smpl, tok) }

            let pieceBytes = tokenToPieceBytes(tok, vocab: vocab)
            if !pieceBytes.isEmpty {
                onSample?(confProb, !firstContentReported)
                firstContentReported = true
                let (chunkBytes, stopped) = stopFilter.push(pieceBytes)
                let chunk = utf8Decoder.push(chunkBytes)
                if !chunk.isEmpty { try Self.requireAPIContinuation(onToken(chunk)) }
                if stopped {
                    let tail = utf8Decoder.finish()
                    if !tail.isEmpty { try Self.requireAPIContinuation(onToken(tail)) }
                    return
                }
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
        let tail = utf8Decoder.push(stopFilter.finish()) + utf8Decoder.finish()
        if !tail.isEmpty { try Self.requireAPIContinuation(onToken(tail)) }
    }

    func unload() {
        publishMetadata(MetadataSnapshot(
            isLoaded: false,
            contextWindowTokens: Int(contextSize),
            modelChatTemplate: nil,
            modelArchitecture: nil,
            modelSupportsChat: false,
            supportsFIM: false
        ))
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil
        model = nil
        vocab = nil
        loadedModelChatTemplate = nil
        loadedModelArchitecture = nil
        loadedModelSupportsChat = false
        modelFIMTokens = nil
        // Tier 2a: the byte table is vocab-specific. reloadModel() is unload+load on this same
        // instance, so leaving it behind hands the next model the previous vocab's bytes (see
        // tokenByteBuf for what that breaks). Same for the vocab-sized candidate buffer, which
        // generate() re-sizes on mismatch anyway but should not hold ~3 MB across an unload.
        tokenByteBuf.removeAll(keepingCapacity: false)
        tokenByteOff.removeAll(keepingCapacity: false)
        tokenByteTableReady = false
        cand.removeAll(keepingCapacity: false)
        cachedTokensBySeq.removeAll(keepingCapacity: false)
        nPastBySeq.removeAll(keepingCapacity: false)
        cancellations.reset()
    }

    // MARK: - KV-cache helpers (FR-CE-5)

    // Full reset for one seq: drop its entire KV cache. Used for a cold prefill and as the fallback
    // when a partial SWA trim is refused (see generate()). Partial reuse instead trims only above
    // the common prefix: llama_memory_seq_rm(mem, seqID, reuseLength, -1).
    private func resetSeq(_ seqID: Int32, in memory: OpaquePointer?) {
        guard let memory else { return }
        _ = llama_memory_seq_rm(memory, seqID, 0, -1)
    }

    // Hand a sequence's KV cells back to the shared pool (see the protocol declaration for why). Safe to
    // call on a seq that was never used. Must run on the inferenceQueue like every other engine call —
    // it mutates the same per-seq maps generate() maintains.
    func releaseSeq(_ seqID: Int32) {
        guard isLoaded, let ctx else { return }
        resetSeq(seqID, in: llama_get_memory(ctx))
        cachedTokensBySeq[seqID] = nil
        nPastBySeq[seqID] = nil
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

    // Prompt tokens to replay through llama_sampler_accept so the repetition-penalty ring buffer
    // reflects what the user actually wrote (see the call site). The LAST `lastN` tokens, in
    // chronological order — the ring buffer evicts from the front, so a longer replay would just push
    // the recent tokens back out. Empty when no penalty window is configured.
    // llama_token is a typealias for Int32; spelled Int32 so this stays callable from the test target
    // without importing CLlama.
    static func penaltyPrimeTokens(prompt: [Int32], lastN: Int32) -> ArraySlice<Int32> {
        guard lastN > 0 else { return [][...] }
        return prompt.suffix(Int(lastN))
    }

    // Smallest prompt window worth honouring: below this the front-trim leaves a stub rather than
    // context, so generate() refuses the request instead (see promptWindowExhausted).
    static let minPromptWindow = 512

    // KV cells held back from the prompt for the tokens this call will generate. Both decode loops
    // grow the same seq's KV token by token, so the reserve has to cover `maxTokens` — a flat 256
    // (the pre-fix value) plus a /v1 request's max_tokens of 2048 overran the 4096 pool and killed the
    // stream mid-response. The 256 floor is the co-resident-seq margin kv_unified needs and keeps the
    // ghost path (maxTokens ~16-24) byte-identical to the old behaviour; +64 is slack for the
    // single-token decode batches themselves.
    static func generationReserve(maxTokens: Int) -> Int { max(256, maxTokens + 64) }

    // Unified KV is one n_ctx-sized pool. Tokens held by every OTHER sequence reduce the cells this
    // request can safely budget; the current sequence's own tail is reusable or trimmed below.
    static func residentTokenCount(nPastBySeq: [Int32: Int32], excluding seqID: Int32) -> Int {
        nPastBySeq.reduce(into: 0) { total, entry in
            if entry.key != seqID { total += max(0, Int(entry.value)) }
        }
    }

    // Prompt-token budget for one generate(): the live context minus the generation reserve, then the
    // user's configured "Context window size". Floored at 8 so the arithmetic can't go negative.
    static func promptCap(nCtx: Int, maxTokens: Int, maxContextTokens: Int) -> Int {
        max(8, min(nCtx - generationReserve(maxTokens: maxTokens), maxContextTokens))
    }

    // Granularity of the front-trim window (FIX 4). See trimToWindow.
    static let trimAnchor = 256

    // Front-trim an over-cap prompt to the most recent `cap` tokens, ANCHORED — and keeping token 0
    // when the vocab prepended a BOS (`keepFirst`).
    //
    // Why anchored: a plain `suffix(cap)` slides the window forward by one token per keystroke, so
    // cached[0] != new[0] on every fire, reuseLength() returns 0, resetSeq() runs, and every single
    // keystroke pays a full cold prefill. That is why the documented warm ~65 ms path (FR-CE-5)
    // vanishes in long documents — the exact case the product exists for. Rounding the dropped-token
    // count UP to a multiple of `trimAnchor` pins the window head to a fixed grid: between re-anchors
    // the prompt head is byte-identical, reuseLength grows normally, and one cold prefill is amortized
    // over ~256 tokens of typing. (Rounding DOWN would keep more tokens than `cap` allows and blow the
    // n_ctx budget the cap exists to protect, so it has to be up.) The price is that the live window
    // oscillates in (cap - anchor, cap] instead of sitting at cap — ~6% of context at 3840/256.
    //
    // Upgrade path for the next reader: llama_memory_seq_add + llama_memory_can_shift DO exist in this
    // build (llama.h:736, :769), so a true server-style seq_rm+seq_add context shift — rebasing the KV
    // positions instead of re-prefilling — is possible. We deliberately take the anchored window first:
    // it is a fraction of the work and captures most of the win.
    //
    // llama_token is a typealias for Int32; spelled Int32 so this stays callable from the test target
    // without importing CLlama.
    static func trimToWindow(_ tokens: [Int32], cap: Int, keepFirst: Bool) -> [Int32] {
        guard cap > 0, tokens.count > cap else { return tokens }
        let head = keepFirst ? 1 : 0            // slots reserved at the front (BOS)
        guard tokens.count > head else { return tokens }
        // Scale the step down on small windows so one anchor step can never cost more than a quarter
        // of the context (at the shipping cap of 3840 this is a no-op and the step stays 256).
        let anchor = max(1, min(trimAnchor, cap / 4))
        // Body tokens that MUST go for the result (head + kept body) to fit `cap`; the head is carried
        // over, so the shortfall is the same with or without a BOS.
        let minDrop = tokens.count - cap
        let drop = min(((minDrop + anchor - 1) / anchor) * anchor, tokens.count - head)
        var out: [Int32] = []
        out.reserveCapacity(tokens.count - drop)
        if keepFirst { out.append(tokens[0]) }
        out.append(contentsOf: tokens[(head + drop)...])
        return out
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
    // retracted — so we hold back the last (maxStopByteLen-1) bytes of the running output until they're
    // proven not to begin a stop. `push` returns the chunk safe to emit now plus whether a stop hit;
    // `finish` releases the held tail at a clean end (EOG / maxTokens). Pure + testable: no model.
    struct StreamStopFilter {
        private let stops: [[UInt8]]
        private let maxStopByteLen: Int
        private var lookback: [UInt8] = []
        var bufferedByteCount: Int { lookback.count }

        init(stops: [String]) {
            self.stops = stops.filter { !$0.isEmpty }.map { Array($0.utf8) }
            self.maxStopByteLen = self.stops.map(\.count).max() ?? 0
        }

        // Feed one raw token piece. Returns (bytesToEmitNow, stopped). When stopped is true the stop
        // string (and anything after) has been dropped and the loop should end.
        mutating func push(_ piece: [UInt8]) -> (chunk: [UInt8], stopped: Bool) {
            let tentative = lookback + piece
            if let stopStart = Self.firstStopMatch(in: tentative, stops: stops) {
                lookback.removeAll(keepingCapacity: true)
                return (Array(tentative[..<stopStart]), true)
            }
            let holdback = max(0, maxStopByteLen - 1)
            let safeEnd = max(0, tentative.count - holdback)
            let chunk = Array(tentative[..<safeEnd])
            lookback = Array(tentative[safeEnd...])
            return (chunk, false)
        }

        // Release the held-back tail (no stop ever completed). Call once at a clean end.
        mutating func finish() -> [UInt8] {
            defer { lookback.removeAll(keepingCapacity: true) }
            return lookback
        }

        private static func firstStopMatch(in bytes: [UInt8], stops: [[UInt8]]) -> Int? {
            var earliest: Int?
            for stop in stops where stop.count <= bytes.count {
                for start in 0...(bytes.count - stop.count)
                where bytes[start..<(start + stop.count)].elementsEqual(stop) {
                    if earliest.map({ start < $0 }) ?? true { earliest = start }
                    break
                }
            }
            return earliest
        }
    }

    // Token pieces are byte strings, not independently valid Swift strings. Byte-fallback
    // vocabularies may split one scalar across several tokens, so retain only the incomplete UTF-8
    // suffix and emit complete prefixes.
    struct UTF8StreamDecoder {
        private var pending: [UInt8] = []
        var bufferedByteCount: Int { pending.count }

        mutating func push(_ bytes: [UInt8]) -> String {
            pending.append(contentsOf: bytes)
            if let whole = String(bytes: pending, encoding: .utf8) {
                pending.removeAll(keepingCapacity: true)
                return whole
            }

            let maxHold = min(3, pending.count)
            guard maxHold > 0 else { return "" }
            for hold in 1...maxHold {
                let split = pending.count - hold
                let suffix = Array(pending[split...])
                guard Self.isIncompleteScalarPrefix(suffix) else { continue }
                let prefix = String(decoding: pending[..<split], as: UTF8.self)
                pending = suffix
                return prefix
            }
            let recovered = String(decoding: pending, as: UTF8.self)
            pending.removeAll(keepingCapacity: true)
            return recovered
        }

        mutating func finish() -> String {
            defer { pending.removeAll(keepingCapacity: true) }
            return String(decoding: pending, as: UTF8.self)
        }

        private static func isIncompleteScalarPrefix(_ bytes: [UInt8]) -> Bool {
            guard let first = bytes.first else { return false }
            let expected: Int
            switch first {
            case 0xC2...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF4: expected = 4
            default: return false
            }
            guard bytes.count < expected else { return false }
            for byte in bytes.dropFirst() where !(0x80...0xBF).contains(byte) { return false }
            if bytes.count >= 2 {
                let second = bytes[1]
                if first == 0xE0 && second < 0xA0 { return false }
                if first == 0xED && second > 0x9F { return false }
                if first == 0xF0 && second < 0x90 { return false }
                if first == 0xF4 && second > 0x8F { return false }
            }
            return true
        }
    }

    // MARK: - Helpers

    // Sample one token from the last-evaluated logits and return it together with the model's
    // CONFIDENCE for that step — the PEAK of the model's RAW (pre-sampler-chain) distribution, NOT
    // the sampled token's prob. Replicates the llama_sampler_sample() shorthand (apply chain -> read
    // selected) but WITHOUT the internal accept (the caller accepts once).
    //
    // Why peak-prob and not the sampled token's prob: the chain ends in `dist` (stochastic), so the
    // SELECTED token is frequently NOT the top token under temperature. The confidence gate asks
    // "is the model flailing?" — a property of how peaked the distribution is, independent of the
    // random draw. Gating on the sampled token's prob hid confident completions whenever the draw
    // landed on a lower-probability token (the "low first-token confidence -> hide everything" bug).
    //
    // Why RAW and not the post-chain peak: the peak used to be read off `data[i].p` AFTER
    // llama_sampler_apply had run the whole chain — after top_k(40) truncated, after top_p(0.9)
    // truncated AND RENORMALIZED, and after temp 0.4 divided every logit by 0.4 (a 2.5x sharpening).
    // A step whose true top-1 probability is 0.10, spread over ~40 near-uniform survivors, reported
    // ~0.5 that way — five times the 0.10 first-token threshold — so both confidence gates only fired
    // on an almost perfectly flat distribution, i.e. essentially never. Reading the raw logits also
    // makes the number meaningful under greedy sampling: llama_sampler_init_greedy is an argmax with
    // NO softmax, so the post-chain scan returned p == 0 for every token and the gate would have
    // suppressed everything the moment `params.greedy` was set (the API temperature == 0 path, and the
    // one-line experiment any maintainer would try on the ghost).
    // Falls back to the plain sampler if logits are unavailable (conf 0 = unknown).
    static func requiresCandidateSampling(hasSampleObserver: Bool,
                                          hasRequiredPrefix: Bool) -> Bool {
        hasSampleObserver || hasRequiredPrefix
    }

    private func sampleWithProb(ctx: OpaquePointer,
                                smpl: UnsafeMutablePointer<llama_sampler>,
                                nVocab: Int,
                                cand: inout [llama_token_data],
                                computeConfidence: Bool,
                                requiredRemaining: ArraySlice<UInt8> = [][...])
        -> (token: llama_token, confidence: Float, alreadyAccepted: Bool) {
        guard nVocab > 0, let logits = llama_get_logits_ith(ctx, -1) else {
            return (llama_sampler_sample(smpl, ctx, -1), 0, true)
        }
        // Tier 2a: when a stem is pending, drop (logit = -inf) every candidate whose bytes aren't
        // prefix-compatible with the remaining stem — done in the candidate fill the loop already runs,
        // so it's near-free, and only while a stem is being satisfied (the first 1–3 tokens).
        let constrained = !requiredRemaining.isEmpty
        var maxLogit = -Float.infinity
        for i in 0..<nVocab {
            var lg = logits[i]
            if constrained,
               !RequiredPrefix.isAdmissible(tokenBytes: tokenBytesSlice(llama_token(i)), remaining: requiredRemaining) {
                lg = -.infinity
            }
            if computeConfidence, lg > maxLogit { maxLogit = lg }
            cand[i] = llama_token_data(id: llama_token(i), logit: lg, p: 0)
        }
        // Raw softmax peak = exp(maxLogit - logSumExp) = 1 / Σexp(logit - maxLogit). Subtracting the
        // max first is what keeps the exponentials in range on a 262k-token vocab. Masked (-inf)
        // entries drop out of both max and sum, so a healed step reports the peak among the tokens the
        // required-prefix constraint actually left admissible.
        var sumExp = 0.0
        if computeConfidence, maxLogit > -.infinity {
            // Terms more than 20 nats below the peak contribute < 2.1e-9 each (< 6e-4 total across the
            // whole vocab), and skipping them turns ~262k expf() calls per SAMPLED TOKEN — milliseconds
            // out of a 400 ms end-to-end budget — into a compare sweep plus a few thousand exps.
            let cutoff = maxLogit - 20
            for i in 0..<nVocab where cand[i].logit > cutoff {
                sumExp += Double(exp(cand[i].logit - maxLogit))
            }
        }
        let rawPeak: Float = computeConfidence && sumExp > 0 ? Float(1.0 / sumExp) : 0
        return cand.withUnsafeMutableBufferPointer { buf -> (llama_token, Float, Bool) in
            var cur = llama_token_data_array(
                data: buf.baseAddress, size: nVocab, selected: -1, sorted: false)
            llama_sampler_apply(smpl, &cur)
            guard cur.selected >= 0, let data = cur.data else {
                return (llama_sampler_sample(smpl, ctx, -1), rawPeak, true)
            }
            return (data[Int(cur.selected)].id, rawPeak, false)
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

    struct TokenizationInput: Equatable {
        let storage: [UInt8]
        let byteCount: Int32
    }

    static func tokenizationInput(_ text: String) -> TokenizationInput {
        var storage = Array(text.utf8)
        let byteCount = Int32(storage.count)
        storage.append(0)
        return TokenizationInput(storage: storage, byteCount: byteCount)
    }

    private func tokenize(_ text: String, addSpecial: Bool) throws -> [llama_token] {
        guard let vocab else { throw InferenceError.notLoaded }
        let input = Self.tokenizationInput(text)
        let cap = input.byteCount + 8
        var out = [llama_token](repeating: 0, count: Int(cap))
        let n = input.storage.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                src.baseAddress!.withMemoryRebound(to: CChar.self, capacity: src.count) { cstr in
                    llama_tokenize(vocab, cstr, input.byteCount, dst.baseAddress, cap, addSpecial, true)
                }
            }
        }
        if n < 0 { throw InferenceError.tokenizeFailed }
        out.removeLast(out.count - Int(n))
        return out
    }

}
