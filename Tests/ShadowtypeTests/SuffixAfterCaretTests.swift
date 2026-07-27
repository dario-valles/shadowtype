// EditContextTracker.suffixAfterCaret — the pure post-caret read. Until this existed the only thing
// the product knew about text AFTER the caret was caretAtLineEnd()'s one-character peek, so a
// completion could happily duplicate or contradict what sat three lines below. UTF-16 offsets, matching
// kAXSelectedTextRange.
import XCTest
@testable import Shadowtype

final class SuffixAfterCaretTests: XCTestCase {
    func testTextAfterCaret() {
        XCTAssertEqual(EditContextTracker.suffixAfterCaret("hello world", caret: 5, maxChars: 100),
                       " world")
    }

    func testNilAtEndOfText() {
        // Nothing follows → nil, not "": "no suffix" and "empty suffix" are the same fact and callers
        // shouldn't have to special-case the empty string.
        XCTAssertNil(EditContextTracker.suffixAfterCaret("hello", caret: 5, maxChars: 100))
        XCTAssertNil(EditContextTracker.suffixAfterCaret("", caret: 0, maxChars: 100))
    }

    func testSpansNewlines() {
        // The whole point: the caret can be at end-of-LINE and still have paragraphs below it.
        let text = "Hi there,\n\nThanks for the update.\nBest,\n"
        XCTAssertEqual(EditContextTracker.suffixAfterCaret(text, caret: 9, maxChars: 100),
                       "\n\nThanks for the update.\nBest,\n")
    }

    func testLineEndDoesNotImplyNoSuffix() {
        // caretAtLineEnd() is NOT an end-of-document test — the exact misconception the suffix read
        // exists to fix. Both facts hold at once for the same caret.
        let text = "line one\nline two"
        XCTAssertTrue(EditContextTracker.isCaretAtLineEnd(text, caret: 8))
        XCTAssertEqual(EditContextTracker.suffixAfterCaret(text, caret: 8, maxChars: 100), "\nline two")
    }

    func testCapsToMaxChars() {
        XCTAssertEqual(EditContextTracker.suffixAfterCaret("abcdefghij", caret: 2, maxChars: 3), "cde")
    }

    func testZeroOrNegativeMaxCharsYieldsNil() {
        XCTAssertNil(EditContextTracker.suffixAfterCaret("abc", caret: 0, maxChars: 0))
        XCTAssertNil(EditContextTracker.suffixAfterCaret("abc", caret: 0, maxChars: -5))
    }

    func testClampsOutOfRangeCaret() {
        XCTAssertNil(EditContextTracker.suffixAfterCaret("hi", caret: 99, maxChars: 10))  // past end
        XCTAssertEqual(EditContextTracker.suffixAfterCaret("hi", caret: -1, maxChars: 10), "hi")
    }

    func testCapNeverSlicesASurrogatePair() {
        // "a👋b": the emoji is TWO UTF-16 units. A cap landing between them must drop the dangling high
        // surrogate rather than emit a lone one (which String repairs to U+FFFD).
        let text = "a\u{1F44B}b"
        XCTAssertEqual(EditContextTracker.suffixAfterCaret(text, caret: 0, maxChars: 2), "a")
        XCTAssertEqual(EditContextTracker.suffixAfterCaret(text, caret: 0, maxChars: 3), "a\u{1F44B}")
        // A cap of 1 that lands on the high surrogate alone has nothing left to return.
        XCTAssertNil(EditContextTracker.suffixAfterCaret(text, caret: 1, maxChars: 1))
    }

    func testUncappedSuffixKeepsWholeEmoji() {
        XCTAssertEqual(EditContextTracker.suffixAfterCaret("ok \u{1F44B}", caret: 3, maxChars: 400),
                       "\u{1F44B}")
    }

    // The suffix is read at the same chokepoint as the prefix, so both sides get the NBSP fold that
    // downstream boundary gates depend on (see normalizingSpaces / the Apple Mail bug).
    func testNBSPFoldAppliesToSuffixShape() {
        let raw = EditContextTracker.suffixAfterCaret("done\u{00A0}already", caret: 4, maxChars: 100)
        XCTAssertEqual(raw, "\u{00A0}already")
        XCTAssertEqual(raw.map(EditContextTracker.normalizingSpaces), " already")
    }
}
