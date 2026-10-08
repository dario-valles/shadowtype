// The first-capture gate: fire() waits for a focus's FIRST OCR capture, never for later ones.
//
// In 0.6.1 a capture that came back empty (no resolvable window, a blank screen, a throttled call) set
// `.ready`, but the next pause re-armed `.pending` because the cache was still empty, and the deferred
// fire only re-ran when the context CHANGED (nil -> nil never does). A field whose window OCR could not
// read therefore never showed a suggestion. These tests pin both halves of the fix.
import XCTest
@testable import Shadowtype

final class CaptureGateTests: XCTestCase {
    func testFirstCaptureOfAFocusArmsTheGate() {
        let a = CompletionContextAssembler()
        XCTAssertEqual(a.captureState, .idle)
        a.markCapturePendingIfEmpty()
        XCTAssertEqual(a.captureState, .pending)
    }

    func testAnEmptyCompletedCaptureDoesNotReArmTheGate() {
        let a = CompletionContextAssembler()
        a.markCapturePendingIfEmpty()
        a.captureState = .ready          // the capture landed with no text
        XCTAssertNil(a.cachedOCR)
        a.markCapturePendingIfEmpty()    // the next pause
        XCTAssertEqual(a.captureState, .ready, "an empty capture must leave fire() prefix-only, not waiting again")
    }

    func testAFocusChangeReArmsTheGate() {
        let a = CompletionContextAssembler()
        a.captureState = .ready
        a.captureState = .idle           // what focusDidChange() / focus-in do
        a.markCapturePendingIfEmpty()
        XCTAssertEqual(a.captureState, .pending)
    }

    func testCachedContextNeverArmsTheGate() {
        let a = CompletionContextAssembler()
        a.storeOCR("Some text on screen") { _ in nil }
        a.markCapturePendingIfEmpty()
        XCTAssertEqual(a.captureState, .idle)
    }

    func testADeferredFireRunsEvenWhenTheCaptureBroughtNothing() {
        XCTAssertTrue(CompletionContextAssembler.shouldRefireAfterCapture(changed: false, fireDeferred: true))
        XCTAssertTrue(CompletionContextAssembler.shouldRefireAfterCapture(changed: true, fireDeferred: false))
        XCTAssertTrue(CompletionContextAssembler.shouldRefireAfterCapture(changed: true, fireDeferred: true))
        XCTAssertFalse(CompletionContextAssembler.shouldRefireAfterCapture(changed: false, fireDeferred: false))
    }
}
