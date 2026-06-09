import XCTest
@testable import Shadowtype

// Tier 1: locks the multilingual, context-aware sentence-stop policy.
final class SentenceBoundaryTests: XCTestCase {
    private func stop(_ c: Character, _ before: String, _ after: Character?) -> Bool {
        SentenceBoundary.isStop(terminator: c, before: Substring(before), after: after)
    }

    func testPlainSentenceEndStops() {
        XCTAssertTrue(stop(".", "I agree", " "))
        XCTAssertTrue(stop(".", "thanks for your help", nil))
        XCTAssertTrue(stop("!", "great", " "))
        XCTAssertTrue(stop("?", "are you sure", nil))
    }

    func testDecimalsAndVersionsDoNotStop() {
        XCTAssertFalse(stop(".", "3", "1"))      // 3.14
        XCTAssertFalse(stop(".", "v1", "2"))     // v1.2
        XCTAssertFalse(stop(".", "the price is 3", nil))  // streaming tail of a decimal
    }

    func testUrlAndInlineDotDoNotStop() {
        XCTAssertFalse(stop(".", "google", "c"))  // google.com
    }

    func testAbbreviationsDoNotStop() {
        XCTAssertFalse(stop(".", "Mr", " "))
        XCTAssertFalse(stop(".", "Dr", " "))
        XCTAssertFalse(stop(".", "etc", " "))
        XCTAssertFalse(stop(".", "e.g", " "))     // second dot of e.g.
        XCTAssertFalse(stop(".", "z.B", " "))     // German
    }

    func testSingleInitialDoesNotStop() {
        XCTAssertFalse(stop(".", "J", " "))            // J. Smith
        XCTAssertFalse(stop(".", "signed, A", " "))    // initial after a space
        XCTAssertTrue(stop(".", "NJ", " "))            // two letters → a real stop
        XCTAssertTrue(stop(".", "agree", " "))         // multi-letter word → a real stop
    }

    func testNonLatinTerminatorsStop() {
        XCTAssertTrue(stop("。", "資料はもうあります", nil))   // CJK
        XCTAssertTrue(stop("？", "本当に", nil))            // fullwidth ?
        XCTAssertTrue(stop("۔", "شكرا جزيلا", nil))        // Arabic full stop
        XCTAssertTrue(stop("؟", "هل أنت متأكد", nil))      // Arabic question mark
        XCTAssertTrue(stop("।", "नमस्ते", nil))            // Devanagari danda
    }

    func testClauseSeparatorsDoNotStop() {
        XCTAssertFalse(stop("、", "これは", nil))   // CJK clause comma
        XCTAssertFalse(stop("،", "مرحبا", nil))     // Arabic comma
        XCTAssertFalse(stop(",", "hello", " "))     // ASCII comma
    }

    func testFirstStopIndexScansWithContext() {
        // "Mr. Smith arrived." — the first period (Mr.) is not a stop; the last one is.
        let piece = "Mr. Smith arrived."
        let idx = SentenceBoundary.firstStopIndex(in: piece, before: "")
        XCTAssertNotNil(idx)
        XCTAssertEqual(piece[idx!], ".")
        XCTAssertEqual(piece.distance(from: piece.startIndex, to: idx!), piece.count - 1) // the LAST dot
    }

    func testFirstStopIndexUsesBeforeContext() {
        // The boundary's word began in `before` (prior tokens): "Mr" + "." piece.
        XCTAssertNil(SentenceBoundary.firstStopIndex(in: ".", before: "Mr"))
        XCTAssertNotNil(SentenceBoundary.firstStopIndex(in: ".", before: "I agree"))
    }
}
