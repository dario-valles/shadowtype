// CompletionLength — paid configurable completion length (PRD §4, FR-CE-3).
// Pure logic + a stored preference; hermetic via an isolated, named UserDefaults suite so the
// real `.standard` defaults are never touched (mirrors the injectable-store style of AppRulesTests).
import XCTest
@testable import Shadowtype

final class CompletionLengthTests: XCTestCase {
    // A throwaway, per-test UserDefaults suite so reads/writes stay hermetic.
    private func tempDefaults() -> UserDefaults {
        let name = "gw-length-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Per-case numeric relationship (FR-CE-3)

    // The token ceiling must sit ABOVE the word boundary in every case, so the word count is what
    // actually ends a normal completion (the ceiling only caps pathological runs).
    func testMaxWordsBelowMaxTokensForEveryCase() {
        for length in CompletionLength.allCases {
            XCTAssertLessThan(length.maxWords, length.maxTokens,
                              "\(length.rawValue): maxWords must be < maxTokens")
        }
    }

    // `.short` is the free tier: a 1–2 word phrase (engine.maxWords=2 / maxTokens=8).
    func testShortValues() {
        XCTAssertEqual(CompletionLength.short.maxWords, 2)
        XCTAssertEqual(CompletionLength.short.maxTokens, 8)
    }

    // MARK: - Ordering short < medium < long

    func testMaxWordsStrictlyIncreasing() {
        XCTAssertLessThan(CompletionLength.short.maxWords, CompletionLength.medium.maxWords)
        XCTAssertLessThan(CompletionLength.medium.maxWords, CompletionLength.long.maxWords)
        XCTAssertLessThan(CompletionLength.long.maxWords, CompletionLength.extraLong.maxWords)
    }

    func testMaxTokensStrictlyIncreasing() {
        XCTAssertLessThan(CompletionLength.short.maxTokens, CompletionLength.medium.maxTokens)
        XCTAssertLessThan(CompletionLength.medium.maxTokens, CompletionLength.long.maxTokens)
        XCTAssertLessThan(CompletionLength.long.maxTokens, CompletionLength.extraLong.maxTokens)
    }

    // Sentence-aware stop: off for the short presets, on (and below maxWords) for the long ones, so a
    // long completion ends on a clause boundary rather than at the hard word cap.
    func testSentenceStopOnlyForLongPresets() {
        XCTAssertEqual(CompletionLength.short.sentenceStopAfterWords, 0)
        XCTAssertEqual(CompletionLength.medium.sentenceStopAfterWords, 0)
        XCTAssertGreaterThan(CompletionLength.long.sentenceStopAfterWords, 0)
        XCTAssertGreaterThan(CompletionLength.extraLong.sentenceStopAfterWords, 0)
        // The grace count must sit below the word cap or the sentence stop could never fire first.
        XCTAssertLessThan(CompletionLength.long.sentenceStopAfterWords, CompletionLength.long.maxWords)
        XCTAssertLessThan(CompletionLength.extraLong.sentenceStopAfterWords, CompletionLength.extraLong.maxWords)
    }

    // MARK: - Identifiable / CaseIterable surface

    func testIdentityAndCases() {
        XCTAssertEqual(CompletionLength.allCases, [.short, .medium, .long, .extraLong])
        XCTAssertEqual(CompletionLength.medium.id, "medium")
        XCTAssertEqual(CompletionLength.long.displayName, "Long")
        XCTAssertEqual(CompletionLength.extraLong.displayName, "Extra Long")
    }

    // MARK: - current() reads the stored value (free: every length selectable)

    func testCurrentDefaultsToShortWhenUnset() {
        let defaults = tempDefaults() // nothing stored
        XCTAssertEqual(CompletionLength.current(defaults: defaults), .short)
    }

    func testCurrentReadsStoredValue() {
        let defaults = tempDefaults()
        defaults.set(CompletionLength.medium.rawValue, forKey: CompletionLength.defaultsKey)
        XCTAssertEqual(CompletionLength.current(defaults: defaults), .medium)

        defaults.set(CompletionLength.long.rawValue, forKey: CompletionLength.defaultsKey)
        XCTAssertEqual(CompletionLength.current(defaults: defaults), .long)
    }

    func testCurrentFallsBackToShortOnUnrecognizedValue() {
        let defaults = tempDefaults()
        defaults.set("gigantic", forKey: CompletionLength.defaultsKey)
        XCTAssertEqual(CompletionLength.current(defaults: defaults), .short)
    }
}
