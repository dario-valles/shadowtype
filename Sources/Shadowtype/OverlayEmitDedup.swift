// OverlayEmitDedup — pure decision for whether overlay.show() should be called given the last
// text we emitted. Sibling of OverlayStabilityGate, applied at the metal boundary.
//
// Why this exists: the stability gate's snapshot (lastRenderedOverlay) is reset by every
// clearSuggestion()/untrackOverlay() call — so a context-driven re-fire that briefly clears and
// then re-generates the IDENTICAL text passes the gate and the user sees the same ghost shown
// back-to-back. This second gate persists across that clear for a short window so the duplicate
// emission is dropped before it ever reaches the panel.
import Foundation

enum OverlayEmitDedup {
    // Long enough to absorb a re-fire's cancel→bumpGen→regenerate round-trip on local M-series
    // hardware; short enough that a user-initiated cycle (Esc + retype the same text) still feels
    // responsive instead of mysteriously silent.
    static let windowSeconds: TimeInterval = 0.6

    struct State: Equatable {
        var text: String
        var focusSeq: UInt64
        var emittedAt: TimeInterval
    }

    // True when the caller should drop this emit (a same-text re-show on the same focus session
    // inside the window). False when the emit should proceed. Pure + testable.
    //
    // `presented` MUST be whether that ghost is still actually on screen. The dedup record can outlive
    // the on-screen ghost (it is intentionally kept across a clearSuggestion() during a context re-fire,
    // so the record persists past an overlay.hide()). Suppressing a re-show when nothing is presented
    // would leave suggestionVisible=true over an empty field — a phantom Tab-accept inserting unseen
    // text. So a re-show is only a "duplicate" worth dropping when the ghost is genuinely still up.
    static func shouldDrop(last: State?, text: String, focusSeq: UInt64, now: TimeInterval,
                           presented: Bool) -> Bool {
        guard presented else { return false }   // nothing on screen → this is the FIRST show, not a dupe
        guard let last else { return false }
        guard last.focusSeq == focusSeq else { return false }
        guard last.text == text else { return false }
        return (now - last.emittedAt) < windowSeconds
    }
}
