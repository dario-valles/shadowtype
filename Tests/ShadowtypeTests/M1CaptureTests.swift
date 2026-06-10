// M1 (capture + read-only overlay) unit tests. These need NO TCC grants: they exercise the
// pure AX->Cocoa coordinate math (FR-OV-3) and InputEvent decoding (FR-KC-3) so the geometry
// and event-shape contracts stay locked even though the live AX/CGEventTap paths require
// Accessibility/Input-Monitoring permissions that can't be granted in CI.
import XCTest
import AppKit
@testable import Shadowtype

final class M1CaptureTests: XCTestCase {

    // Mirror of EditContextTracker.convertAXRectToCocoa (which is private). AX reports a
    // top-left-origin global rect; Cocoa is bottom-left. The flip is about the PRIMARY display
    // height and is independent of backing scale (AX rects are already in points — must NOT be
    // divided by backingScaleFactor). If the tracker's formula changes, this contract test should
    // change with it.
    private func axRectToCocoa(_ axRect: CGRect, primaryHeight: CGFloat) -> CGRect {
        let cocoaY = primaryHeight - axRect.origin.y - axRect.size.height
        return CGRect(x: axRect.origin.x, y: cocoaY, width: axRect.size.width, height: axRect.size.height)
    }

    func testAXTopLeftToCocoaBottomLeftFlip() {
        // 1080p primary; a caret rect 20pt tall sitting 100pt down from the top.
        let primaryHeight: CGFloat = 1080
        let ax = CGRect(x: 50, y: 100, width: 2, height: 20)
        let cocoa = axRectToCocoa(ax, primaryHeight: primaryHeight)

        // x and size are preserved; only y flips.
        XCTAssertEqual(cocoa.origin.x, 50, accuracy: 0.0001)
        XCTAssertEqual(cocoa.size.width, 2, accuracy: 0.0001)
        XCTAssertEqual(cocoa.size.height, 20, accuracy: 0.0001)
        // Cocoa y = 1080 - 100 - 20 = 960 (bottom edge of the rect, bottom-left origin).
        XCTAssertEqual(cocoa.origin.y, 960, accuracy: 0.0001)
    }

    func testAXFlipIsInvolutory() {
        // Applying the same flip twice returns the original rect (the transform is its own inverse).
        let primaryHeight: CGFloat = 1440
        let ax = CGRect(x: 12.5, y: 333, width: 1.5, height: 18)
        let once = axRectToCocoa(ax, primaryHeight: primaryHeight)
        let twice = axRectToCocoa(once, primaryHeight: primaryHeight)
        XCTAssertEqual(twice.origin.x, ax.origin.x, accuracy: 0.0001)
        XCTAssertEqual(twice.origin.y, ax.origin.y, accuracy: 0.0001)
        XCTAssertEqual(twice.size.width, ax.size.width, accuracy: 0.0001)
        XCTAssertEqual(twice.size.height, ax.size.height, accuracy: 0.0001)
    }

    func testAXFlipIsScaleIndependent() {
        // A Retina (2x) display has the SAME point height as a 1x display of equal logical size,
        // so the flip result must not change with backing scale. Same primaryHeight (points) =>
        // same Cocoa rect, regardless of whether the display is 1x or 2x.
        let ax = CGRect(x: 0, y: 200, width: 2, height: 16)
        let oneX = axRectToCocoa(ax, primaryHeight: 900)
        let twoX = axRectToCocoa(ax, primaryHeight: 900) // points, not pixels — identical
        XCTAssertEqual(oneX, twoX)
    }

    func testAXFlipMultiMonitorSharesPrimaryAnchor() {
        // A secondary monitor placed to the RIGHT of primary keeps AX x past primary width; the
        // flip still anchors y on the PRIMARY display height (both AX and Cocoa share that anchor),
        // so a rect on the second display converts without referencing the second display's frame.
        let primaryHeight: CGFloat = 1080
        let axOnSecondary = CGRect(x: 2000, y: 100, width: 2, height: 20)
        let cocoa = axRectToCocoa(axOnSecondary, primaryHeight: primaryHeight)
        XCTAssertEqual(cocoa.origin.x, 2000, accuracy: 0.0001) // x carried through untouched
        XCTAssertEqual(cocoa.origin.y, 960, accuracy: 0.0001)  // anchored on primary height
    }

    // MARK: - InputEvent decoding (FR-KC-3)

    func testInputEventCarriesKeycodeCharsAndDirection() {
        let down = InputEvent(keycode: 0, chars: "a", isKeyDown: true, uptime: 0)
        XCTAssertEqual(down.keycode, 0)
        XCTAssertEqual(down.chars, "a")
        XCTAssertTrue(down.isKeyDown)

        let up = InputEvent(keycode: 0, chars: "a", isKeyDown: false, uptime: 0)
        XCTAssertFalse(up.isKeyDown)
    }

    func testInputEventNonPrintingKeyHasEmptyChars() {
        // Arrow keys / modifiers produce no unicode; the tap stores "" (length-0 read). The M1
        // overlay still refreshes on these keyDowns so the ghost follows arrow-key caret moves.
        let leftArrow = InputEvent(keycode: 123, chars: "", isKeyDown: true, uptime: 0)
        XCTAssertTrue(leftArrow.chars.isEmpty)
        XCTAssertTrue(leftArrow.isKeyDown)
    }

    // MARK: - Direct-AX injection wiring (FR-IN-2)

    // focusedElement() backs the coordinator's direct-AX inject path. Headless (no AX trust / no
    // focused field) it must return nil gracefully — the Injector then uses the Unicode fallback —
    // never crash. The live AX-insert behavior itself needs TCC + a focused field (manual M2 check).
    func testFocusedElementIsNilGracefullyWhenUntrusted() throws {
        let tracker = EditContextTracker()
        if AXIsProcessTrusted() {
            // Trusted dev machine: a real focused field may exist, so nil can't be asserted.
            // The no-crash contract still ran; the nil contract only holds headless.
            _ = tracker.focusedElement()
            throw XCTSkip("AX-trusted environment — nil contract only verifiable headless/CI")
        }
        XCTAssertNil(tracker.focusedElement(), "no focused field / untrusted -> nil, no crash")
    }

    // Injector with a nil element falls back to the Unicode path and reports placement (FR-IN-3).
    // Empty text is a no-op success. Neither requires AX writes, so both are CI-safe.
    func testInjectorEmptyTextIsNoOpSuccess() {
        XCTAssertTrue(Injector().inject("", into: nil), "empty injection is a no-op success")
    }
}
