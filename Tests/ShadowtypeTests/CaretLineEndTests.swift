// EditContextTracker.isCaretAtLineEnd — the pure predicate behind the per-app "mid-line completions"
// gate. UTF-16 offset semantics; CR/LF count as end-of-line.
import XCTest
import AppKit
import ApplicationServices
@testable import Shadowtype

final class CaretLineEndTests: XCTestCase {
    func testCaretAtEndOfText() {
        XCTAssertTrue(EditContextTracker.isCaretAtLineEnd("hello", caret: 5))
    }

    func testCaretBeforeNewline() {
        // "hello\nworld" — caret right after "hello" (index 5) sits before the LF → end of line.
        XCTAssertTrue(EditContextTracker.isCaretAtLineEnd("hello\nworld", caret: 5))
    }

    func testCaretMidLine() {
        // Caret after "hel" with "lo" still ahead on the same line → NOT end of line.
        XCTAssertFalse(EditContextTracker.isCaretAtLineEnd("hello", caret: 3))
    }

    func testCaretMidWordBeforeMoreText() {
        XCTAssertFalse(EditContextTracker.isCaretAtLineEnd("foo bar", caret: 4))  // before "bar"
    }

    func testClampsOutOfRange() {
        XCTAssertTrue(EditContextTracker.isCaretAtLineEnd("hi", caret: 99))   // past end → end
        XCTAssertFalse(EditContextTracker.isCaretAtLineEnd("hi", caret: -1))  // clamped to 0, "h" follows
    }

    func testEmptyString() {
        XCTAssertTrue(EditContextTracker.isCaretAtLineEnd("", caret: 0))
    }
}

// AXTextProbe.classifyLineRemainder — the pure core of the web/marker mid-line gate. Given the text
// from the caret to the end of its visual line, decides lineEnd vs midLine (trailing whitespace = EOL).
final class LineRemainderClassifyTests: XCTestCase {
    func testEmptyIsLineEnd() {
        XCTAssertEqual(AXTextProbe.classifyLineRemainder(""), .lineEnd)
    }

    func testBreaksAreLineEnd() {
        XCTAssertEqual(AXTextProbe.classifyLineRemainder("\n"), .lineEnd)
        XCTAssertEqual(AXTextProbe.classifyLineRemainder("\r"), .lineEnd)
    }

    func testTrailingWhitespaceIsLineEnd() {
        XCTAssertEqual(AXTextProbe.classifyLineRemainder("   "), .lineEnd)
        XCTAssertEqual(AXTextProbe.classifyLineRemainder("  \n"), .lineEnd)
        XCTAssertEqual(AXTextProbe.classifyLineRemainder("\t"), .lineEnd)
    }

    func testRealTextIsMidLine() {
        XCTAssertEqual(AXTextProbe.classifyLineRemainder("world"), .midLine)
        XCTAssertEqual(AXTextProbe.classifyLineRemainder("it's still rough"), .midLine)
    }

    func testLeadingSpaceThenTextIsMidLine() {
        XCTAssertEqual(AXTextProbe.classifyLineRemainder(" x"), .midLine)
        XCTAssertEqual(AXTextProbe.classifyLineRemainder("\tx"), .midLine)
    }

    func testPageContextCapKeepsComposerAdjacentTail() {
        let page = "oldest-message\nolder-message\nResponder en español"
        XCTAssertEqual(AXTextProbe.recentText(page, maxChars: 20), "Responder en español")
    }

    func testUnsupportedNextMarkerIsUnavailableNotLineEnd() {
        let element = AXUIElementCreateApplication(123)
        let selected = "selected" as CFString
        let caret = "caret" as CFString
        let access = AXTextProbe.Access(
            value: { _, attribute in
                attribute == AXTextProbe.selectedTextMarkerRange
                    ? .init(error: .success, value: selected)
                    : .init(error: .attributeUnsupported, value: nil)
            },
            parameterized: { _, attribute, _ in
                if attribute == AXTextProbe.startTextMarkerForRange {
                    return .init(error: .success, value: caret)
                }
                return .init(error: .attributeUnsupported, value: nil)
            })

        let result = AXTextProbe.webCaretLinePosition(
            of: element,
            session: AXTextProbe.MarkerSession(element: element, access: access))

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(
            AXTextProbe.nextMarkerAvailability(error: .attributeUnsupported, hasValue: false),
            .unavailable)
        XCTAssertEqual(
            AXTextProbe.nextMarkerAvailability(error: .cannotComplete, hasValue: false),
            .unavailable)
    }

