// ElectronAccessibility — per-pid "force once" bookkeeping. The AX side effect is live-only, but the
// idempotence (one attempt per pid, re-armed by reset) is the contract the focus path relies on to
// stay cheap, and that is pure + testable.
import XCTest
@testable import Shadowtype

final class ElectronAccessibilityTests: XCTestCase {
    func testForcesOncePerPid() {
        let ea = ElectronAccessibility()
        XCTAssertTrue(ea.forceIfNeeded(pid: 4242))   // first attempt
        XCTAssertFalse(ea.forceIfNeeded(pid: 4242))  // already attempted
        XCTAssertFalse(ea.forceIfNeeded(pid: 4242))
    }

    func testDistinctPidsEachForcedOnce() {
        let ea = ElectronAccessibility()
        XCTAssertTrue(ea.forceIfNeeded(pid: 1))
        XCTAssertTrue(ea.forceIfNeeded(pid: 2))
        XCTAssertFalse(ea.forceIfNeeded(pid: 1))
    }

    func testInvalidPidIsNotForced() {
        let ea = ElectronAccessibility()
        XCTAssertFalse(ea.forceIfNeeded(pid: 0))
        XCTAssertFalse(ea.forceIfNeeded(pid: -1))
    }
}
