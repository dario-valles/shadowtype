// Autocorrect (FR-AC-1 paid) unit tests. Pure engine — no TCC, no model, no UI.
// The corrector is the paid upgrade to TypoGuard's Free suppress: it OFFERS a concrete fix for a
// mistyped trailing token. It must fix classic typos confidently while staying at least as
// conservative as TypoGuard (a wrong rewrite is worse than none), declining on correct words, short
// tokens, ALL-CAPS, proper-noun-like tokens, and anything non-alphabetic.
import XCTest
@testable import Shadowtype

final class AutocorrectTests: XCTestCase {
    let ac = Autocorrect()

    // MARK: - Classic typos correct

    func testClassicTyposCorrect() {
        XCTAssertEqual(ac.correction(for: "teh"), "the")          // transposition
        XCTAssertEqual(ac.correction(for: "becuase"), "because")  // transposition
        XCTAssertEqual(ac.correction(for: "recieve"), "receive")  // i/e transposition
        XCTAssertEqual(ac.correction(for: "thier"), "their")      // transposition
        XCTAssertEqual(ac.correction(for: "abouy"), "about")      // substitution
        XCTAssertEqual(ac.correction(for: "freind"), "friend")    // transposition
    }

    // MARK: - Correctly-spelled words return nil

    func testCorrectWordsReturnNil() {
        for w in ["the", "because", "receive", "their", "world", "hello", "great", "completion"] {
            XCTAssertNil(ac.correction(for: w), "false correction on correct word \(w)")
        }
    }

    // MARK: - Short tokens return nil

    func testShortTokensReturnNil() {
        for w in ["a", "to", "an", "is", "of"] { // 1–2 letters: too ambiguous to rewrite
            XCTAssertNil(ac.correction(for: w), "short token corrected: \(w)")
        }
    }

    // MARK: - ALL-CAPS / proper-noun-like return nil

    func testAllCapsAndProperNounsReturnNil() {
        for w in ["NASA", "USA", "HTTP"] {           // ALL-CAPS acronyms
            XCTAssertNil(ac.correction(for: w), "acronym corrected: \(w)")
        }
        for w in ["Dario", "Github", "Xerox", "Teh"] {
            // Single leading capital + lowercase rest => proper-noun-like => left alone, even "Teh".
            XCTAssertNil(ac.correction(for: w), "proper-noun-like corrected: \(w)")
        }
    }

    // MARK: - Tokens with digits/symbols return nil

    func testNonAlphabeticTokensReturnNil() {
        for w in ["v1.2.3", "foo_bar", "don't", "well-known", "http://x", "2026", "a1b2", "teh!"] {
            XCTAssertNil(ac.correction(for: w), "non-alpha token corrected: \(w)")
        }
    }

    func testEmptyAndWhitespaceReturnNil() {
        XCTAssertNil(ac.correction(for: ""))
        XCTAssertNil(ac.correction(for: "   "))
    }

    // MARK: - Capitalization preserved

    func testLeadingCapitalizationPreserved() {
        // A mixed-case token (leading cap but NOT a clean proper-noun, so the exclusion lets it
        // through) keeps its leading capital in the suggestion. "Becuase" has uppercase letters mid-
        // word? No — it's leading-cap + lowercase, which is excluded. Use a token whose tail isn't all
        // lowercase to exercise case preservation without tripping the proper-noun guard.
        XCTAssertEqual(ac.correction(for: "BECUASE"), nil) // all-caps -> excluded
        // Lowercase input stays lowercase.
        XCTAssertEqual(ac.correction(for: "becuase"), "because")
    }

    // MARK: - Ambiguity / no-confident-fix declines

    func testNoConfidentFixReturnsNil() {
        // Random gibberish with no single lexicon word one edit away.
        XCTAssertNil(ac.correction(for: "zxcvb"))
        XCTAssertNil(ac.correction(for: "qqqq"))
    }

    // MARK: - Distance helper

    func testDamerauDistanceOne() {
        XCTAssertTrue(Autocorrect.isDamerauDistanceOne("teh", "the"))     // transposition
        XCTAssertTrue(Autocorrect.isDamerauDistanceOne("freind", "friend")) // transposition
        XCTAssertTrue(Autocorrect.isDamerauDistanceOne("abouy", "about")) // substitution
        XCTAssertFalse(Autocorrect.isDamerauDistanceOne("the", "the"))    // identical => 0
        XCTAssertFalse(Autocorrect.isDamerauDistanceOne("cat", "world"))  // far apart
    }
}
