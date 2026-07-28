import XCTest
@testable import Shadowtype

final class PermissionLifecycleTests: XCTestCase {
    func testDeniedGrantedRevokedRegrantedTransitions() {
        var starts = 0
        var stops = 0
        let lifecycle = PermissionLifecycleCoordinator(
            start: { starts += 1 },
            stop: { stops += 1 })

        XCTAssertEqual(
            lifecycle.update(.init(accessibility: false, inputMonitoring: false)),
            .none)
        XCTAssertFalse(lifecycle.isRunning)

        XCTAssertEqual(
            lifecycle.update(.init(accessibility: true, inputMonitoring: true)),
            .started)
        XCTAssertTrue(lifecycle.isRunning)
        XCTAssertEqual(starts, 1)

        XCTAssertEqual(
            lifecycle.update(.init(accessibility: false, inputMonitoring: true)),
            .stopped)
        XCTAssertFalse(lifecycle.isRunning)
        XCTAssertEqual(stops, 1)

        XCTAssertEqual(
            lifecycle.update(.init(accessibility: true, inputMonitoring: true)),
            .started)
        XCTAssertTrue(lifecycle.isRunning)
        XCTAssertEqual(starts, 2)
    }

    func testRepeatedPermissionSamplesAreIdempotent() {
        var starts = 0
        var stops = 0
        let lifecycle = PermissionLifecycleCoordinator(
            start: { starts += 1 },
            stop: { stops += 1 })
        let granted = RequiredPermissionSnapshot(accessibility: true, inputMonitoring: true)
        let denied = RequiredPermissionSnapshot(accessibility: true, inputMonitoring: false)

        XCTAssertEqual(lifecycle.update(granted), .started)
        XCTAssertEqual(lifecycle.update(granted), .none)
        XCTAssertEqual(lifecycle.update(granted), .none)
        XCTAssertEqual(starts, 1)

        XCTAssertEqual(lifecycle.update(denied), .stopped)
        XCTAssertEqual(lifecycle.update(denied), .none)
        XCTAssertEqual(stops, 1)
    }

    func testShutdownStopsRunningPipelineOnlyOnce() {
        var stops = 0
        let lifecycle = PermissionLifecycleCoordinator(start: {}, stop: { stops += 1 })

        _ = lifecycle.update(.init(accessibility: true, inputMonitoring: true))
        lifecycle.shutdown()
        lifecycle.shutdown()

        XCTAssertFalse(lifecycle.isRunning)
        XCTAssertEqual(stops, 1)
    }
}
