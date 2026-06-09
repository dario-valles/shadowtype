// Aggressiveness — how eagerly the inline completer fires.
//
// Research finding (deep-research, Jun 2026): the single biggest lever on inline-completion
// acceptance is WHEN a suggestion fires, not how good the model is. Firing on every keystroke or a
// fixed short delay produces "blind rejections" — suggestions dismissed in <0.3 s, before the user
// could even read them. Waiting for a *natural typing pause* instead raised acceptance roughly
// 4.9% → 18.6% and cut blind rejections ~8.3% → 0.3% (arXiv 2511.18842).
//
// A fixed delay can't fit everyone: a fast typist's natural pause is far shorter than a hunt-and-peck
// typist's, so any single threshold either nags one or feels laggy to the other. So the coordinator
// adapts the wait to the user's own recent inter-keystroke cadence (see CompletionCoordinator), and
// THIS setting is the user-facing dial on that behavior: it multiplies the user's median cadence to
// decide how long a confirmed pause must be before a suggestion fires.
//
// This is a FREE, core-UX control (not Pro): it improves the product for everyone and gating it would
// only hurt the funnel the research says it most helps. The stored value lives in plain UserDefaults
// (a benign preference, like AppRules / CompletionLength — no HMAC/Keychain à la WordMeter).
import Foundation

/// User-facing trigger aggressiveness. `Identifiable` + `CaseIterable` so a SwiftUI segmented picker
/// can drive it directly from `allCases`.
enum Aggressiveness: String, CaseIterable, Identifiable {
    case conservative
    case balanced
    case eager

    var id: String { rawValue }

    /// Multiplier applied to the user's recent median inter-keystroke interval to set the confirmed-pause
    /// threshold before firing. Higher waits for a clearer pause (fewer, higher-value suggestions, fewer
    /// blind rejections); lower fires on a briefer lull (snappier, more frequent). The coordinator clamps
    /// the result to `[debounce floor, ceiling]`, so these never produce a runaway wait.
    var pauseMultiplier: Double {
        switch self {
        case .conservative: return 3.3
        case .balanced:     return 2.3
        case .eager:        return 1.5
        }
    }

    /// Title-cased label for a Settings picker.
    var displayName: String {
        switch self {
        case .conservative: return "Conservative"
        case .balanced:     return "Balanced"
        case .eager:        return "Eager"
        }
    }

    // MARK: - Stored preference

    /// UserDefaults key for the user's chosen aggressiveness. Stored as the enum `rawValue` string.
    static let defaultsKey = "shadowtype.aggressiveness"

    /// The effective aggressiveness to apply right now. Defaults to `.balanced` when unset or unrecognized.
    /// `defaults` is injectable purely for hermetic tests; production passes `.standard`.
    static func current(defaults: UserDefaults = .standard) -> Aggressiveness {
        guard let raw = defaults.string(forKey: defaultsKey),
              let value = Aggressiveness(rawValue: raw) else { return .balanced }
        return value
    }
}
