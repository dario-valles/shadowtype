import XCTest
@testable import Shadowtype

final class SelectionRewriteControllerStateTests: XCTestCase {
    func testDoubleTriggerDoesNotStartSecondGeneration() {
        var flow = SelectionRewriteFlowState()

        XCTAssertEqual(flow.beginGeneration(), 1)
        XCTAssertNil(flow.beginGeneration())
        XCTAssertEqual(flow.phase, .generating)
        XCTAssertEqual(flow.activeGeneration, 1)
    }

    func testStaleCallbackCannotCompleteNewGeneration() {
        var flow = SelectionRewriteFlowState()
        let stale = flow.beginGeneration()!
        flow.reset()
        let current = flow.beginGeneration()!

        XCTAssertFalse(flow.completeGeneration(stale, injectionSucceeded: true))
        XCTAssertEqual(flow.phase, .generating)
        XCTAssertEqual(flow.activeGeneration, current)

        XCTAssertTrue(flow.completeGeneration(current, injectionSucceeded: true))
        XCTAssertEqual(flow.phase, .previewing)
    }

    func testInjectionFailureReturnsToIdleAndAllowsRetry() {
        var flow = SelectionRewriteFlowState()
        let failed = flow.beginGeneration()!

        XCTAssertTrue(flow.completeGeneration(failed, injectionSucceeded: false))
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertNil(flow.activeGeneration)

        let retry = flow.beginGeneration()
        XCTAssertNotNil(retry)
        XCTAssertGreaterThan(retry!, failed)
    }

    func testRegenerationUsesNewTokenAndRejectsPriorCallback() {
        var flow = SelectionRewriteFlowState()
        let initial = flow.beginGeneration()!
        XCTAssertTrue(flow.completeGeneration(initial, injectionSucceeded: true))

        let redo = flow.beginRegeneration()!
        XCTAssertGreaterThan(redo, initial)
        XCTAssertFalse(flow.completeGeneration(initial, injectionSucceeded: true))
        XCTAssertEqual(flow.phase, .generating)
        XCTAssertEqual(flow.activeGeneration, redo)
    }
}
