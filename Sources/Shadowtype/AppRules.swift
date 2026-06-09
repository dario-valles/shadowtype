// AppRules — per-app + per-domain enable/disable for completions (FR-PA-1, FR-PA-2).
// FREE tier: a user can silence Shadowtype in specific apps (by bundle id) or, inside a browser,
// on specific web domains. Default is ON everywhere; a rule only ever *disables*. Persisted as
// JSON in Application Support so the choice survives relaunch. This REPLACES the coordinator's
// ad-hoc in-memory disabledBundleIds set.
//
// Unlike WordMeter this is plain (no HMAC): these are user preferences, not an anti-tamper counter —
// editing the file just toggles the user's own setting, which is harmless.
//
// The coordinator's fire()-gate, the menu "Pause for this app" toggle, and the Settings Per-App pane
// all read/mutate `AppRules.shared` — a single instance. AppRules caches its record in memory (loaded
// once at init), so these MUST share one instance or a Settings toggle wouldn't reach the coordinator
// until relaunch. Tests use the injectable `init(storeURL:)` instead and stay hermetic.
import Foundation

final class AppRules {
    // A target appears in a list only when it BUCKS the current default: `defaultEnabled == true`
    // (the classic behavior) uses the `disabled*` lists to silence specific apps/domains; flipping the
    // default OFF (Settings → "Default behavior in new apps: Off") uses the `enabled*` lists to allow
    // specific ones. Decoding tolerates older files that only had the two `disabled*` arrays.
    private struct Record: Codable {
        var disabledBundleIds: [String]
        var disabledDomains: [String]
        var enabledBundleIds: [String]
        var enabledDomains: [String]
        var defaultEnabled: Bool
        // Temporary ("Disable for 5 min / 1 hour / rest of day") rules: epoch-seconds expiry keyed by the
        // disabled bundle id / domain. A disabled entry WITHOUT an expiry here is permanent (the classic
        // behavior). Expired entries are pruned lazily on the next isEnabled() read.
        var bundleExpiries: [String: Double]
        var domainExpiries: [String: Double]

        init(disabledBundleIds: [String] = [], disabledDomains: [String] = [],
             enabledBundleIds: [String] = [], enabledDomains: [String] = [],
             defaultEnabled: Bool = true,
             bundleExpiries: [String: Double] = [:], domainExpiries: [String: Double] = [:]) {
            self.disabledBundleIds = disabledBundleIds
            self.disabledDomains = disabledDomains
            self.enabledBundleIds = enabledBundleIds
            self.enabledDomains = enabledDomains
            self.defaultEnabled = defaultEnabled
            self.bundleExpiries = bundleExpiries
            self.domainExpiries = domainExpiries
        }

