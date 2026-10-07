import XCTest
import CoreGraphics
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

    // MARK: - window match by frame, for hosts with no AXWindowNumber (Chromium/Electron)

    private let axFrame = CGRect(x: 100, y: 50, width: 800, height: 600)

    private func candidate(_ id: CGWindowID, pid: pid_t = 7, onScreen: Bool = true, layer: Int = 0,
                           frame: CGRect = CGRect(x: 100, y: 50, width: 800, height: 600))
        -> ScreenContextProvider.FrameCandidate {
        .init(windowID: id, owningPID: pid, isOnScreen: onScreen, layer: layer, frame: frame)
    }

    func testFrameMatchResolvesASingleExactMatch() {
        let other = CGRect(x: 0, y: 0, width: 50, height: 50)
        XCTAssertEqual(ScreenContextProvider.resolvedWindowIDByFrame(
            axFrame: axFrame, frontmostPID: 7, candidates: [candidate(1), candidate(2, frame: other)]), 1)
    }

    func testFrameMatchFailsClosedOnTwoMatches() {
        XCTAssertNil(ScreenContextProvider.resolvedWindowIDByFrame(
            axFrame: axFrame, frontmostPID: 7, candidates: [candidate(1), candidate(2)]))
    }

    func testFrameMatchNeverUsesAnotherProcessesWindow() {
        XCTAssertNil(ScreenContextProvider.resolvedWindowIDByFrame(
            axFrame: axFrame, frontmostPID: 7, candidates: [candidate(1, pid: 99)]))
    }

    func testFrameMatchNeverUsesAnOffScreenWindow() {
        XCTAssertNil(ScreenContextProvider.resolvedWindowIDByFrame(
            axFrame: axFrame, frontmostPID: 7, candidates: [candidate(1, onScreen: false)]))
    }

    func testFrameMatchNeverUsesANonZeroLayer() {
        XCTAssertNil(ScreenContextProvider.resolvedWindowIDByFrame(
            axFrame: axFrame, frontmostPID: 7, candidates: [candidate(1, layer: 25)]))
    }

    func testFrameMatchToleranceIsTwoPoints() {
        let inside = CGRect(x: 102, y: 50, width: 800, height: 600)
        let outside = CGRect(x: 103, y: 50, width: 800, height: 600)
        XCTAssertEqual(ScreenContextProvider.resolvedWindowIDByFrame(
            axFrame: axFrame, frontmostPID: 7, candidates: [candidate(1, frame: inside)]), 1)
        XCTAssertNil(ScreenContextProvider.resolvedWindowIDByFrame(
            axFrame: axFrame, frontmostPID: 7, candidates: [candidate(1, frame: outside)]))
    }

    // MARK: - the capture latch: only a window that cannot be captured at all switches OCR context off

    func testOnlyAnUncapturableWindowLatchesOCROff() {
        typealias Outcome = ScreenContextProvider.RecentTextOutcome
        XCTAssertTrue(Outcome.noWindow.cannotCapture)
        XCTAssertTrue(Outcome.unavailable.cannotCapture)
        // Ordinary reasons for "no text right now" must NOT latch: a capture inside minInterval, a blank
        // chat whose only text is UI chrome, and (of course) a capture that returned text.
        XCTAssertFalse(Outcome.throttled.cannotCapture)
        XCTAssertFalse(Outcome.empty.cannotCapture)
        XCTAssertFalse(Outcome.text("hello").cannotCapture)
    }

    func testRecentTextOutcomeCarriesTheTextOnlyWhenThereIsSome() {
        typealias Outcome = ScreenContextProvider.RecentTextOutcome
        XCTAssertEqual(Outcome.text("hello").text, "hello")
        XCTAssertNil(Outcome.empty.text)
        XCTAssertNil(Outcome.throttled.text)
        XCTAssertNil(Outcome.noWindow.text)
    }
}
