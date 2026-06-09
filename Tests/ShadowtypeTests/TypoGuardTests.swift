// TypoGuard (FR-CE-6 Free half) unit tests. Pure logic — no TCC, no model.
// The guard must SUPPRESS off obvious mid-typing typos while staying conservative on
// real words, proper nouns, short tokens, and non-alphabetic tokens (false negatives
// are cheaper than false positives — see TypoGuard.swift).
import XCTest
@testable import Shadowtype

final class TypoGuardTests: XCTestCase {
    let guard_ = TypoGuard()

    // MARK: - Should flag (likely typos)

    func testTripleLetterRun() {
        XCTAssertTrue(guard_.looksLikeTypo(lastWord: "helllo"))
        XCTAssertTrue(guard_.looksLikeTypo(lastWord: "abbbout"))
    }

    func testNoVowelsInLongWord() {
        XCTAssertTrue(guard_.looksLikeTypo(lastWord: "thnk"))
        XCTAssertTrue(guard_.looksLikeTypo(lastWord: "wrkk"))
    }

    func testLongConsonantCluster() {
        XCTAssertTrue(guard_.looksLikeTypo(lastWord: "thgnk"))
    }

    func testOneEditFromCommonWord() {
        XCTAssertTrue(guard_.looksLikeTypo(lastWord: "becuase")) // transposition-ish, dist 1 cases
        XCTAssertTrue(guard_.looksLikeTypo(lastWord: "thier"))   // their substitution-ish
        XCTAssertTrue(guard_.looksLikeTypo(lastWord: "abouy"))   // about -> abouy (sub)
        XCTAssertTrue(guard_.looksLikeTypo(lastWord: "worl"))    // world deletion
    }

    // MARK: - Should NOT flag (conservative)

    func testNormalWordsPass() {
        for w in ["hello", "completion", "keyboard", "rhythm", "because", "their", "world", "great"] {
            XCTAssertFalse(guard_.looksLikeTypo(lastWord: w), "false positive on \(w)")
        }
    }

    func testShortWordsNeverFlagged() {
        for w in ["a", "to", "the", "wrk", "xyz"] { // <4 letters: too ambiguous
            XCTAssertFalse(guard_.looksLikeTypo(lastWord: w), "short word flagged: \(w)")
        }
    }

    func testProperNounsAndAcronymsPass() {
        for w in ["Dario", "Github", "NASA", "Xerox"] {
            XCTAssertFalse(guard_.looksLikeTypo(lastWord: w), "proper noun/acronym flagged: \(w)")
        }
    }

    func testNonAlphabeticTokensPass() {
        for w in ["v1.2.3", "foo_bar", "don't", "well-known", "http://x", "2026", "a1b2"] {
            XCTAssertFalse(guard_.looksLikeTypo(lastWord: w), "non-alpha token flagged: \(w)")
        }
    }

    func testEmptyAndWhitespace() {
        XCTAssertFalse(guard_.looksLikeTypo(lastWord: ""))
        XCTAssertFalse(guard_.looksLikeTypo(lastWord: "   "))
    }

    func testDoubleLetterRunIsFine() {
        // Two identical letters is normal English ("ll", "ss") — must not flag.
        for w in ["coffee", "balloon", "success", "really"] {
            XCTAssertFalse(guard_.looksLikeTypo(lastWord: w), "double-letter word flagged: \(w)")
        }
    }
}
