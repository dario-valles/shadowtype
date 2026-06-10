// CompletionLength — "configurable completion length" (FR-CE-3). The stream stops on the first
// sentence/line boundary OR `maxCompletionTokens`. This type is that knob: a small enum that maps a
// user-facing length to the two numeric stops the pipeline already uses — the engine's `maxWords`
// (the word-count boundary, see InferenceEngine.maxWords) and the coordinator's `maxTokens` ceiling
// (see CompletionCoordinator).
//
// `.short` is a tight 1–2 word phrase continuation (maxWords 2 under a maxTokens 8 ceiling); the
// longer cases step them up. Shadowtype is free, so every length is selectable. The stored value
// lives in plain UserDefaults (a benign user preference, like AppRules).
import Foundation

/// User-facing completion length (FR-CE-3). Every length is freely selectable. `Identifiable` +
/// `CaseIterable` so a SwiftUI picker can drive it directly from `allCases`.
enum CompletionLength: String, CaseIterable, Identifiable {
    case short
    case medium
    case long
    case extraLong

    var id: String { rawValue }

    /// The word-count boundary handed to `InferenceEngine.maxWords`. The engine stops the stream once
    /// this many whole words have been emitted (it also stops earlier on EOG/newline/sentence). These
    /// are the *intended* output lengths:
    /// - `.short`  = 2 words — the free behavior, a 1–2 word phrase continuation.
    /// - `.medium` = 5 words — a short clause.
    /// - `.long`   = 12 words — a phrase or short sentence.
    /// - `.extraLong` = 18 words — a full sentence / Cotypist "Ultra Long". Paired with a sentence-aware
    ///   stop (see `sentenceStopAfterWords`) so the longer budget ends on punctuation, not mid-clause.
    var maxWords: Int {
        switch self {
        case .short:     return 2
        case .medium:    return 5
        case .long:      return 12
        case .extraLong: return 18
        }
    }

    /// Once this many words are out, the engine ends the stream at the NEXT sentence boundary (`. ! ?`)
    /// instead of running to the hard `maxWords` cap — so long completions finish a clause cleanly
    /// rather than truncating mid-sentence. 0 disables it (short/medium are already tight enough that
    /// a sentence stop would just shorten them). See `InferenceEngine.stopAtSentenceAfterWords`.
    var sentenceStopAfterWords: Int {
        switch self {
        case .short, .medium: return 0
        case .long:           return 6
        case .extraLong:      return 9
        }
    }

    /// The token ceiling handed to the coordinator (`CompletionCoordinator` → `engine.generate(maxTokens:)`).
    /// This is a *safety ceiling*, not the target length: it must always sit comfortably ABOVE `maxWords`
    /// so the word boundary (`maxWords`) is what actually ends a normal completion, while this still caps
    /// pathological runs (rare tokens, no whitespace). We mirror the existing free relationship — maxWords
    /// boundary under a token ceiling with headroom — at every step.
    /// - `.short`  = 8.
    /// - `.medium` = 16.
    /// - `.long`   = 24.
    var maxTokens: Int {
        switch self {
        case .short:     return 8
        case .medium:    return 16
        case .long:      return 24
        case .extraLong: return 40
        }
    }

    /// Title-cased label for a Settings picker.
    var displayName: String {
        switch self {
        case .short:     return "Short"
        case .medium:    return "Medium"
        case .long:      return "Long"
        case .extraLong: return "Extra Long"
        }
    }

    // MARK: - Stored preference

    /// UserDefaults key for the user's chosen length. Stored as the enum `rawValue` string.
    static let defaultsKey = "shadowtype.completionLength"

    /// The effective length to apply right now: the stored value, defaulting to `.medium` when unset
    /// or unrecognized.
    ///
    /// `defaults` is injectable purely for hermetic tests; production passes `.standard`.
    static func current(defaults: UserDefaults = .standard) -> CompletionLength {
        guard let raw = defaults.string(forKey: defaultsKey),
              let length = CompletionLength(rawValue: raw) else { return .medium }
        return length
    }
}
