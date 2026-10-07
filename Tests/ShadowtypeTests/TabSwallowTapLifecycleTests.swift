import AppKit
import XCTest
@testable import Shadowtype

final class TabSwallowTapLifecycleTests: XCTestCase {
    private final class Recorder {
        let lock = NSLock()
        var createdOnMain: [Bool] = []
        var enables: [Bool] = []
        var invalidated = 0

        func record(_ body: (Recorder) -> Void) {
            lock.lock()
            body(self)
            lock.unlock()
        }
    }

    private func makePort() -> CFMachPort {
        var context = CFMachPortContext()
        return CFMachPortCreate(nil, nil, &context, nil)!
    }

    private func runtime(_ recorder: Recorder,
                         failFirst: Bool = false) -> TabSwallowTap.Runtime {
        TabSwallowTap.Runtime(
            createTap: { _, _, _ in
                var shouldFail = false
                recorder.record {
                    shouldFail = failFirst && $0.createdOnMain.isEmpty
                    $0.createdOnMain.append(Thread.isMainThread)
                }
                return shouldFail ? nil : self.makePort()
            },
            setTapEnabled: { _, enabled in recorder.record { $0.enables.append(enabled) } },
            invalidateTap: { port in
                recorder.record { $0.invalidated += 1 }
                CFMachPortInvalidate(port)
            }
        )
    }

    // The active tap delays every keystroke on the system until its callback returns, so it must
    // never be serviced by the main run loop (synchronous AX + overlay work lives there).
    func testActiveTapIsCreatedOffTheMainThread() {
        let recorder = Recorder()
        let tap = TabSwallowTap(runtime: runtime(recorder)) { $0() }

        tap.start()
        XCTAssertTrue(tap.isRunning)
        tap.stop()

        recorder.lock.lock()
        defer { recorder.lock.unlock() }
        XCTAssertEqual(recorder.createdOnMain, [false])
    }

    func testStartIsIdempotentAndStopTearsDownOnce() {
        let recorder = Recorder()
        let tap = TabSwallowTap(runtime: runtime(recorder)) { $0() }

        tap.start()
        tap.start()
        tap.stop()
        tap.stop()

        XCTAssertFalse(tap.isRunning)
        recorder.lock.lock()
        defer { recorder.lock.unlock() }
        XCTAssertEqual(recorder.createdOnMain.count, 1)
        XCTAssertEqual(recorder.enables, [true, false])
        XCTAssertEqual(recorder.invalidated, 1)
    }

    func testFailedCreationDoesNotLatchAndLaterStartSucceeds() {
        let recorder = Recorder()
        let tap = TabSwallowTap(runtime: runtime(recorder, failFirst: true)) { $0() }

        tap.start()
        XCTAssertFalse(tap.isRunning)

        tap.start()
        XCTAssertTrue(tap.isRunning)

        tap.stop()
        XCTAssertFalse(tap.isRunning)
        recorder.lock.lock()
        defer { recorder.lock.unlock() }
        XCTAssertEqual(recorder.createdOnMain.count, 2)
        XCTAssertEqual(recorder.invalidated, 1)
    }

    func testRestartAfterStopCreatesAFreshTap() {
        let recorder = Recorder()
        let tap = TabSwallowTap(runtime: runtime(recorder)) { $0() }

        tap.start()
        tap.stop()
        tap.start()
        XCTAssertTrue(tap.isRunning)
        tap.stop()

        recorder.lock.lock()
        defer { recorder.lock.unlock() }
        XCTAssertEqual(recorder.createdOnMain.count, 2)
        XCTAssertEqual(recorder.invalidated, 2)
    }
}
