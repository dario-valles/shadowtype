// TabSwallowTap.shouldAcceptOnRightArrow — the pure gate for the Right Arrow accept hotkey
// (Smart Compose / Superhuman parity). Swallow only when the ghost is up AND caret is at end-of-line
// AND the user toggled it on AND no modifier is held; any other combination passes Right Arrow
// through so native cursor motion wins.
import XCTest
@testable import Shadowtype

final class RightArrowAcceptTests: XCTestCase {
    func testAcceptsWhenGhostVisibleAndAtLineEndAndEnabledNoModifier() {
        XCTAssertTrue(TabSwallowTap.shouldAcceptOnRightArrow(
            ghostVisible: true, caretAtLineEnd: true, enabled: true, hasModifier: false))
    }

    func testPassesThroughWhenNoGhost() {
        XCTAssertFalse(TabSwallowTap.shouldAcceptOnRightArrow(
            ghostVisible: false, caretAtLineEnd: true, enabled: true, hasModifier: false))
    }

    func testPassesThroughMidLine() {
        // Caret in the middle of a line — Right Arrow MUST keep its cursor-move behavior.
        XCTAssertFalse(TabSwallowTap.shouldAcceptOnRightArrow(
            ghostVisible: true, caretAtLineEnd: false, enabled: true, hasModifier: false))
    }

    func testPassesThroughWhenDisabled() {
        XCTAssertFalse(TabSwallowTap.shouldAcceptOnRightArrow(
            ghostVisible: true, caretAtLineEnd: true, enabled: false, hasModifier: false))
    }

    func testPassesThroughWithAnyModifier() {
        // ⇧→ extends selection, ⌥→ word-jump, ⌘→ line-jump — all native cursor commands.
        XCTAssertFalse(TabSwallowTap.shouldAcceptOnRightArrow(
            ghostVisible: true, caretAtLineEnd: true, enabled: true, hasModifier: true))
    }

    func testRightArrowKeycodeIs124() {
        // kVK_RightArrow per HIToolbox — wire-locks the contract with the CGEvent tap.
        XCTAssertEqual(TabSwallowTap.rightArrowKeycode, 124)
    }
}
