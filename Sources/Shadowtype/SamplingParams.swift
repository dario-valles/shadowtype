// SamplingParams — per-request sampler configuration. Threaded through the engine so the existing
// ghost-text path and the upcoming /v1 API path can coexist with different sampling behavior in the
// same llama context. Ghost passes `.ghostDefaults` (byte-identical to the pre-M0 hardcoded chain);
// API/MCP build params from the request body via `apiClamped(...)`.
//
// `useEngineStopPolicy` is the early-branch flag inside `InferenceEngine.generate`:
//   - true  (ghost): keep word-buffering, sentence detection, leading-newline strip, maxWords cap.
//   - false (API):   stream tokens verbatim; only maxTokens, EOG, and `stopStrings` end the run.
import Foundation

// M5 FIM (fill-in-middle) request payload. When non-nil AND the loaded model exposes FIM tokens
// via `llama_vocab_fim_{pre,suf,mid}`, the engine builds a manual token stream
// `[fim_pre, ...prefix, fim_suf, ...suffix, fim_mid]` instead of tokenizing the raw prompt
// straight. The model then generates the "middle" text — the code that goes between prefix and
// suffix. Used by /v1/completions when the OpenAI-shape `suffix` field is set (Cursor, Continue,
// llm-cli, any Copilot-style flow). Pure data — no llama types — so SamplingParams stays
// CLlama-free and importable from tests.
struct FIMRequest: Sendable, Equatable {
    var prefix: String
    var suffix: String
}

struct SamplingParams: Sendable, Equatable {
    var temperature: Float
    var topP: Float
    var topK: Int32
    var repeatPenalty: Float
    var repeatPenaltyLastN: Int32
    var seed: UInt32
    var greedy: Bool

    // Stop substrings (API only). Engine scans the streaming text and halts as soon as any of
    // these is observed; OpenAI semantics — the stop string is NOT included in the emitted output.
    var stopStrings: [String]

    // See file header. The ghost path sets this true to preserve the legacy behavior; the API path
    // sets it false to stream raw tokens governed only by maxTokens and stopStrings.
    var useEngineStopPolicy: Bool

    // M5 FIM. nil = raw prompt continuation (the default); non-nil = the engine wraps prefix+suffix
    // in the model's FIM tokens. Engine rejects non-nil when the loaded model lacks FIM tokens.
    var fim: FIMRequest?

    static let ghostDefaults = SamplingParams(
        temperature: 0.4,
        topP: 0.9,
        topK: 40,
        repeatPenalty: 1.1,
        repeatPenaltyLastN: 64,
        seed: 0xACE1,
        greedy: false,
        stopStrings: [],
        useEngineStopPolicy: true,
        fim: nil
    )

    // Single shell-command completion (terminal shell-command mode). Deterministic and command-shaped:
    // streams raw tokens (useEngineStopPolicy=false, so the prose word-buffer + sentence/maxWords cap is
    // bypassed) and halts at the first newline so EXACTLY ONE command line is produced. Lower temp than
    // ghost for path/flag determinism; a modest top-k avoids exotic hallucinated flags. The `"$ "` /
    // `"\n$ "` stops guard against the base model emitting the NEXT few-shot turn before a newline.
    static let commandDefaults = SamplingParams(
        temperature: 0.2,
        topP: 0.9,
        topK: 40,
        repeatPenalty: 1.1,
        repeatPenaltyLastN: 64,
        seed: 0xACE1,
        greedy: false,
        stopStrings: ["\n", "\n$ ", "$ "],
        useEngineStopPolicy: false,
        fim: nil
    )

    // OpenAI-ish defaults for API requests: temp 0.7, no top-k (we still apply a high cap to keep
    // candidate scans cheap), no repeat penalty (clients add their own). `apiClamped` overrides
    // these from the request body and re-flags `greedy` when temperature is exactly 0.
    static let apiDefaults = SamplingParams(
        temperature: 0.7,
        topP: 1.0,
        topK: 1000,
        repeatPenalty: 1.0,
        repeatPenaltyLastN: 0,
        seed: 0,
        greedy: false,
        stopStrings: [],
        useEngineStopPolicy: false,
        fim: nil
    )

    // Build API sampling params from an OpenAI-shape request body, clamping each field to a safe
    // range. Caller passes nil for missing fields so server defaults apply. temperature == 0
    // collapses to greedy decoding (matches OpenAI's deterministic-when-zero contract).
    static func apiClamped(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        repeatPenalty: Double? = nil,
        seed: Int? = nil,
        stop: [String] = [],
        fim: FIMRequest? = nil,
        ghostStopPolicy: Bool = false
    ) -> SamplingParams {
        // Non-OpenAI debug extension: when `ghostStopPolicy` is set, start from the GHOST defaults
        // (temp 0.4, repeat penalty, useEngineStopPolicy=true) instead of the raw API defaults, so a
        // local QA harness can exercise the exact ghost decode loop (leading-newline strip + continue,
        // sentence/word-cap stops) over /v1/completions. Body fields still override sampling below.
        var p = ghostStopPolicy ? ghostDefaults : apiDefaults
        if let t = temperature { p.temperature = Float(max(0.0, min(2.0, t))) }
        if let tp = topP { p.topP = Float(max(0.0, min(1.0, tp))) }
        if let tk = topK { p.topK = Int32(max(1, min(10_000, tk))) }
        if let rp = repeatPenalty { p.repeatPenalty = Float(max(0.5, min(2.0, rp))) }
        if let s = seed { p.seed = UInt32(truncatingIfNeeded: s) }
        p.stopStrings = Array(stop.prefix(16))  // OpenAI allows up to 4 user stops; the chat path
                                                 // also prepends ~6 turn-end sentinels, so keep headroom.
        if p.temperature == 0 { p.greedy = true }
        p.fim = fim
        return p
    }
}
