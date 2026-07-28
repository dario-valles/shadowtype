import XCTest
@testable import Shadowtype

final class InferenceCancellationTests: XCTestCase {
    func testCancellingSequenceZeroDoesNotCancelSequenceOne() throws {
        let registry = InferenceEngine.CancellationRegistry()
        let api = try XCTUnwrap(registry.begin(seqID: 1))

        registry.cancel(seqID: 0)

        XCTAssertFalse(registry.isCancelled(api))
        registry.end(api)
    }

    func testActiveCancellationReportsCancelled() throws {
        let registry = InferenceEngine.CancellationRegistry()
        let request = try XCTUnwrap(registry.begin(seqID: 1))

        registry.cancel(seqID: 1)

        XCTAssertTrue(registry.isCancelled(request))
        registry.end(request)
    }

    func testCancelledAPIContinuationThrowsCancelled() {
        XCTAssertThrowsError(try InferenceEngine.requireAPIContinuation(false)) { error in
            guard case InferenceError.cancelled = error else {
                return XCTFail("expected cancelled, got \(error)")
            }
        }
        XCTAssertNoThrow(try InferenceEngine.requireAPIContinuation(true))
    }

    func testIdleCancellationDoesNotPoisonFutureRequest() throws {
        let registry = InferenceEngine.CancellationRegistry()

        registry.cancel(seqID: 1)

        let future = try XCTUnwrap(registry.begin(seqID: 1))
        XCTAssertFalse(registry.isCancelled(future))
        registry.end(future)
    }
}
