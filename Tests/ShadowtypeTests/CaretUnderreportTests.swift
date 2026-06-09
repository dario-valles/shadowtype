// EditContextTracker.isTrailingEdgePark — the gate behind correctSingleLineCaretX. It re-anchors a
// caret only when AX parked it at a single-line field's TRAILING edge (the SwiftUI/NSTextField bug),
// NOT when a correct mid-field caret merely looks "drifted" because the measuring font under-estimates
// an enlarged bold line (the Apple Notes title regression that painted the ghost over the title).
import XCTest
import CoreGraphics
import AppKit
@testable import Shadowtype

final class CaretUnderreportTests: XCTestCase {
    // Frame-anchored caret estimate (Electron AXTextArea, no kAXBoundsForRange). A short line that fits the
    // box reports zero soft-wraps and a last-line width below the box width — caret seats right after the text.
    func testShortLineFitsNoWrap() {
        let font = NSFont.systemFont(ofSize: 14)
        let (w, wraps) = EditContextTracker.lastVisualLineWidth(
            "Hy tengo una charla con mi", font: font, width: 638, calibration: 0.86)
        XCTAssertEqual(wraps, 0)
        XCTAssertGreaterThan(w, 0)
        XCTAssertLessThan(w, 638)
    }

    // Claude Code regression: a 124-char line soft-wraps in the 638px box. The LAST visual line must report
    // a non-zero, sub-box width (not the box's left edge) so the ghost lands after the wrapped text, and at
    // least one wrap so the ghost drops to the wrapped line — the old code reset X to minX and painted over it.
    func testLongLineWrapsAndLastLineIsNotLeftEdge() {
        let font = NSFont.systemFont(ofSize: 14)
        let long = String(repeating: "palabra ", count: 18) + "final"   // ~150 chars, wraps in 638px
        let (w, wraps) = EditContextTracker.lastVisualLineWidth(long, font: font, width: 638, calibration: 0.86)
        XCTAssertGreaterThanOrEqual(wraps, 1)
        XCTAssertGreaterThan(w, 0)              // NOT pinned to the left edge
        XCTAssertLessThanOrEqual(w, 638)
    }

    // A single token wider than the box can't break on a space: it gets its own visual line and its width
    // is clamped to the box so the caret never lands off-field to the right.
    func testOverlongTokenClampedToBox() {
        let font = NSFont.systemFont(ofSize: 14)
        let (w, _) = EditContextTracker.lastVisualLineWidth(
            String(repeating: "x", count: 400), font: font, width: 200, calibration: 0.86)
        XCTAssertLessThanOrEqual(w, 200)
    }

    // Empty line: no width, no wraps.
    func testEmptyLine() {
        let (w, wraps) = EditContextTracker.lastVisualLineWidth(
            "", font: NSFont.systemFont(ofSize: 14), width: 638, calibration: 0.86)
        XCTAssertEqual(w, 0)
        XCTAssertEqual(wraps, 0)
    }

    // Real bug: short email in a 300px login row. AX parks the caret at the right edge (~290) while the
    // text ends near the left (~100). Caret is past expectedX AND near frame.maxX → correct it.
    func testTrailingEdgeParkInNarrowField() {
        XCTAssertTrue(EditContextTracker.isTrailingEdgePark(
            axMinX: 290, expectedX: 100, frameMaxX: 300, slop: 13, trailingTolerance: 60))
    }

    // Notes title regression: full-width editor (~1500). The BOLD title is wider than the height-derived
    // measuring font thinks, so the CORRECT AX caret (674) reads as "past expectedX" (599) — but it sits
    // mid-field, nowhere near frame.maxX, so it must NOT be re-anchored.
    func testNotesTitleMidFieldNotCorrected() {
        // trailingTolerance = max(20pt*2, 1500*0.15) = 225 → right region starts at 1500-225 = 1275.
        XCTAssertFalse(EditContextTracker.isTrailingEdgePark(
            axMinX: 674, expectedX: 599, frameMaxX: 1500, slop: 40, trailingTolerance: 225))
    }

    // Caret already at the measured text end (within slop) → nothing to correct, regardless of region.
    func testCaretAtTextEndNotCorrected() {
        XCTAssertFalse(EditContextTracker.isTrailingEdgePark(
            axMinX: 105, expectedX: 100, frameMaxX: 300, slop: 13, trailingTolerance: 60))
    }

    // Near the right edge but the text genuinely fills the field (expectedX ≈ caret) → no correction.
    func testFullFieldNoDriftNotCorrected() {
        XCTAssertFalse(EditContextTracker.isTrailingEdgePark(
            axMinX: 285, expectedX: 284, frameMaxX: 300, slop: 13, trailingTolerance: 60))
    }

    // Past expectedX but NOT in the right region (mid-field drift in a wide field) → no correction.
    func testPastTextButMidFieldNotCorrected() {
        XCTAssertFalse(EditContextTracker.isTrailingEdgePark(
            axMinX: 700, expectedX: 500, frameMaxX: 1500, slop: 13, trailingTolerance: 225))
    }

    // Exactly at the region boundary, and past expectedX → corrected.
    func testAtRegionBoundaryCorrected() {
        XCTAssertTrue(EditContextTracker.isTrailingEdgePark(
            axMinX: 1275, expectedX: 800, frameMaxX: 1500, slop: 13, trailingTolerance: 225))
    }

    // WebKit contenteditable (Apple Mail) stores a trailing space as NBSP (U+00A0); the boundary gate
    // compares against a literal U+0020, so the ghost died on space-press. normalizingSpaces folds the
    // NBSP family back to a regular space — and the trailing char must end up == " ".
    func testNbspTrailingFoldsToSpace() {
        let folded = EditContextTracker.normalizingSpaces("how are you\u{00A0}")
        XCTAssertEqual(folded, "how are you ")
        XCTAssertEqual(folded.last, " ")
    }

    // Narrow + figure NBSP also fold; regular text and newlines are untouched (no phantom spaces).
    func testNbspVariantsFoldAndPlainTextUntouched() {
        XCTAssertEqual(EditContextTracker.normalizingSpaces("a\u{202F}b\u{2007}c"), "a b c")
        XCTAssertEqual(EditContextTracker.normalizingSpaces("line1\nline2 "), "line1\nline2 ")
    }
}
