// GhostFontSizeStabilizer — floors the ghost-font caret height to the smallest value seen during one
// focus session, so a single bad AX poll can't render a comically oversized ghost.
//
// Why this exists: when the host AX font is unavailable, the ghost's point size is derived from the
// caret line height (see CompletionCoordinator.ghostFontSize). AX caret geometry is eventually
// consistent and app-specific: the SAME field can report a tight line-height caret on one poll
// (zero-length BoundsForRange) and the full field-height AXFrame fallback on the next, when the
// precise branches happen to miss. That fluctuation sizes the ghost off the coarse fallback and it
// renders far too large for one frame.
//
// Within a single focus session the real line height does not grow, so we treat the smallest height
// seen as the truth and clamp larger readings down to it. The baseline is keyed by the focus-session
// id (EditContextTracker.focusChangeSequence): switching fields — or leaving and re-entering the same
// field — starts a fresh measurement instead of inheriting a stale ceiling. Biased deliberately
// toward the smaller reading (the over-tall fallback is the observed failure mode); the downstream
// readable-minimum floor in ghostFontSize bounds how small a spurious low reading can make the text.
import CoreGraphics

struct GhostFontSizeStabilizer {
    private var sessionKey: UInt64?
    private var minCaretHeight: CGFloat?

    // Returns the caret height to derive the ghost font size from: the running per-session minimum.
    // Non-positive heights (empty/unusable rects) pass through untouched so a transient bad poll can't
    // pin the session minimum to zero and force every later suggestion to the font-size floor.
    mutating func stabilizedCaretHeight(_ caretHeight: CGFloat, focusSessionKey: UInt64) -> CGFloat {
        guard caretHeight > 0 else { return caretHeight }

        if sessionKey != focusSessionKey {
            sessionKey = focusSessionKey
            minCaretHeight = caretHeight
            return caretHeight
        }

        let stabilized = min(caretHeight, minCaretHeight ?? caretHeight)
        minCaretHeight = stabilized
        return stabilized
    }
}
