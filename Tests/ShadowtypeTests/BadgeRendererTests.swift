// BadgeRenderer geometry — the only headlessly-testable part (the NSPanel itself needs a GUI).
// Verifies the active-field chip lands just left of the field, vertically centred, and clamps to
// the screen's left edge instead of disappearing past the bezel.
import XCTest
@testable import Shadowtype

final class BadgeRendererTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testSitsInLeftGutterVerticallyCentred() {
        let field = CGRect(x: 400, y: 500, width: 300, height: 40)   // Cocoa bottom-left
        let origin = BadgeRenderer.badgeOrigin(for: field, size: 20, gap: 6, screen: screen)
        XCTAssertEqual(origin.x, 400 - 20 - 6, accuracy: 0.001)      // left of the field's left edge
        XCTAssertEqual(origin.y, 500 + 20 - 10, accuracy: 0.001)     // midY (520) - size/2 (10)
    }

    func testAnchorsToCaretLineNotTallFieldCentre() {
        // A tall (mostly empty) Gmail-style compose: the caret sits near the top, far above the field's
        // own midY. The chip must follow the caret line, not float at the box centre.
        let field = CGRect(x: 400, y: 200, width: 600, height: 400)   // midY = 400
        let caret = CGRect(x: 410, y: 560, width: 0, height: 16)       // caret line near the top
        let origin = BadgeRenderer.badgeOrigin(for: field, caret: caret, size: 20, gap: 6, screen: screen)
        XCTAssertEqual(origin.x, 400 - 20 - 6, accuracy: 0.001)        // still in the left gutter
        XCTAssertEqual(origin.y, caret.midY - 10, accuracy: 0.001)     // tracks the caret, not field.midY
    }

    func testFallsBackToFieldCentreWithoutUsableCaret() {
        let field = CGRect(x: 400, y: 500, width: 300, height: 40)
        // Null caret and a zero-height caret both fall back to the field centre.
        XCTAssertEqual(BadgeRenderer.badgeOrigin(for: field, caret: .null, size: 20, gap: 6, screen: screen).y,
                       field.midY - 10, accuracy: 0.001)
        let zeroH = CGRect(x: 410, y: 700, width: 0, height: 0)
        XCTAssertEqual(BadgeRenderer.badgeOrigin(for: field, caret: zeroH, size: 20, gap: 6, screen: screen).y,
                       field.midY - 10, accuracy: 0.001)
    }

    func testClampsToScreenLeftEdge() {
        let field = CGRect(x: 2, y: 100, width: 300, height: 40)     // flush against the left edge
        let origin = BadgeRenderer.badgeOrigin(for: field, size: 20, gap: 6, screen: screen)
        XCTAssertEqual(origin.x, screen.minX, accuracy: 0.001)       // clamped on-screen, never negative
    }

    func testRespectsNonZeroScreenOrigin() {
        // Secondary display to the left of the primary (negative origin).
        let left = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        let field = CGRect(x: -1278, y: 200, width: 200, height: 30)
        let origin = BadgeRenderer.badgeOrigin(for: field, size: 20, gap: 6, screen: left)
        XCTAssertEqual(origin.x, left.minX, accuracy: 0.001)         // clamps to that screen's minX
    }
}
