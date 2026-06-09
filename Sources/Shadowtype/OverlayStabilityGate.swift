// OverlayStabilityGate — pure decision for whether a render tick should reposition the visible
// ghost-text overlay, or hold the existing geometry exactly as last drawn.
//
// Why this exists: renderSuggestion runs many times per suggestion — on every streamed token and on
// the remainder re-render after a Tab-accept. AX commonly returns a slightly drifted caretRect after
// a synthesized insertion, and re-presenting against those drifted measurements is what causes the
// visible one-frame "shift left and down, then snap back" on accept. This gate holds the existing
// overlay frame whenever the focus session, displayed text, and caret rect have not materially moved;
// legitimate changes (field switch, window move, text change, fresh show) still re-anchor.
import AppKit
import CoreGraphics

enum OverlayStabilityGate {
    // Slack absorbed when comparing the caret rect between renders. 1pt swallows the sub-pixel noise
    // that mixed Retina/non-Retina setups produce on consecutive AX reads of the same caret, while
    // still catching whole-pixel movement from a real caret advance or window drag. Drift is compared
    // against the LAST-DRAWN caret, so monotonic sub-tolerance creep accumulates against that fixed
    // reference and trips this threshold within ~1pt of lag — it does not silently grow unbounded.
    static let caretTolerance: CGFloat = 1

    // Tolerance for the fade opacity; below this the change isn't visible. Small enough that every real
    // cap-fade step re-presents (so the fade can't freeze), large enough to ignore float noise.
    static let opacityTolerance: CGFloat = 0.0001

    // Everything about the last overlay we actually drew that, if changed, must redraw. nil means
    // nothing is currently shown. `fontKey` is a stable string identity for the host font (see fontKey),
    // since NSFont isn't trivially Equatable for synthesis.
    struct Rendered: Equatable {
        var text: String
        var caretRect: CGRect
        var focusSeq: UInt64
        var opacity: CGFloat
        var rtl: Bool
        var fontKey: String?
    }

    // A stable identity string for a host font, or nil when the overlay uses its default font.
    static func fontKey(_ font: NSFont?) -> String? {
        guard let font else { return nil }
        return "\(font.fontName):\(font.pointSize)"
    }

    // Returns true when the caller should call overlay.show for this render tick; false to hold the
    // existing overlay exactly as drawn. Re-anchors when nothing is shown, or the focus session, text,
    // fade opacity, RTL side, host font, or caret rect (beyond tolerance) changed.
    static func shouldRePresent(last: Rendered?, candidate: Rendered) -> Bool {
        guard let last else { return true }
        if last.focusSeq != candidate.focusSeq { return true }
        if last.text != candidate.text { return true }
        if last.rtl != candidate.rtl { return true }
        if last.fontKey != candidate.fontKey { return true }
        if abs(last.opacity - candidate.opacity) > opacityTolerance { return true }
        return !rectsClose(last.caretRect, candidate.caretRect)
    }

    private static func rectsClose(_ a: CGRect, _ b: CGRect) -> Bool {
        // A null rect (no caret geometry → chip fallback) is only "close" to another null rect.
        if a.isNull || b.isNull { return a.isNull && b.isNull }
        return abs(a.origin.x - b.origin.x) <= caretTolerance
            && abs(a.origin.y - b.origin.y) <= caretTolerance
            && abs(a.size.width - b.size.width) <= caretTolerance
            && abs(a.size.height - b.size.height) <= caretTolerance
    }
}
