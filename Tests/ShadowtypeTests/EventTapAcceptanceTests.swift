import AppKit
import XCTest
@testable import Shadowtype

final class EventTapAcceptanceTests: XCTestCase {
    func testCallbackReturnsBeforeAcceptanceWorkAndSchedulesExactlyOnce() {
        var scheduled: [() -> Void] = []
        let tap = TabSwallowTap { scheduled.append($0) }
        tap.setSuggestionVisible(true)

        var callbackReturned = false
        var workRanBeforeReturn = false
        var acceptCount = 0
        tap.onAccept = {
            workRanBeforeReturn = !callbackReturned
            acceptCount += 1
        }

        XCTAssertTrue(tap.handleKeyDown(keycode: 48, flags: []))
        callbackReturned = true

        XCTAssertFalse(workRanBeforeReturn)
        XCTAssertEqual(acceptCount, 0)
        XCTAssertEqual(scheduled.count, 1)

        // Key repeat while the first accept is pending is swallowed without duplicating the work.
        XCTAssertTrue(tap.handleKeyDown(keycode: 48, flags: []))
        XCTAssertEqual(scheduled.count, 1)

        scheduled.removeFirst()()
        XCTAssertEqual(acceptCount, 1)
    }

    func testOptionTabSchedulesLineAcceptanceOnly() {
        var scheduled: [() -> Void] = []
        let tap = TabSwallowTap { scheduled.append($0) }
        tap.setSuggestionVisible(true)

        var wordAccepts = 0
        var lineAccepts = 0
        tap.onAccept = { wordAccepts += 1 }
        tap.onAcceptLine = { lineAccepts += 1 }

        XCTAssertTrue(tap.handleKeyDown(keycode: 48, flags: .maskAlternate))
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()

        XCTAssertEqual(wordAccepts, 0)
        XCTAssertEqual(lineAccepts, 1)
    }
}
