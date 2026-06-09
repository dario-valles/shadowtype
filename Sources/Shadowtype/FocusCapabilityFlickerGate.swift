// FocusCapabilityFlickerGate — suppresses a transient "field briefly reports no editable context"
// flicker on the SAME focused element, so the ghost overlay does not tear down and rebuild every time
// a host app momentarily republishes its focused field.
//
// Background: fire() reads the prefix-before-caret fresh on each run. Some Catalyst-style fields
// (Apple Calendar's event editor is the reproduction) briefly drop the text value / selection range
// while they redraw, so currentPrefix() returns nil for a single read and recovers on the next.
// Without this gate that one nil drives clearSuggestion() → overlay.hide().
//
// Scope note: this matters on the re-fire paths where a ghost is ALREADY visible when fire() re-enters
// — the on-pause OCR/page-context re-fire (CompletionCoordinator.refreshOCRContextIfEnabled) and the
// forced-activate hotkey. On the ordinary keystroke path the ghost was already hidden by
// onKeystroke()→cancel() before fire() runs, so there is no visible ghost to preserve there; the gate
// is harmless (it just suppresses a redundant clear + regeneration) but does nothing visible.
//
// The gate is keyed on the focus-session id (EditContextTracker.focusChangeSequence): a nil read on
// the SAME session as the last good read is treated as a flicker and held; a nil read on a different
// (or never-supported) session is a genuine focus change and propagates immediately. A persistent loss
// on the same session still propagates after `requiredConsecutiveMisses` so real focus-loss isn't
// perceptibly delayed.
struct FocusCapabilityFlickerGate {
    // Consecutive no-context reads on the same focus session before the gate releases the teardown.
    // Two is enough to swallow the single-poll flicker without delaying real focus loss perceptibly.
    static let requiredConsecutiveMisses = 2

    enum Decision: Equatable {
        // Act on this read as-is (show/regenerate when context is present, tear down when absent).
        case apply
        // Treat the absent context as a transient flicker: hold the current overlay, do not tear down.
        // `pendingMissCount` is exposed for diagnostic logging only.
        case suppress(pendingMissCount: Int)
    }

    private var lastGoodFocusSeq: UInt64?
    private var consecutiveMisses = 0

    // Feed every read through here. `hasContext` is whether a usable prefix-before-caret was resolved
    // this read; `focusSeq` is the current focus-session id.
    mutating func evaluate(hasContext: Bool, focusSeq: UInt64) -> Decision {
        if hasContext {
            lastGoodFocusSeq = focusSeq
            consecutiveMisses = 0
            return .apply
        }

        // No context. Only debounce when we are still on the focus session that last had context.
        // A different/missing session is a genuine focus change and must propagate immediately.
        guard let last = lastGoodFocusSeq, last == focusSeq else {
            lastGoodFocusSeq = nil
            consecutiveMisses = 0
            return .apply
        }

        consecutiveMisses += 1
        if consecutiveMisses >= Self.requiredConsecutiveMisses {
            lastGoodFocusSeq = nil
            consecutiveMisses = 0
            return .apply
        }
        return .suppress(pendingMissCount: consecutiveMisses)
    }
}
