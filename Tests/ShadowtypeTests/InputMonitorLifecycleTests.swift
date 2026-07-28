import AppKit
import XCTest
@testable import Shadowtype

final class InputMonitorLifecycleTests: XCTestCase {
    private func makePort() -> CFMachPort {
        var context = CFMachPortContext()
        return CFMachPortCreate(nil, nil, &context, nil)!
    }

    private func runtime(
        startupHook: @escaping () -> Void = {},
        createTap: @escaping (CGEventMask) -> CFMachPort?
    ) -> InputMonitor.Runtime {
        InputMonitor.Runtime(
            ensureAccess: { true },
            createTap: { mask, _, _ in createTap(mask) },
            setTapEnabled: { _, _ in },
            invalidateTap: { CFMachPortInvalidate($0) },
            startupHook: startupHook
        )
    }

    func testFailedTapCreationDoesNotLatchAndLaterStartSucceeds() {
        let lock = NSLock()
        var attempts = 0
        var observedMasks: [CGEventMask] = []
        let monitor = InputMonitor(runtime: runtime { mask in
            lock.lock()
            attempts += 1
            observedMasks.append(mask)
            let attempt = attempts
            lock.unlock()
            return attempt == 1 ? nil : self.makePort()
        })

        monitor.start()
        XCTAssertEqual(monitor.lifecycleState, .stopped)

        monitor.start()
        XCTAssertEqual(monitor.lifecycleState, .running)

        lock.lock()
        let finalAttempts = attempts
        let masks = observedMasks
        lock.unlock()
        XCTAssertEqual(finalAttempts, 2)
        XCTAssertEqual(masks, [
            CGEventMask(1 << CGEventType.keyDown.rawValue),
            CGEventMask(1 << CGEventType.keyDown.rawValue),
        ])

        monitor.stop()
        XCTAssertEqual(monitor.lifecycleState, .stopped)
    }

    func testStopRacingSlowStartupLeavesNoTapAndCanStartAgain() {
        let startupEntered = expectation(description: "worker entered startup")
        let firstStartupRelease = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var startupCount = 0
        let tapLock = NSLock()
        var tapsCreated = 0

        let monitor = InputMonitor(runtime: runtime(
            startupHook: {
                hookLock.lock()
                startupCount += 1
                let isFirst = startupCount == 1
                hookLock.unlock()
                if isFirst {
                    startupEntered.fulfill()
                    firstStartupRelease.wait()
                }
            },
            createTap: { _ in
                tapLock.lock()
                tapsCreated += 1
                tapLock.unlock()
                return self.makePort()
            }
        ))

        let firstStartReturned = expectation(description: "first start returned")
        DispatchQueue.global().async {
            monitor.start()
            firstStartReturned.fulfill()
        }
        wait(for: [startupEntered], timeout: 1)

        let stopReturned = expectation(description: "racing stop returned")
        DispatchQueue.global().async {
            monitor.stop()
            stopReturned.fulfill()
        }

        let deadline = Date().addingTimeInterval(1)
        while monitor.lifecycleState != .stopping, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(monitor.lifecycleState, .stopping)
        firstStartupRelease.signal()

        wait(for: [firstStartReturned, stopReturned], timeout: 2)
        XCTAssertEqual(monitor.lifecycleState, .stopped)
        tapLock.lock()
        let createdDuringRace = tapsCreated
        tapLock.unlock()
        XCTAssertEqual(createdDuringRace, 0)

        // The stopped worker cleared every lifecycle field, so a fresh start owns exactly one tap.
        monitor.start()
        XCTAssertEqual(monitor.lifecycleState, .running)
        tapLock.lock()
        let createdAfterRetry = tapsCreated
        tapLock.unlock()
        XCTAssertEqual(createdAfterRetry, 1)
        monitor.stop()
        XCTAssertEqual(monitor.lifecycleState, .stopped)
    }

    func testStampedAndKeyUpEventsAreDroppedBeforeMainHandoff() throws {
        let monitor = InputMonitor(runtime: runtime { _ in nil })
        let real = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(0),
            keyDown: true
        ))
        let stamped = try XCTUnwrap(real.copy())
        stamped.setIntegerValueField(
            .eventSourceUserData,
            value: InputMonitor.injectedEventMagic
        )

        var received: [InputEvent] = []
        let drained = expectation(description: "main queue drained")
        monitor.onEvent = { received.append($0) }

        monitor.decodeAndForward(type: .keyDown, event: stamped, uptime: 1)
        monitor.decodeAndForward(type: .keyUp, event: real, uptime: 2)
        monitor.decodeAndForward(type: .keyDown, event: real, uptime: 3)
        DispatchQueue.main.async { drained.fulfill() }

        wait(for: [drained], timeout: 1)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.keycode, 0)
        XCTAssertEqual(received.first?.uptime, 3)
        XCTAssertEqual(received.first?.isKeyDown, true)
    }
}
