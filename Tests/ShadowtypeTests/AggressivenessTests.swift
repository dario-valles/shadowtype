// Aggressiveness — free, core-UX trigger dial driving the adaptive typing-pause multiplier.
// Pure logic + a stored preference; hermetic via an isolated, named UserDefaults suite (mirrors
// CompletionLengthTests / AppRulesTests).
import XCTest
@testable import Shadowtype

final class AggressivenessTests: XCTestCase {
    private func tempDefaults() -> UserDefaults {
        let name = "gw-aggr-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Multiplier ordering: calmer settings wait for a clearer pause.

    func testPauseMultiplierStrictlyDecreasingFromConservativeToEager() {
        XCTAssertGreaterThan(Aggressiveness.conservative.pauseMultiplier,
                             Aggressiveness.balanced.pauseMultiplier)
        XCTAssertGreaterThan(Aggressiveness.balanced.pauseMultiplier,
                             Aggressiveness.eager.pauseMultiplier)
    }

    func testPauseMultipliersArePositiveAndAboveOne() {
        // A multiplier ≤ 1 would fire before a typical inter-keystroke gap — never a real pause.
        for a in Aggressiveness.allCases {
            XCTAssertGreaterThan(a.pauseMultiplier, 1.0, "\(a.rawValue) must wait longer than one IKI")
        }
    }

    // MARK: - Identifiable / CaseIterable surface

    func testIdentityAndCases() {
        XCTAssertEqual(Aggressiveness.allCases, [.conservative, .balanced, .eager])
        XCTAssertEqual(Aggressiveness.balanced.id, "balanced")
        XCTAssertEqual(Aggressiveness.eager.displayName, "Eager")
    }

    // MARK: - Stored preference: defaults to .balanced

    func testCurrentDefaultsToBalancedWhenUnset() {
        XCTAssertEqual(Aggressiveness.current(defaults: tempDefaults()), .balanced)
    }

    func testCurrentReadsStoredValue() {
        let defaults = tempDefaults()
        defaults.set(Aggressiveness.eager.rawValue, forKey: Aggressiveness.defaultsKey)
        XCTAssertEqual(Aggressiveness.current(defaults: defaults), .eager)

        defaults.set(Aggressiveness.conservative.rawValue, forKey: Aggressiveness.defaultsKey)
        XCTAssertEqual(Aggressiveness.current(defaults: defaults), .conservative)
    }

    func testCurrentFallsBackToBalancedOnUnrecognizedValue() {
        let defaults = tempDefaults()
        defaults.set("rabid", forKey: Aggressiveness.defaultsKey)
        XCTAssertEqual(Aggressiveness.current(defaults: defaults), .balanced)
    }
}
