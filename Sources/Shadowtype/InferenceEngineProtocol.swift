// InferenceEngineProtocol — the abstraction the suggestion pipeline depends on, so a second backend
// (Apple's on-device FoundationModels on macOS 26+) can be slotted in behind a router without touching
// the coordinator. Scaffold only for now: the llama.cpp backend (InferenceEngine) is the sole live
// implementation; FoundationModelsEngine is a stub and the router forwards to whichever backend is
// selected (always llama today).
//
// The surface is what CompletionCoordinator + AppDelegate touch on the engine — generation,
// lifecycle, cooperative cancel, the settable stop-policy / context-window tunables, and (since M0)
// per-request `seqID` + `SamplingParams`. The legacy shorter call shape is preserved by a defaulted
// extension below so ghost call sites stay source-compatible: they implicitly run on seq 0 with
// `SamplingParams.ghostDefaults`, exactly matching the pre-M0 hardcoded sampler chain.
import Foundation

protocol InferenceEngineProtocol: AnyObject {
    var isLoaded: Bool { get }

    // Stop-policy + context-window tunables (driven by AppDelegate from the active CompletionLength
    // preset and the Context-window setting). See InferenceEngine for semantics. These remain
    // engine-wide settings consulted by the ghost path; the API/MCP path bypasses them via
    // `SamplingParams.useEngineStopPolicy = false`.
    var stopAtFirstSentence: Bool { get set }
    var maxWords: Int { get set }
    var stopAtSentenceAfterWords: Int { get set }
    var maxContextTokens: Int { get set }

    // GGUF `tokenizer.chat_template` metadata read on load (nil if absent). The /v1/chat/completions
    // path renders messages via this; when nil the route returns HTTP 400 + steers to /v1/completions.
    var modelChatTemplate: String? { get }

    // GGUF `general.architecture`, for ChatTemplate's fallback renderer; and whether chat rendering
    // actually works for the loaded model (template recognized by llama.cpp OR a built-in fallback
    // exists). /v1/models advertises `supports_chat` from the latter — not from template presence.
    var modelArchitecture: String? { get }
    var modelSupportsChat: Bool { get }

    // M5 FIM. True when the loaded model exposes llama_vocab_fim_{pre,suf,mid}. The
    // /v1/completions route gates the optional OpenAI `suffix` field on this — a request with
    // `suffix` against a non-FIM model returns HTTP 400 with a clear message. The /v1/models
    // route surfaces it as `supports_fim: true|false` so Cursor/Continue can decide locally
    // whether to send FIM requests.
    var supportsFIM: Bool { get }

    func load(modelPath: String) throws
    func unload()
    func requestCancel()

    // Drop a sequence's KV cells and cached token stream. `kv_unified = true` means every seq draws from
    // ONE n_ctx-sized pool, so a seq that will never reuse its prefix should hand the cells back rather
    // than hold them against the ghost: ghost + rewrite both prefilling near the cap would otherwise ask
    // for more cells than exist and `llama_decode` fails with no KV slot. Rewrite is exactly that case —
    // every rewrite prompt diverges at token 0, so its cache is never reused.
    func releaseSeq(_ seqID: Int32)

    // Full-surface generate. Ghost callers use the defaulted extension below (`seqID: 0`,
    // `params: .ghostDefaults`); API/MCP callers stamp their own seq ID + clamped params so the two
    // workloads can coexist in the same context with independent KV slots.
    func generate(prompt: String,
                  maxTokens: Int,
                  seqID: Int32,
                  params: SamplingParams,
                  requiredPrefix: [UInt8]?,
                  onToken: (String) -> Bool,
                  onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)?) throws

    // The engine's REAL context window, as opposed to `maxContextTokens` — which is engine-WIDE but is
    // driven from the GHOST's "Context window size" setting (1024 by default). Because generate()
    // applies that cap with no reference to seqID, a 3000-token Cursor/Claude Code request on seq 1 is
    // silently front-trimmed to the last 1024 tokens — the system prompt is dropped — and still returns
    // HTTP 200, while /v1/health advertises the full window. The API path reads this to size its own
    // cap. Declared here (not only in the extension) so a backend CAN override it: InferenceEngine
    // reports its live `llama_n_ctx`, and the extension default below (the engine-wide setting) is the
    // conservative fallback for a backend that has no separate notion of a window.
    var contextWindowTokens: Int { get }

    // Per-call prompt cap. `contextTokenCap` overrides the engine-wide `maxContextTokens` for THIS call
    // only, so the ghost keeps the user's small window while an API request gets the real one. A
    // requirement rather than extension-only so a backend that implements it is dispatched to
    // dynamically — InferenceEngine threads it into `promptCap` and turns an over-cap prompt into
    // `InferenceError.contextOverflow` (HTTP 400) instead of a silent front-trim. The extension default
    // below ignores the cap and forwards to the engine-wide path, for backends that have no such notion.
    func generate(prompt: String,
                  maxTokens: Int,
                  seqID: Int32,
                  params: SamplingParams,
                  contextTokenCap: Int?,
                  requiredPrefix: [UInt8]?,
                  onToken: (String) -> Bool,
                  onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)?) throws
}

extension InferenceEngineProtocol {
    var contextWindowTokens: Int { maxContextTokens }

