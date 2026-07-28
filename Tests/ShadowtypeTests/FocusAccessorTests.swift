import XCTest
import ApplicationServices
@testable import Shadowtype

final class FocusAccessorTests: XCTestCase {
    func testTransientFocusFailureNeverReturnsCachedElementToStrictAccessor() {
        let stale = AXUIElementCreateApplication(4242)
        var result: (AXError, AXUIElement?) = (.success, stale)
        let tracker = EditContextTracker(
            focusReader: { _ in result },
            frontmostPID: { 4242 },
            elementPID: { _ in 4242 })

        XCTAssertTrue(CFEqual(tracker.focusedElement(), stale))

        result = (.cannotComplete, nil)
        XCTAssertNil(tracker.focusedElement())
        XCTAssertTrue(CFEqual(tracker.focusedElementForRead(), stale))
    }

    func testValueChangeDoesNotRereadFocusOrRunFocusChangeCallback() {
        var focusReads = 0
        var callbacks = 0
        let tracker = EditContextTracker(focusReader: { _ in
            focusReads += 1
            return (.cannotComplete, nil)
        })
        tracker.onFocusChange = { callbacks += 1 }

        tracker.handleObserverNotification(kAXValueChangedNotification as String)

        XCTAssertEqual(focusReads, 0)
        XCTAssertEqual(callbacks, 0)
    }
}
