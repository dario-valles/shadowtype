// FoundationModelsEngine — Apple's on-device FoundationModels (macOS 26+, Apple Intelligence) behind
// InferenceEngineProtocol. Used ONLY for the opt-in "Rewrite with Apple Intelligence" path; the ghost text
// and the Local API always run on llama.cpp. Measured by FoundationModelsEvalTests (2026-10, M1 Pro,
// macOS 26.6, busy machine) — re-run that spike before widening this:
//
// - Ghost text: NOT viable. Median time to first token is ~390–470 ms reusing a session and ~510–630 ms
//   with a fresh one (prewarm() doesn't help), against the coordinator's 400 ms deadline and llama's
//   ~40 ms — only 1–5 of 30 calls per instruction variant made 400 ms — plus multi-second stalls (3–10 s)
//   on some calls. Short answers arrive as 1–2 snapshots, so streaming buys nothing. A ~1500-token
//   page-context prefix takes ~10–12 s to prefill (llama: ~1.2 s cold, and llama reuses the KV prefix
//   across keystrokes — FM has no such reuse; even prewarm(promptPrefix:) on the page context doesn't
//   help), and ~4350 tokens throws exceededContextWindowSize (4096-token window shared by input +
//   output). There is no raw-prefix continuation API, and the instruct model answers the text instead of
//   continuing it ("I'm here to help!", "I'm sorry, but as a chatbot created by Apple…"), echoes the
//   prefix or wraps it in quotes, depending on the instructions. Catalan isn't a supported language:
//   requests either throw unsupportedLanguageOrLocale or come back in Spanish / broken Catalan.
// - Selection rewrite: viable for supported languages. Fed as a plain prompt (no session instructions):
//   ~0.6–0.9 s to first token and ~1.2–3 s (median ~1.7 s) for a ~50-token rewrite on a moderately
//   loaded machine, in the selection's language for en/es (with the language named in the prompt — a
//   generic "same language" instruction answered a Spanish selection in English). The llama few-shot
//   prompt works too, but the model can answer with the EXEMPLAR's rewrite (Spanish "summarize" returned
//   the exemplar's summary, translated, in 3 of 3 runs), so the coordinator sends
//   RewriteAction.instructionPrompt (zero-shot) instead. Under heavy load single calls stalled for
//   10–60 s, hence `timeout`. The coordinator only routes a rewrite here when the selection's language is
//   one the system model supports, and falls back to llama on any error, timeout or empty result.
// - Chat (/v1/chat/completions shape): fine for en/es (~0.6–3 s), Catalan answered in Spanish with
//   invented content. Not wired: the route renders messages through a GGUF chat template, and serving FM
//   there needs message → instructions/transcript plumbing.
//
// The system model streams in coarse snapshots (1–2 per short response), so generate() buffers the whole
// response, cleans it, and hands it to `onToken` once. It blocks the calling (inference) queue while the
// async request runs, the same contract as the llama engine.
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Whether the system model can be used right now, and which languages it accepts. Thin wrappers so the
// rest of the app (Settings, AppDelegate) never needs `#if canImport` / `#available` of its own.
enum FoundationModelsSupport {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "available"
            case .unavailable(let reason): return "\(reason)"
            }
        }
        #endif
        return "requires macOS 26 with Apple Intelligence"
    }

    // Base language codes ("en", "es", …) the system model accepts; empty when unavailable.
    static var supportedLanguageCodes: Set<String> {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return Set(SystemLanguageModel.default.supportedLanguages.compactMap {
                $0.languageCode?.identifier.lowercased()
            })
        }
        #endif
        return []
    }
}

// Pure post-processing + routing decisions for the system model. No FoundationModels dependency, so it is
// unit-tested hermetically (FoundationModelsEngineTests).
enum FoundationModelsOutput {
    // Should a request in `languageCode` (an NLLanguage raw value such as "es", "zh-Hans"; nil when the
    // language couldn't be detected) go to the system model? Unknown → yes: the model refuses unsupported
    // languages itself and the caller falls back. Known but unsupported (Catalan) → no: the model doesn't
    // always refuse those — it can quietly answer in a neighbouring language.
    static func handlesLanguage(_ languageCode: String?, supported: Set<String>) -> Bool {
        guard let code = languageCode, !code.isEmpty else { return true }
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return supported.contains(base.lowercased())
    }