    func generate(prompt: String,
                  maxTokens: Int,
                  seqID: Int32,
                  params: SamplingParams,
                  contextTokenCap: Int?,
                  requiredPrefix: [UInt8]?,
                  onToken: (String) -> Bool,
                  onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)?) throws {
        try generate(prompt: prompt, maxTokens: maxTokens, seqID: seqID, params: params,
                     requiredPrefix: requiredPrefix, onToken: onToken, onSample: onSample)
    }

    // Legacy ghost-text shape. Forwards to the new method with `seq 0` + `.ghostDefaults` so all
    // existing call sites (CompletionCoordinator.startGeneration / rewrite / warmFocus) remain
    // source-compatible and byte-identical in behavior.
    func generate(prompt: String, maxTokens: Int,
                  requiredPrefix: [UInt8]? = nil,
                  onToken: (String) -> Bool,
                  onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)? = nil) throws {
        try generate(prompt: prompt, maxTokens: maxTokens,
                     seqID: 0, params: .ghostDefaults,
                     requiredPrefix: requiredPrefix,
                     onToken: onToken, onSample: onSample)
    }
}

// Routes generation to a selected backend. The protocol surface is forwarded to the active backend;
// tunable writes go to the active backend so AppDelegate's existing configuration path is unchanged.
final class InferenceEngineRouter: InferenceEngineProtocol {
    enum Backend { case llama, foundationModels }

    private let llama: InferenceEngineProtocol
    private let foundationModels: InferenceEngineProtocol
    var backend: Backend

    init(llama: InferenceEngineProtocol = InferenceEngine(),
         foundationModels: InferenceEngineProtocol = FoundationModelsEngine(),
         backend: Backend = .llama) {
        self.llama = llama
        self.foundationModels = foundationModels
        self.backend = backend
    }

    private var active: InferenceEngineProtocol {
        switch backend {
        case .llama: return llama
        case .foundationModels: return foundationModels
        }
    }

    var isLoaded: Bool { active.isLoaded }

    var stopAtFirstSentence: Bool {
        get { active.stopAtFirstSentence }
        set { active.stopAtFirstSentence = newValue }
    }
    var maxWords: Int {
        get { active.maxWords }
        set { active.maxWords = newValue }
    }
    var stopAtSentenceAfterWords: Int {
        get { active.stopAtSentenceAfterWords }
        set { active.stopAtSentenceAfterWords = newValue }
    }
    var maxContextTokens: Int {
        get { active.maxContextTokens }
        set { active.maxContextTokens = newValue }
    }

    var modelChatTemplate: String? { active.modelChatTemplate }
    var modelArchitecture: String? { active.modelArchitecture }
    var modelSupportsChat: Bool { active.modelSupportsChat }
    var supportsFIM: Bool { active.supportsFIM }
    var contextWindowTokens: Int { active.contextWindowTokens }

    func load(modelPath: String) throws { try active.load(modelPath: modelPath) }
    func unload() { active.unload() }
    func requestCancel() { active.requestCancel() }
    func releaseSeq(_ seqID: Int32) { active.releaseSeq(seqID) }

    func generate(prompt: String, maxTokens: Int,
                  seqID: Int32, params: SamplingParams,
                  requiredPrefix: [UInt8]?,
                  onToken: (String) -> Bool,
                  onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)?) throws {
        try active.generate(prompt: prompt, maxTokens: maxTokens,
                            seqID: seqID, params: params,
                            requiredPrefix: requiredPrefix,
                            onToken: onToken, onSample: onSample)
    }

    // Forwarded explicitly so the per-call cap reaches the backend that implements it; a backend that
    // doesn't picks up the protocol extension's default (ignore + forward) at this call site.
    func generate(prompt: String, maxTokens: Int,
                  seqID: Int32, params: SamplingParams,
                  contextTokenCap: Int?,
                  requiredPrefix: [UInt8]?,
                  onToken: (String) -> Bool,
                  onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)?) throws {
        try active.generate(prompt: prompt, maxTokens: maxTokens,
                            seqID: seqID, params: params,
                            contextTokenCap: contextTokenCap,
                            requiredPrefix: requiredPrefix,
                            onToken: onToken, onSample: onSample)
    }
}

// Stub for Apple's on-device FoundationModels runtime (macOS 26+). Not yet implemented: it reports
// unloaded and throws on load/generate so the router compiles and the wiring is exercised, without
// pretending to produce completions. Replace with a real FoundationModels-backed implementation.
final class FoundationModelsEngine: InferenceEngineProtocol {
    private(set) var isLoaded: Bool = false
    var stopAtFirstSentence: Bool = false
    var maxWords: Int = 12
    var stopAtSentenceAfterWords: Int = 0
    var maxContextTokens: Int = 4096
    var modelChatTemplate: String? { nil }
    var modelArchitecture: String? { nil }
    var modelSupportsChat: Bool { false }
    var supportsFIM: Bool { false }

    func load(modelPath: String) throws {
        // TODO: bridge Apple FoundationModels (macOS 26+). Unavailable until then.
        throw InferenceError.modelLoadFailed("FoundationModels backend not implemented")
    }

    func unload() {}
    func requestCancel() {}
    func releaseSeq(_ seqID: Int32) {}

    func generate(prompt: String, maxTokens: Int,
                  seqID: Int32, params: SamplingParams,
                  requiredPrefix: [UInt8]?,
                  onToken: (String) -> Bool,
                  onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)?) throws {
        throw InferenceError.notLoaded
    }
}
