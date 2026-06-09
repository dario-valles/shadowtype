// AccessibilityNudge — per-app "we can't read this app" nudge gating (Google Docs et al).
// Pure host predicate + the UserDefaults-backed dismiss/streak store (hermetic via injected defaults).
import XCTest
@testable import Shadowtype

final class AccessibilityNudgeTests: XCTestCase {
    private func tempDefaults() -> UserDefaults {
        UserDefaults(suiteName: "gw-axnudge-\(UUID().uuidString)")!
    }

    // MARK: - Pure host predicate

    func testIsHostileMatchesKnownHosts() {
        XCTAssertTrue(AXNudge.isHostile(host: "docs.google.com"))
        XCTAssertTrue(AXNudge.isHostile(host: "DOCS.GOOGLE.COM"))   // case-insensitive
    }

    func testIsHostileRejectsOthersAndNil() {
        XCTAssertFalse(AXNudge.isHostile(host: "mail.google.com"))
        XCTAssertFalse(AXNudge.isHostile(host: "example.com"))
        XCTAssertFalse(AXNudge.isHostile(host: nil))
    }

    func testAppLabelAndHelpURL() {
        XCTAssertEqual(AXNudge.appLabel(forHost: "docs.google.com"), "Google Docs")
        XCTAssertNotNil(AXNudge.helpURL(forHost: "docs.google.com"))
    }

    // MARK: - Miss streak / once-per-host gating

    func testFiresExactlyOnceAtThreshold() {
        let store = AXNudgeStore(defaults: tempDefaults())
        var fired = 0
        for _ in 0..<(AXNudge.missThreshold + 3) {
            if store.notePrefixMiss(host: "docs.google.com") { fired += 1 }
        }
        XCTAssertEqual(fired, 1, "Banner should fire exactly once per host per session")
    }

    func testBelowThresholdDoesNotFire() {
        let store = AXNudgeStore(defaults: tempDefaults())
        var fired = false
        for _ in 0..<(AXNudge.missThreshold - 1) {
            fired = fired || store.notePrefixMiss(host: "docs.google.com")
        }
        XCTAssertFalse(fired)
    }

    func testDismissSuppressesPermanently() {
        let defaults = tempDefaults()
        let store = AXNudgeStore(defaults: defaults)
        store.dismiss(host: "docs.google.com")
        XCTAssertTrue(store.isDismissed(host: "docs.google.com"))
        var fired = false
        for _ in 0..<(AXNudge.missThreshold + 5) {
            fired = fired || store.notePrefixMiss(host: "docs.google.com")
        }
        XCTAssertFalse(fired, "Dismissed host must never re-fire")

        // Persists across instances (UserDefaults-backed).
        let reloaded = AXNudgeStore(defaults: defaults)
        XCTAssertTrue(reloaded.isDismissed(host: "docs.google.com"))
    }

    func testMayStillPromptGatesAfterPromptAndDismiss() {
        let store = AXNudgeStore(defaults: tempDefaults())
        XCTAssertTrue(store.mayStillPrompt(), "Fresh session can still prompt")
        // Drive the only hostile host past threshold → prompted this session.
        for _ in 0..<AXNudge.missThreshold { _ = store.notePrefixMiss(host: "docs.google.com") }
        XCTAssertFalse(store.mayStillPrompt(), "Nothing left to prompt once the host fired this session")
    }

    func testMayStillPromptFalseWhenAllDismissed() {
        let store = AXNudgeStore(defaults: tempDefaults())
        for h in AXNudge.hostileHosts { store.dismiss(host: h) }
        XCTAssertFalse(store.mayStillPrompt())
    }

    func testDistinctHostsTrackedIndependently() {
        let store = AXNudgeStore(defaults: tempDefaults())
        for _ in 0..<AXNudge.missThreshold { _ = store.notePrefixMiss(host: "docs.google.com") }
        // A different host starts its own streak.
        var firedOther = false
        for _ in 0..<(AXNudge.missThreshold - 1) {
            firedOther = firedOther || store.notePrefixMiss(host: "other.example.com")
        }
        XCTAssertFalse(firedOther)
    }
}