    // Clean a system-model response to a raw `prompt`: drop a chat preamble line ("Sure, here's the
    // rewritten text:"), an echo of the prompt (whole, or its final cue line such as "Rewritten:"), a
    // paragraph the model repeated, and a single pair of quotes wrapping the whole answer. Trims
    // surrounding whitespace.
    static func clean(_ raw: String, prompt: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = droppingPreamble(s)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty, s.hasPrefix(p) {
            s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let cue = p.split(separator: "\n").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
           !cue.isEmpty, s.hasPrefix(cue) {
            s = String(s.dropFirst(cue.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return unquoted(droppingRepeatedParagraphs(s))
    }

    // The model occasionally says its answer twice ("A\n\nA", or "A\n\nA-cut-off-by-the-token-cap"). Drop a
    // paragraph that repeats an earlier one or is a truncated copy of one.
    static func droppingRepeatedParagraphs(_ s: String) -> String {
        let paragraphs = s.components(separatedBy: "\n\n")
        guard paragraphs.count > 1 else { return s }
        var kept: [String] = []
        var seen: [String] = []
        for p in paragraphs {
            let key = p.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !key.isEmpty, seen.contains(where: { $0 == key || (key.count >= 20 && $0.hasPrefix(key)) }) {
                continue
            }
            kept.append(p)
            seen.append(key)
        }
        return kept.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let preambleOpeners = [
        "sure", "certainly", "of course", "here is", "here's", "here are",
        "claro", "por supuesto", "aquí tienes", "aquí está", "aqui tienes",
        "bien sûr", "voici", "certo", "ecco", "natürlich", "hier ist",
    ]

    // A first line that opens like an assistant ("Sure, …", "Here's …") and ends with ":" is a preamble
    // to the real answer on the following lines.
    private static func droppingPreamble(_ s: String) -> String {
        guard let nl = s.firstIndex(of: "\n") else { return s }
        let first = s[..<nl].trimmingCharacters(in: .whitespaces)
        let lower = first.lowercased()
        guard first.hasSuffix(":"), preambleOpeners.contains(where: { lower.hasPrefix($0) }) else { return s }
        return String(s[s.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let quotePairs: [(Character, Character)] = [
        ("\"", "\""), ("\u{201C}", "\u{201D}"), ("\u{00AB}", "\u{00BB}"), ("'", "'"), ("\u{2018}", "\u{2019}"),
    ]

    // Unwrap one pair of quotes around the whole answer, but only when the opening quote doesn't recur
    // inside (`"a" and "b"` is two quotations, not one wrapped answer).
    private static func unquoted(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, let last = s.last else { return s }
        for (open, close) in quotePairs where first == open && last == close {
            let inner = s.dropFirst().dropLast()
            if inner.contains(open) || inner.contains(close) { return s }
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}

final class FoundationModelsEngine: InferenceEngineProtocol {
    private(set) var isLoaded: Bool = false
    // The ghost stop-policy / window tunables don't apply (this engine never serves the ghost); they are
    // stored so the protocol's setters stay harmless.
    var stopAtFirstSentence: Bool = false
    var maxWords: Int = 12
    var stopAtSentenceAfterWords: Int = 0
    var maxContextTokens: Int = 4096
    var modelChatTemplate: String? { nil }
    var modelArchitecture: String? { isLoaded ? "apple-foundation-models" : nil }
    var modelSupportsChat: Bool { false }
    var supportsFIM: Bool { false }
    // Input + output share this window on the system model.
    var contextWindowTokens: Int { 4096 }

    // Upper bound on one request. Calls usually finish in 1–3 s but stalled for up to a minute on a busy
    // machine; generate() blocks the shared inference queue, so a stuck request would also hold back the
    // ghost. Kept under SelectionRewriteController's 30 s watchdog so the local-model fallback still fits.
    var timeout: TimeInterval = 20

    private let isSystemModelAvailable: () -> Bool
    private let lock = NSLock()
    private var running: (() -> Void)?   // cancels the in-flight request

    init(isSystemModelAvailable: @escaping () -> Bool = { FoundationModelsSupport.isAvailable }) {
        self.isSystemModelAvailable = isSystemModelAvailable
    }

    // `modelPath` is ignored: the system model is managed by the OS. "Loading" just confirms it is usable.
    func load(modelPath: String) throws {
        guard isSystemModelAvailable() else {
            isLoaded = false
            throw InferenceError.modelLoadFailed("Apple Intelligence model unavailable (\(FoundationModelsSupport.unavailableReason))")
        }
        isLoaded = true
    }

    func unload() {
        requestCancel()
        isLoaded = false
    }

    // Cancels only the request in flight; a later generate() starts clean.
    func requestCancel() {
        lock.lock(); let cancel = running; lock.unlock()
        cancel?()
    }

    func releaseSeq(_ seqID: Int32) {}

    func generate(prompt: String, maxTokens: Int,
                  seqID: Int32, params: SamplingParams,
                  requiredPrefix: [UInt8]?,
                  onToken: (String) -> Bool,
                  onSample: ((_ prob: Float, _ isFirstContent: Bool) -> Void)?) throws {
        guard isLoaded else { throw InferenceError.notLoaded }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let raw = try respondBlocking(prompt: prompt, maxTokens: maxTokens, params: params)
            let cleaned = FoundationModelsOutput.clean(raw, prompt: prompt)
            if !cleaned.isEmpty { _ = onToken(cleaned) }
            return
        }
        #endif
        throw InferenceError.notLoaded
    }

    #if canImport(FoundationModels)
    private final class Outcome: @unchecked Sendable {
        var result: Result<String, Error> = .failure(InferenceError.cancelled)
    }

    @available(macOS 26, *)
    private func respondBlocking(prompt: String, maxTokens: Int, params: SamplingParams) throws -> String {
        let options = Self.options(maxTokens: maxTokens, params: params)
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                // No instructions: the measured-good shape is the few-shot prompt as the user turn.
                let session = LanguageModelSession()
                var text = ""
                for try await snapshot in session.streamResponse(to: prompt, options: options) {
                    try Task.checkCancellation()
                    text = snapshot.content
                }
                try Task.checkCancellation()
                outcome.result = .success(text)
            } catch is CancellationError {
                outcome.result = .failure(InferenceError.cancelled)
            } catch {
                outcome.result = .failure(error)
            }
            done.signal()
        }
        lock.lock(); running = { task.cancel() }; lock.unlock()
        let finished = done.wait(timeout: .now() + timeout) == .success
        lock.lock(); running = nil; lock.unlock()
        guard finished else {
            task.cancel()
            throw InferenceError.cancelled
        }
        return try outcome.result.get()
    }

    @available(macOS 26, *)
    private static func options(maxTokens: Int, params: SamplingParams) -> GenerationOptions {
        let tokens = max(1, maxTokens)
        let greedy = params.greedy || params.temperature <= 0
        let mode: GenerationOptions.SamplingMode = greedy
            ? .greedy
            : .random(probabilityThreshold: Double(min(max(params.topP, 0.01), 1)), seed: UInt64(params.seed))
        let temperature: Double? = greedy ? nil : Double(params.temperature)
        // The macOS 27 SDK (Swift 6.4) renamed `sampling:` to `samplingMode:` (back-deployed to 26) and
        // deprecated the old label; older SDKs only have `sampling:`.
        #if compiler(>=6.4)
        return GenerationOptions(samplingMode: mode, temperature: temperature, maximumResponseTokens: tokens)
        #else
        return GenerationOptions(sampling: mode, temperature: temperature, maximumResponseTokens: tokens)
        #endif
    }
    #endif
}
