// SmartComposeNudge — Gmail Smart Compose coexistence nudge.
// Covers the pure host predicate + overlap heuristic + the consecutive-count store gating.
import XCTest
@testable import Shadowtype

final class SmartComposeNudgeTests: XCTestCase {
    private func tempDefaults() -> UserDefaults {
        UserDefaults(suiteName: "gw-smartcompose-\(UUID().uuidString)")!
    }

    // MARK: - Host predicate

    func testIsApplicableHostMatchesGmail() {
        XCTAssertTrue(SmartComposeNudge.isApplicableHost("mail.google.com"))
        XCTAssertTrue(SmartComposeNudge.isApplicableHost("MAIL.GOOGLE.COM"))
    }

    func testIsApplicableHostRejectsOthersAndNil() {
        XCTAssertFalse(SmartComposeNudge.isApplicableHost("docs.google.com"))
        XCTAssertFalse(SmartComposeNudge.isApplicableHost("example.com"))
        XCTAssertFalse(SmartComposeNudge.isApplicableHost(nil))
    }

    func testSettingsURLPresent() {
        XCTAssertNotNil(SmartComposeNudge.settingsURL())
    }

    // MARK: - Overlap detection (pure)

    func testDetectsTailOverlap() {
        // Field has Smart Compose's ghost appended after the typed prefix; tail matches our suggestion.
        let field = "Hi, let's catch up tomorrow"
        XCTAssertTrue(SmartComposeNudge.detectsOverlap(fieldValue: field,
                                                       prefix: "Hi, let's",
                                                       suggestion: " catch up tomorrow"))
    }

    func testDetectsOverlapIgnoresLeadingSeparatorSpace() {
        // Smart Compose may include the separator space; our suggestion may not (or vice versa).
        XCTAssertTrue(SmartComposeNudge.detectsOverlap(fieldValue: "Hi, let's catch up",
                                                       prefix: "Hi, let's",
                                                       suggestion: "catch up tomorrow"))
    }

    func testNoOverlapWhenFieldIsJustPrefix() {
        XCTAssertFalse(SmartComposeNudge.detectsOverlap(fieldValue: "Hi, let's",
                                                        prefix: "Hi, let's",
                                                        suggestion: " catch up"))
    }

    func testNoOverlapWhenPrefixIsNotAFieldPrefix() {
        // A caret in the middle of an existing sentence — value doesn't start with our prefix.
        XCTAssertFalse(SmartComposeNudge.detectsOverlap(fieldValue: "Yes I agree with you",
                                                        prefix: "Hi, let's",
                                                        suggestion: " catch up"))
    }

    func testNoOverlapBelowMinChars() {
        // Tail and head share only 3 chars (" an"), below the minOverlapChars=4 floor.
        XCTAssertFalse(SmartComposeNudge.detectsOverlap(fieldValue: "I have an",
                                                        prefix: "I have",
                                                        suggestion: " announcement"))
    }

    func testNoOverlapOnNilFieldOrEmpties() {
        XCTAssertFalse(SmartComposeNudge.detectsOverlap(fieldValue: nil, prefix: "x", suggestion: "y"))
        XCTAssertFalse(SmartComposeNudge.detectsOverlap(fieldValue: "x", prefix: "", suggestion: "y"))
        XCTAssertFalse(SmartComposeNudge.detectsOverlap(fieldValue: "x", prefix: "x", suggestion: ""))
    }

    func testNoOverlapWhenTailDiffersFromSuggestion() {
        // Smart Compose ghosted something different than what we'd suggest.
        XCTAssertFalse(SmartComposeNudge.detectsOverlap(fieldValue: "Thanks for the help today",
                                                        prefix: "Thanks for the",
                                                        suggestion: " quick reply"))
    }

    // MARK: - Consecutive-overlap store gating

    func testFiresExactlyOnceAtThreshold() {
        let store = SmartComposeNudgeStore(defaults: tempDefaults())
        var fired = 0
        for _ in 0..<(SmartComposeNudge.consecutiveThreshold + 3) {
            if store.noteOverlap() { fired += 1 }
        }
        XCTAssertEqual(fired, 1, "Banner should fire exactly once per session at threshold")
    }

    func testBelowThresholdDoesNotFire() {
        let store = SmartComposeNudgeStore(defaults: tempDefaults())
        var fired = false
        for _ in 0..<(SmartComposeNudge.consecutiveThreshold - 1) {
            fired = fired || store.noteOverlap()
        }
        XCTAssertFalse(fired)
    }

    func testNoOverlapResetsConsecutiveStreak() {
        let store = SmartComposeNudgeStore(defaults: tempDefaults())
        // Get one short of threshold, then break the streak.
        for _ in 0..<(SmartComposeNudge.consecutiveThreshold - 1) { _ = store.noteOverlap() }
        store.noteNoOverlap()
        // Now another (threshold - 1) overlaps should NOT fire — streak reset.
        var fired = false
        for _ in 0..<(SmartComposeNudge.consecutiveThreshold - 1) {
            fired = fired || store.noteOverlap()
        }
        XCTAssertFalse(fired, "Non-overlap render must reset the consecutive count")
    }

    func testDismissSuppressesPermanently() {
        let defaults = tempDefaults()
        let store = SmartComposeNudgeStore(defaults: defaults)
        store.dismiss()
        XCTAssertTrue(store.isDismissed())
        var fired = false
        for _ in 0..<(SmartComposeNudge.consecutiveThreshold + 5) {
            fired = fired || store.noteOverlap()
        }
        XCTAssertFalse(fired, "Dismissed store must never re-fire")
        // Persists across instances.
        let reloaded = SmartComposeNudgeStore(defaults: defaults)
        XCTAssertTrue(reloaded.isDismissed())
    }

    func testMayStillPromptGatesAfterPromptAndDismiss() {
        let store = SmartComposeNudgeStore(defaults: tempDefaults())
        XCTAssertTrue(store.mayStillPrompt())
        for _ in 0..<SmartComposeNudge.consecutiveThreshold { _ = store.noteOverlap() }
        XCTAssertFalse(store.mayStillPrompt(), "Already prompted this session")
    }

    func testMayStillPromptFalseAfterDismiss() {
        let store = SmartComposeNudgeStore(defaults: tempDefaults())
        store.dismiss()
        XCTAssertFalse(store.mayStillPrompt())
    }
}
