import XCTest
@testable import Shadowtype

final class ScreenContextProviderStateTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 10_000)

    func testCacheExpiresAfterTTLThenStartsFreshCapture() {
        var state = ScreenContextProvider.CacheState()
        let first = state.begin(at: origin, cacheTTL: 1, minInterval: 1)
        guard case .capture(let ticket) = first else { return XCTFail("expected capture") }
        XCTAssertTrue(state.store("first", for: ticket, at: origin))

        XCTAssertEqual(state.begin(at: origin.addingTimeInterval(0.9), cacheTTL: 1, minInterval: 1),
                       .cached("first"))
        guard case .capture = state.begin(at: origin.addingTimeInterval(1.0), cacheTTL: 1, minInterval: 1) else {
            return XCTFail("expired OCR must not be served")
        }
    }

    func testFailedCaptureClearsPreviousCachedText() {
        var state = ScreenContextProvider.CacheState()
        guard case .capture(let first) = state.begin(at: origin, cacheTTL: 10, minInterval: 1) else {
            return XCTFail("expected initial capture")
        }
        XCTAssertTrue(state.store("stale", for: first, at: origin))

        guard case .capture(let retry) = state.begin(at: origin.addingTimeInterval(10), cacheTTL: 1, minInterval: 1) else {
            return XCTFail("expected retry")
        }
        state.captureFailed(for: retry)
        XCTAssertEqual(state.begin(at: origin.addingTimeInterval(10.1), cacheTTL: 10, minInterval: 1), .suppressed)
    }

    func testFocusChangeClearsCacheAndRejectsLateCapture() {
        var state = ScreenContextProvider.CacheState()
        guard case .capture(let oldTicket) = state.begin(at: origin, cacheTTL: 10, minInterval: 1) else {
            return XCTFail("expected initial capture")
        }
        XCTAssertTrue(state.store("old focus", for: oldTicket, at: origin))

        state.focusDidChange()
        XCTAssertFalse(state.store("late old focus", for: oldTicket, at: origin.addingTimeInterval(0.1)))
        guard case .capture(let newTicket) = state.begin(at: origin.addingTimeInterval(0.1), cacheTTL: 10, minInterval: 1) else {
            return XCTFail("focus reset must bypass the old throttle")
        }
        XCTAssertTrue(state.store("new focus", for: newTicket, at: origin.addingTimeInterval(0.1)))
        XCTAssertEqual(state.begin(at: origin.addingTimeInterval(0.2), cacheTTL: 10, minInterval: 1),
                       .cached("new focus"))
    }

    func testWindowSelectionRequiresExactAXWindowAndFrontmostOwner() {
        let candidates: [ScreenContextProvider.WindowCandidate] = [
            .init(windowID: 101, owningPID: 42, isOnScreen: true),
            .init(windowID: 202, owningPID: 42, isOnScreen: true),
            .init(windowID: 303, owningPID: 99, isOnScreen: true),
        ]

        XCTAssertEqual(ScreenContextProvider.resolvedFocusedWindowID(
            focusedWindowID: 202, frontmostPID: 42, candidates: candidates), 202)
        XCTAssertNil(ScreenContextProvider.resolvedFocusedWindowID(
            focusedWindowID: 303, frontmostPID: 42, candidates: candidates))
        XCTAssertNil(ScreenContextProvider.resolvedFocusedWindowID(
            focusedWindowID: nil, frontmostPID: 42, candidates: candidates))
    }
}