        // Backward-compatible: missing keys (pre-default-behavior / pre-expiry files) fall back to empty/true.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            disabledBundleIds = try c.decodeIfPresent([String].self, forKey: .disabledBundleIds) ?? []
            disabledDomains  = try c.decodeIfPresent([String].self, forKey: .disabledDomains) ?? []
            enabledBundleIds = try c.decodeIfPresent([String].self, forKey: .enabledBundleIds) ?? []
            enabledDomains   = try c.decodeIfPresent([String].self, forKey: .enabledDomains) ?? []
            defaultEnabled   = try c.decodeIfPresent(Bool.self, forKey: .defaultEnabled) ?? true
            bundleExpiries   = try c.decodeIfPresent([String: Double].self, forKey: .bundleExpiries) ?? [:]
            domainExpiries   = try c.decodeIfPresent([String: Double].self, forKey: .domainExpiries) ?? [:]
        }
    }

    private let lock = NSLock()
    private let storeURL: URL
    private var record: Record

    // Production: store in Application Support alongside meter.json.
    convenience init() {
        self.init(storeURL: AppRules.defaultStoreURL())
    }

    // The one instance shared by the coordinator, the menu toggle, and the Settings Per-App pane.
    static let shared = AppRules()

    // Designated init — also the seam for hermetic tests (temp file). Loads existing rules.
    init(storeURL: URL) {
        self.storeURL = storeURL
        self.record = AppRules.load(from: storeURL) ?? Record()
    }

    // MARK: - Query

    /// FR-PA-1/2: explicit disable wins, then explicit enable, else the configured default. Bundle ids
    /// match exactly. A domain rule matches its host AND any subdomain of it (case-insensitive), so a
    /// rule on "github.com" also covers "www.github.com" / "gist.github.com" — what a user expects from
    /// a domain rule, and what the curated host entries need to actually fire.
    func isEnabled(bundleId: String?, domain: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked()    // expired temporary rules re-enable themselves on the next read
        let host = domain?.lowercased()
        // Explicit OFF overrides win over everything (a disabled domain silences even an enabled app).
        if let bundleId, record.disabledBundleIds.contains(bundleId) { return false }
        if let host, record.disabledDomains.contains(where: { AppRules.hostMatches(host, rule: $0) }) { return false }
        // Then explicit ON overrides (a user re-enabling a built-in-off app, or any app when the default
        // is OFF). These come BEFORE the built-in layer so the user can always win.
        if let bundleId, record.enabledBundleIds.contains(bundleId) { return true }
        if let host, record.enabledDomains.contains(where: { AppRules.hostMatches(host, rule: $0) }) { return true }
        // Built-in auto-off (password managers, IDEs, terminals, system apps) — the default-off layer
        // under the global default. Bundle ids only; domains have no built-in overrides.
        if BuiltInAppOverrides.override(forBundleId: bundleId)?.completionsOff == true { return false }
        return record.defaultEnabled
    }

    /// Whether unconfigured apps/domains are active by default (Settings → "Default behavior in new apps").
    func defaultEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return record.defaultEnabled
    }

    /// A host matches a domain rule when it equals the rule or is a subdomain of it. Both are
    /// lowercased (hosts are case-insensitive). Pure + testable.
    static func hostMatches(_ host: String, rule: String) -> Bool {
        let r = rule.lowercased()
        guard !r.isEmpty else { return false }
        return host == r || host.hasSuffix("." + r)
    }

    // MARK: - Mutation

    func setEnabled(_ enabled: Bool, bundleId: String) {
        guard !bundleId.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        // Use the built-in-aware default so re-enabling a built-in-off app (e.g. 1Password) stores an
        // explicit enable entry that wins — without this, On != global-default and the toggle is a no-op.
        let effDefault = AppRules.effectiveDefault(record.defaultEnabled, bundleId: bundleId)
        let r = AppRules.applyingOverride(enabled, value: bundleId, defaultEnabled: effDefault,
                                          enabledList: record.enabledBundleIds,
                                          disabledList: record.disabledBundleIds)
        // A manual enable/permanent-disable clears any prior timed expiry for this target.
        let hadExpiry = record.bundleExpiries.removeValue(forKey: bundleId) != nil
        guard r.changed || hadExpiry else { return }
        record.enabledBundleIds = r.enabled
        record.disabledBundleIds = r.disabled
        save()
    }

    func setEnabled(_ enabled: Bool, domain: String) {
        // Normalize once on the way in so query-time comparison is stable.
        let normalized = domain.lowercased()
        guard !normalized.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let r = AppRules.applyingOverride(enabled, value: normalized, defaultEnabled: record.defaultEnabled,
                                          enabledList: record.enabledDomains,
                                          disabledList: record.disabledDomains)
        let hadExpiry = record.domainExpiries.removeValue(forKey: normalized) != nil
        guard r.changed || hadExpiry else { return }
        record.enabledDomains = r.enabled
        record.disabledDomains = r.disabled
        save()
    }

    /// Disable a bundle id, optionally only until `until` (nil == permanent). A temporary disable adds a
    /// disabled-list override (which wins in isEnabled) AND records an expiry; the next isEnabled() read
    /// past that instant prunes it. Passing a past date is a no-op (it would prune immediately).
    ///
    /// Crucially this PRESERVES any explicit-enable entry (e.g. a user who re-enabled a built-in-off app
    /// like Xcode): the pause must be reversible to the user's prior state, so on expiry the pruned
    /// disable falls back to that enable — NOT to the built-in/global default. (Routing through
    /// applyingOverride here would wipe the enable, silently reverting a re-enabled built-in app to OFF
    /// once the timer elapsed.)
    func disable(bundleId: String, until: Date?) {
        guard !bundleId.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if !record.disabledBundleIds.contains(bundleId) { record.disabledBundleIds.append(bundleId) }
        if let until { record.bundleExpiries[bundleId] = until.timeIntervalSince1970 }
        else { record.bundleExpiries[bundleId] = nil }
        save()
    }

    /// Disable a domain, optionally only until `until` (nil == permanent). See `disable(bundleId:until:)`;
    /// likewise preserves any explicit-enable entry so a timed pause is reversible.
    func disable(domain: String, until: Date?) {
        let normalized = domain.lowercased()
        guard !normalized.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if !record.disabledDomains.contains(normalized) { record.disabledDomains.append(normalized) }
        if let until { record.domainExpiries[normalized] = until.timeIntervalSince1970 }
        else { record.domainExpiries[normalized] = nil }
        save()
    }

    /// The soonest still-future temporary-rule expiry, so AppDelegate can arm a single-shot re-enable
    /// timer. Returns nil when no timed rule is pending.
    func nextExpiry() -> Date? {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let future = (Array(record.bundleExpiries.values) + Array(record.domainExpiries.values))
            .filter { $0 > now }
        guard let soonest = future.min() else { return nil }
        return Date(timeIntervalSince1970: soonest)
    }

    /// Flip the default behavior for unconfigured apps/domains. BOTH override lists are preserved: an
    /// explicit per-app/domain rule is the user's intent and must survive toggling the global default
    /// (flipping OFF→ON must NOT silently re-enable an app the user explicitly disabled). isEnabled()
    /// applies explicit overrides before the default, so a now-"redundant" entry stays harmless, and
    /// applyingOverride re-homes an entry to the correct list the next time that target is toggled.
    func setDefaultEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard record.defaultEnabled != enabled else { return }
        record.defaultEnabled = enabled
        save()
    }

    func disabledBundleIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return record.disabledBundleIds
    }

    func disabledDomains() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return record.disabledDomains
    }

    func enabledBundleIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return record.enabledBundleIds
    }

    func enabledDomains() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return record.enabledDomains
    }

    // MARK: - Helpers

    // Caller holds `lock`. Drops any temporary disable whose expiry has passed (from both the disabled
    // list and its expiry map), for bundles and domains, and persists if anything changed.
    private func pruneExpiredLocked() {
        let now = Date().timeIntervalSince1970
        let b = AppRules.pruneExpired(now: now, disabled: record.disabledBundleIds, expiries: record.bundleExpiries)
        let d = AppRules.pruneExpired(now: now, disabled: record.disabledDomains, expiries: record.domainExpiries)
        guard b.changed || d.changed else { return }
        record.disabledBundleIds = b.disabled
        record.bundleExpiries = b.expiries
        record.disabledDomains = d.disabled
        record.domainExpiries = d.expiries
        save()
    }

    // Pure expiry prune: remove every entry whose expiry is at/below `now` from both the disabled list and
    // the expiry map. Permanent disables (no expiry key) are untouched. Testable in isolation.
    static func pruneExpired(now: Double, disabled: [String], expiries: [String: Double])
        -> (disabled: [String], expiries: [String: Double], changed: Bool) {
        let expired = Set(expiries.filter { $0.value <= now }.keys)
        guard !expired.isEmpty else { return (disabled, expiries, false) }
        let remainingDisabled = disabled.filter { !expired.contains($0) }
        let remainingExpiries = expiries.filter { !expired.contains($0.key) }
        return (remainingDisabled, remainingExpiries, true)
    }

    /// The effective default-on for a bundle id: a built-in auto-off override (password manager, IDE,
    /// terminal, system app) forces the default to false; otherwise the global default applies. Pure.
    static func effectiveDefault(_ globalDefault: Bool, bundleId: String) -> Bool {
        if BuiltInAppOverrides.override(forBundleId: bundleId)?.completionsOff == true { return false }
        return globalDefault
    }

    /// The resolved default-on the Settings detail pane shows as "Default (on/off)" for an app's
    /// completions tri-state — built-in overrides included. Public read for the UI.
    func defaultEnabled(forBundleId bundleId: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let bundleId else { return record.defaultEnabled }
        return AppRules.effectiveDefault(record.defaultEnabled, bundleId: bundleId)
    }

    // Pure override computation (no `record` access, so no exclusivity conflict with the caller's two
    // sibling stored properties). Clears any prior override for `value` from both lists, then re-adds it
    // to the matching list ONLY when it bucks `defaultEnabled` (so default-agreeing toggles leave no
    // entry). Returns the new lists plus whether anything changed. Testable in isolation.
    static func applyingOverride(_ enabled: Bool, value: String, defaultEnabled: Bool,
                                 enabledList: [String], disabledList: [String])
        -> (enabled: [String], disabled: [String], changed: Bool) {
        var en = enabledList, dis = disabledList, changed = false
        if let i = dis.firstIndex(of: value) { dis.remove(at: i); changed = true }
        if let i = en.firstIndex(of: value) { en.remove(at: i); changed = true }
        if enabled != defaultEnabled {
            if enabled { en.append(value) } else { dis.append(value) }
            changed = true
        }
        return (en, dis, changed)
    }

    // MARK: - Persistence

    // Caller holds `lock`.
    private func save() {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    private static func load(from url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url),
              let rec = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return rec
    }

    private static func defaultStoreURL() -> URL {
        let base: URL
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first {
            base = appSupport
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        }
        return base
            .appendingPathComponent("Shadowtype", isDirectory: true)
            .appendingPathComponent("app-rules.json", isDirectory: false)
    }
}
