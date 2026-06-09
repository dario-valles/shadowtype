// AppRules — per-app + per-domain enable/disable (FR-PA-1, FR-PA-2).
// Pure logic + on-disk persistence; hermetic via the injectable storeURL init (like WordMeter).
import XCTest
@testable import Shadowtype

final class AppRulesTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-rules-\(UUID().uuidString).json")
    }

    // MARK: - Default-on (FR-PA-1/2)

    func testDefaultEnabledEverywhere() {
        let rules = AppRules(storeURL: tempURL())
        XCTAssertTrue(rules.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        XCTAssertTrue(rules.isEnabled(bundleId: nil, domain: "example.com"))
        XCTAssertTrue(rules.isEnabled(bundleId: nil, domain: nil))
        XCTAssertTrue(rules.disabledBundleIds().isEmpty)
        XCTAssertTrue(rules.disabledDomains().isEmpty)
    }

    // MARK: - Disable / re-enable by bundle

    func testDisableThenEnableBundle() {
        let rules = AppRules(storeURL: tempURL())
        rules.setEnabled(false, bundleId: "com.apple.Notes")
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        XCTAssertTrue(rules.isEnabled(bundleId: "com.apple.Mail", domain: nil)) // unaffected
        XCTAssertEqual(rules.disabledBundleIds(), ["com.apple.Notes"])

        rules.setEnabled(true, bundleId: "com.apple.Notes")
        XCTAssertTrue(rules.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        XCTAssertTrue(rules.disabledBundleIds().isEmpty)
    }

    func testDisableIsIdempotentAndNoDuplicates() {
        let rules = AppRules(storeURL: tempURL())
        rules.setEnabled(false, bundleId: "com.x")
        rules.setEnabled(false, bundleId: "com.x")
        XCTAssertEqual(rules.disabledBundleIds(), ["com.x"])
    }

    // MARK: - Disable / re-enable by domain (case-insensitive)

    func testDisableThenEnableDomainCaseInsensitive() {
        let rules = AppRules(storeURL: tempURL())
        rules.setEnabled(false, domain: "Example.COM")
        XCTAssertFalse(rules.isEnabled(bundleId: nil, domain: "example.com"))
        XCTAssertFalse(rules.isEnabled(bundleId: nil, domain: "EXAMPLE.com"))
        XCTAssertTrue(rules.isEnabled(bundleId: nil, domain: "other.com"))
        XCTAssertEqual(rules.disabledDomains(), ["example.com"]) // normalized on store

        rules.setEnabled(true, domain: "EXAMPLE.com")
        XCTAssertTrue(rules.isEnabled(bundleId: nil, domain: "example.com"))
        XCTAssertTrue(rules.disabledDomains().isEmpty)
    }

    // MARK: - Domain rules cover subdomains (FR-PA-2)

    func testDomainRuleMatchesSubdomains() {
        let rules = AppRules(storeURL: tempURL())
        rules.setEnabled(false, domain: "github.com")
        XCTAssertFalse(rules.isEnabled(bundleId: nil, domain: "github.com"))       // exact
        XCTAssertFalse(rules.isEnabled(bundleId: nil, domain: "www.github.com"))   // subdomain
        XCTAssertFalse(rules.isEnabled(bundleId: nil, domain: "gist.github.com"))  // subdomain
        XCTAssertTrue(rules.isEnabled(bundleId: nil, domain: "notgithub.com"))     // not a subdomain
        XCTAssertTrue(rules.isEnabled(bundleId: nil, domain: "github.com.evil.com")) // suffix trick, not a parent
    }

    func testHostMatchesPure() {
        XCTAssertTrue(AppRules.hostMatches("www.github.com", rule: "github.com"))
        XCTAssertTrue(AppRules.hostMatches("github.com", rule: "GitHub.com"))      // case-insensitive
        XCTAssertFalse(AppRules.hostMatches("evilgithub.com", rule: "github.com")) // must be dot-boundary
        XCTAssertFalse(AppRules.hostMatches("github.com", rule: ""))
    }

    // MARK: - Either match disables

    func testEitherBundleOrDomainDisables() {
        let rules = AppRules(storeURL: tempURL())
        rules.setEnabled(false, domain: "blocked.com")
        // Enabled app, blocked domain -> disabled.
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.Safari", domain: "blocked.com"))
        // Enabled app, allowed domain -> enabled.
        XCTAssertTrue(rules.isEnabled(bundleId: "com.apple.Safari", domain: "ok.com"))
    }

    // MARK: - Persistence + reload

    func testPersistsAcrossReload() {
        let url = tempURL()
        do {
            let rules = AppRules(storeURL: url)
            rules.setEnabled(false, bundleId: "com.apple.Notes")
            rules.setEnabled(false, domain: "example.com")
        }
        let reloaded = AppRules(storeURL: url)
        XCTAssertFalse(reloaded.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        XCTAssertFalse(reloaded.isEnabled(bundleId: nil, domain: "example.com"))
        XCTAssertEqual(reloaded.disabledBundleIds(), ["com.apple.Notes"])
        XCTAssertEqual(reloaded.disabledDomains(), ["example.com"])
    }

    func testMissingFileLoadsEmpty() {
        let rules = AppRules(storeURL: tempURL()) // never written
        XCTAssertTrue(rules.disabledBundleIds().isEmpty)
        XCTAssertTrue(rules.disabledDomains().isEmpty)
    }

    // MARK: - Default behavior in new apps (Settings → "Default behavior in new apps")

    func testDefaultOffDisablesUnconfigured() {
        let rules = AppRules(storeURL: tempURL())
        rules.setDefaultEnabled(false)
        XCTAssertFalse(rules.defaultEnabled())
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        XCTAssertFalse(rules.isEnabled(bundleId: nil, domain: "example.com"))
    }

    func testEnableOverrideWhenDefaultOff() {
        let rules = AppRules(storeURL: tempURL())
        rules.setDefaultEnabled(false)
        rules.setEnabled(true, bundleId: "com.apple.Mail")
        rules.setEnabled(true, domain: "docs.google.com")
        // Explicitly enabled targets are on; everything else stays off.
        XCTAssertTrue(rules.isEnabled(bundleId: "com.apple.Mail", domain: nil))
        XCTAssertTrue(rules.isEnabled(bundleId: nil, domain: "sub.docs.google.com")) // subdomain
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        XCTAssertEqual(rules.enabledBundleIds(), ["com.apple.Mail"])
        XCTAssertEqual(rules.enabledDomains(), ["docs.google.com"])
        // No redundant disabled entries while the default is already off.
        XCTAssertTrue(rules.disabledBundleIds().isEmpty)
    }

    func testFlippingDefaultPreservesExplicitOverrides() {
        let rules = AppRules(storeURL: tempURL())
        // Default on: disable an app (explicit user rule).
        rules.setEnabled(false, bundleId: "com.apple.Notes")
        XCTAssertEqual(rules.disabledBundleIds(), ["com.apple.Notes"])
        // Flip default off, then back on: the explicit disable must survive both flips — not be
        // silently lost (which would re-enable Notes against the user's stated intent).
        rules.setDefaultEnabled(false)
        XCTAssertEqual(rules.disabledBundleIds(), ["com.apple.Notes"])
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        rules.setDefaultEnabled(true)
        XCTAssertEqual(rules.disabledBundleIds(), ["com.apple.Notes"])
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        // Re-enabling clears the override and returns to the (on) default.
        rules.setEnabled(true, bundleId: "com.apple.Notes")
        XCTAssertTrue(rules.disabledBundleIds().isEmpty)
        XCTAssertTrue(rules.isEnabled(bundleId: "com.apple.Notes", domain: nil))
    }

    func testDefaultAndOverridesPersistAcrossReload() {
        let url = tempURL()
        do {
            let rules = AppRules(storeURL: url)
            rules.setDefaultEnabled(false)
            rules.setEnabled(true, bundleId: "com.apple.Mail")
        }
        let reloaded = AppRules(storeURL: url)
        XCTAssertFalse(reloaded.defaultEnabled())
        XCTAssertTrue(reloaded.isEnabled(bundleId: "com.apple.Mail", domain: nil))
        XCTAssertFalse(reloaded.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        XCTAssertEqual(reloaded.enabledBundleIds(), ["com.apple.Mail"])
    }

    // A pre-default-behavior file (only the two `disabled*` arrays) must still load: default true,
    // empty enabled lists, disabled rules honored.
    func testDecodesLegacyRecordWithoutNewKeys() throws {
        let url = tempURL()
        let legacy = #"{"disabledBundleIds":["com.apple.Notes"],"disabledDomains":["example.com"]}"#
        try legacy.data(using: .utf8)!.write(to: url)
        let rules = AppRules(storeURL: url)
        XCTAssertTrue(rules.defaultEnabled())
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        XCTAssertFalse(rules.isEnabled(bundleId: nil, domain: "example.com"))
        XCTAssertTrue(rules.isEnabled(bundleId: "com.apple.Mail", domain: nil))
        XCTAssertTrue(rules.enabledBundleIds().isEmpty)
    }

    // MARK: - Timed disable (badge "for 5 min / 1 hour / rest of day")

    func testPermanentDisableHasNoExpiry() {
        let rules = AppRules(storeURL: tempURL())
        rules.disable(bundleId: "com.apple.Notes", until: nil)
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        XCTAssertEqual(rules.disabledBundleIds(), ["com.apple.Notes"])
        XCTAssertNil(rules.nextExpiry())
    }

    func testFutureExpiryStaysDisabledAndIsTheNextExpiry() {
        let rules = AppRules(storeURL: tempURL())
        let until = Date(timeIntervalSinceNow: 3600)
        rules.disable(bundleId: "com.apple.Notes", until: until)
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        let next = rules.nextExpiry()
        XCTAssertNotNil(next)
        XCTAssertEqual(next!.timeIntervalSince1970, until.timeIntervalSince1970, accuracy: 0.001)
    }

    func testPastExpiryPrunesAndReEnablesOnRead() {
        let rules = AppRules(storeURL: tempURL())
        rules.disable(bundleId: "com.apple.Notes", until: Date(timeIntervalSinceNow: -1))
        // The next isEnabled() read prunes the elapsed rule and the app is enabled again.
        XCTAssertTrue(rules.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        XCTAssertTrue(rules.disabledBundleIds().isEmpty)
        XCTAssertNil(rules.nextExpiry())
    }

    func testTimedDomainDisableAndSubdomainCoverage() {
        let rules = AppRules(storeURL: tempURL())
        rules.disable(domain: "GitHub.com", until: Date(timeIntervalSinceNow: 3600))
        XCTAssertFalse(rules.isEnabled(bundleId: nil, domain: "gist.github.com")) // subdomain still covered
        XCTAssertEqual(rules.disabledDomains(), ["github.com"])                   // normalized
    }

    func testManualReEnableClearsExpiry() {
        let rules = AppRules(storeURL: tempURL())
        rules.disable(bundleId: "com.x", until: Date(timeIntervalSinceNow: 3600))
        rules.setEnabled(true, bundleId: "com.x")
        XCTAssertTrue(rules.isEnabled(bundleId: "com.x", domain: nil))
        XCTAssertNil(rules.nextExpiry())
    }

    func testNextExpiryReturnsSoonest() {
        let rules = AppRules(storeURL: tempURL())
        rules.disable(bundleId: "com.late", until: Date(timeIntervalSinceNow: 7200))
        rules.disable(domain: "soon.com", until: Date(timeIntervalSinceNow: 600))
        let next = rules.nextExpiry()
        XCTAssertEqual(next!.timeIntervalSinceNow, 600, accuracy: 5)
    }

    func testTimedDisablePersistsAcrossReload() {
        let url = tempURL()
        let until = Date(timeIntervalSinceNow: 3600)
        do {
            let rules = AppRules(storeURL: url)
            rules.disable(bundleId: "com.apple.Notes", until: until)
        }
        let reloaded = AppRules(storeURL: url)
        XCTAssertFalse(reloaded.isEnabled(bundleId: "com.apple.Notes", domain: nil))
        XCTAssertEqual(reloaded.nextExpiry()!.timeIntervalSince1970, until.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Built-in auto-off overrides (password managers / IDEs / terminals / system apps)

    func testBuiltInOverrideOffByDefault() {
        let rules = AppRules(storeURL: tempURL())
        // No user rule, global default on, but these ship off via the built-in table.
        XCTAssertFalse(rules.isEnabled(bundleId: "com.1password.1password", domain: nil))
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.dt.Xcode", domain: nil))
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.finder", domain: nil))
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.Terminal", domain: nil))
        // A normal app is still on by default.
        XCTAssertTrue(rules.isEnabled(bundleId: "com.apple.mail", domain: nil))
    }

    func testUserCanReEnableBuiltInOffApp() {
        let url = tempURL()
        do {
            let rules = AppRules(storeURL: url)
            rules.setEnabled(true, bundleId: "com.1password.1password")
            XCTAssertTrue(rules.isEnabled(bundleId: "com.1password.1password", domain: nil))
            // The explicit enable must be stored (it bucks the built-in-off default).
            XCTAssertEqual(rules.enabledBundleIds(), ["com.1password.1password"])
        }
        // …and survive reload.
        let reloaded = AppRules(storeURL: url)
        XCTAssertTrue(reloaded.isEnabled(bundleId: "com.1password.1password", domain: nil))

        // Toggling it back off returns to the built-in default and stores no redundant entry.
        reloaded.setEnabled(false, bundleId: "com.1password.1password")
        XCTAssertFalse(reloaded.isEnabled(bundleId: "com.1password.1password", domain: nil))
        XCTAssertTrue(reloaded.enabledBundleIds().isEmpty)
        XCTAssertTrue(reloaded.disabledBundleIds().isEmpty)
    }

    func testBuiltInDefaultReportedToUI() {
        let rules = AppRules(storeURL: tempURL())
        XCTAssertFalse(rules.defaultEnabled(forBundleId: "com.bitwarden.desktop"))
        XCTAssertTrue(rules.defaultEnabled(forBundleId: "com.apple.mail"))
        XCTAssertTrue(rules.defaultEnabled(forBundleId: nil))
    }

    func testEffectiveDefaultPure() {
        XCTAssertFalse(AppRules.effectiveDefault(true, bundleId: "com.apple.dt.Xcode"))
        XCTAssertTrue(AppRules.effectiveDefault(true, bundleId: "com.apple.mail"))
        // A built-in app under a global-off default stays off.
        XCTAssertFalse(AppRules.effectiveDefault(false, bundleId: "com.apple.mail"))
    }

    func testBuiltInOverrideLookup() {
        XCTAssertEqual(BuiltInAppOverrides.override(forBundleId: "com.1password.1password")?.category, .passwordManager)
        XCTAssertEqual(BuiltInAppOverrides.override(forBundleId: "com.apple.dt.Xcode")?.category, .ide)
        XCTAssertEqual(BuiltInAppOverrides.override(forBundleId: "com.apple.finder")?.category, .system)
        XCTAssertEqual(BuiltInAppOverrides.override(forBundleId: "com.apple.Terminal")?.category, .terminal)
        XCTAssertNil(BuiltInAppOverrides.override(forBundleId: "com.apple.mail"))
        XCTAssertNil(BuiltInAppOverrides.override(forBundleId: nil))
    }

    // The built-in default must not silence a domain rule path (domains have no overrides).
    func testBuiltInDoesNotAffectDomains() {
        let rules = AppRules(storeURL: tempURL())
        XCTAssertTrue(rules.isEnabled(bundleId: nil, domain: "example.com"))
    }

    // Pausing a user-RE-ENABLED built-in-off app must be reversible: when the timed pause expires, the
    // app returns to the user's enable, NOT to the built-in OFF. (Regression: routing disable() through
    // effectiveDefault wiped the enable, so the app silently stayed off forever after the timer.)
    func testTimedPauseOfReEnabledBuiltInAppRestoresOnExpiry() {
        let rules = AppRules(storeURL: tempURL())
        rules.setEnabled(true, bundleId: "com.apple.dt.Xcode")          // user turns Xcode on
        XCTAssertTrue(rules.isEnabled(bundleId: "com.apple.dt.Xcode", domain: nil))

        rules.disable(bundleId: "com.apple.dt.Xcode", until: Date(timeIntervalSinceNow: 3600))
        XCTAssertFalse(rules.isEnabled(bundleId: "com.apple.dt.Xcode", domain: nil))   // paused → off now
        XCTAssertEqual(rules.enabledBundleIds(), ["com.apple.dt.Xcode"])               // enable preserved

        // Simulate the pause elapsing: a past expiry prunes on the next read and the ENABLE resurfaces.
        rules.disable(bundleId: "com.apple.dt.Xcode", until: Date(timeIntervalSinceNow: -1))
        XCTAssertTrue(rules.isEnabled(bundleId: "com.apple.dt.Xcode", domain: nil),
                      "re-enabled built-in app must return to ON after the pause expires")
        XCTAssertNil(rules.nextExpiry())
    }

    // The same reversibility for a permanent re-enable + permanent disable round-trip.
    func testPermanentDisableOfReEnabledBuiltInThenReEnable() {
        let rules = AppRules(storeURL: tempURL())
        rules.setEnabled(true, bundleId: "com.1password.1password")
        rules.disable(bundleId: "com.1password.1password", until: nil)   // permanent pause
        XCTAssertFalse(rules.isEnabled(bundleId: "com.1password.1password", domain: nil))
        // Re-enabling clears the disable and the app is on again (enable entry still present).
        rules.setEnabled(true, bundleId: "com.1password.1password")
        XCTAssertTrue(rules.isEnabled(bundleId: "com.1password.1password", domain: nil))
    }

    // Pure prune helper in isolation.
    func testPruneExpiredPure() {
        let now: Double = 1000
        let r = AppRules.pruneExpired(now: now,
                                      disabled: ["a", "b", "c"],
                                      expiries: ["a": 900, "b": 1500])  // a elapsed, b future, c permanent
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.disabled.sorted(), ["b", "c"])
        XCTAssertNil(r.expiries["a"])
        XCTAssertEqual(r.expiries["b"], 1500)
    }

    func testPruneExpiredNoChangeWhenNothingElapsed() {
        let r = AppRules.pruneExpired(now: 1000, disabled: ["a"], expiries: ["a": 2000])
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.disabled, ["a"])
    }
}
