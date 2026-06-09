// EditContextTracker.isCaretAtLineEnd — the pure predicate behind the per-app "mid-line completions"
// gate. UTF-16 offset semantics; CR/LF count as end-of-line.
import XCTest
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
}