    func testOneWebFireSharesSelectedRangeAndCaretMarkerReads() {
        let element = AXUIElementCreateApplication(456)
        let selected = "selected" as CFString
        let caret = "caret" as CFString
        let documentStart = "start" as CFString
        let range = "range" as CFString
        var valueCounts: [String: Int] = [:]
        var parameterizedCounts: [String: Int] = [:]
        var rect = CGRect(x: 10, y: 20, width: 0, height: 18)
        let rectValue = AXValueCreate(.cgRect, &rect)!
        let attributed = NSAttributedString(
            string: "x",
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let access = AXTextProbe.Access(
            value: { _, attribute in
                valueCounts[attribute, default: 0] += 1
                switch attribute {
                case AXTextProbe.selectedTextMarkerRange:
                    return .init(error: .success, value: selected)
                case AXTextProbe.startTextMarker:
                    return .init(error: .success, value: documentStart)
                default:
                    return .init(error: .attributeUnsupported, value: nil)
                }
            },
            parameterized: { _, attribute, _ in
                parameterizedCounts[attribute, default: 0] += 1
                switch attribute {
                case AXTextProbe.startTextMarkerForRange:
                    return .init(error: .success, value: caret)
                case AXTextProbe.textMarkerRangeForUnorderedTextMarkers:
                    return .init(error: .success, value: range)
                case AXTextProbe.stringForTextMarkerRange:
                    return .init(error: .success, value: "hello" as CFString)
                case AXTextProbe.attributedStringForTextMarkerRange:
                    return .init(error: .success, value: attributed)
                case AXTextProbe.boundsForTextMarkerRange:
                    return .init(error: .success, value: rectValue)
                case AXTextProbe.nextTextMarker:
                    return .init(error: .noValue, value: nil)
                default:
                    return .init(error: .attributeUnsupported, value: nil)
                }
            })
        let session = AXTextProbe.MarkerSession(element: element, access: access)

        XCTAssertEqual(AXTextProbe.webPrefix(of: element, session: session), "hello")
        XCTAssertNotNil(AXTextProbe.webFont(of: element, session: session))
        XCTAssertNotNil(AXTextProbe.webCaretBounds(of: element, session: session))
        XCTAssertEqual(
            AXTextProbe.webCaretLinePosition(of: element, session: session),
            .lineEnd)

        XCTAssertEqual(valueCounts[AXTextProbe.selectedTextMarkerRange], 1)
        XCTAssertEqual(valueCounts[AXTextProbe.startTextMarker], 1)
        XCTAssertEqual(parameterizedCounts[AXTextProbe.startTextMarkerForRange], 1)
    }

    func testSecureFieldSkipsAllTextAndMarkerReads() {
        let secureElement = AXUIElementCreateApplication(789)
        var valueReads = 0
        var markerReads = 0
        let access = AXTextProbe.Access(
            value: { _, attribute in
                if attribute == (kAXValueAttribute as String) {
                    valueReads += 1
                    return .init(error: .success, value: "secret" as CFString)
                }
                markerReads += 1
                return .init(error: .success, value: "marker" as CFString)
            },
            parameterized: { _, _, _ in
                markerReads += 1
                return .init(error: .success, value: "marker" as CFString)
            })
        let session = AXTextProbe.MarkerSession(
            element: secureElement, access: access)

        let sides = EditContextTracker.protectedCaretSides(isSecure: true) {
            let native = access.value(secureElement, kAXValueAttribute as String).value as? String
            let marker = AXTextProbe.webPrefix(
                of: secureElement, session: session)
            return (native, marker)
        }

        XCTAssertNil(sides.prefix)
        XCTAssertNil(sides.suffix)
        XCTAssertEqual(valueReads, 0)
        XCTAssertEqual(markerReads, 0)
    }
}
