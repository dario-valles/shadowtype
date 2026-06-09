// WordMeter — daily accepted-word counter for the menu-bar meter (PRD §4.1, FR-ST-1, FR-IN-5).
// Counting unit: a word = a maximal run of non-whitespace characters in the *accepted* text.
// Reset at local midnight: persist {date: YYYY-MM-DD (local), count}; reset when stored date != today-local.
//
// Anti-tamper (PRD §4.1, R6) — proportionate, offline:
//   • HMAC-SHA256 over {date, count, install_uuid, last_seen_max_date} keyed by a per-install secret
//     held in the Keychain (never in this file). Verified on load; a forged/edited file fails the
//     check and the counter resets — a free user can't simply hand-edit `count` down.
//   • Clock-rollback guard: persist `last_seen_max_date` (a monotonic high-water of the observed
//     local date). "Today" is never allowed below it, so rolling the system clock back grants no
//     free daily reset until real time catches up.
// This is deliberately lightweight: a determined user can still delete the file (which drops the
// Keychain-independent state) — the goal is a frictionless honest path, not DRM warfare (PRD §4.1).
import Foundation
import Security
import CryptoKit

final class WordMeter {
    // On-disk record. `hmac` authenticates the other fields under the per-install secret.
    private struct Record: Codable {
        var date: String              // day the count belongs to (local YYYY-MM-DD)
        var count: Int                // words accepted TODAY (resets at local midnight; drives the free cap)
        var installUUID: String
        var lastSeenMaxDate: String   // monotonic high-water of observed local date (clock guard)
        // All-time, never-reset stats for the local Statistics dashboard (PRD §4.1; never transmitted).
        // `count` above stays the only cap-relevant figure; these are cumulative since install.
        var wordsAllTime: Int = 0     // cumulative accepted words
        var shownAllTime: Int = 0     // cumulative inline completions shown to the user
        var acceptedAllTime: Int = 0  // cumulative completions the user accepted ≥1 word of
        var hmac: String              // base64 HMAC-SHA256 over the canonical payload of the above
    }

    private let lock = NSLock()
    private let storeURL: URL
    private let secret: Data
    private var record: Record
    // Persistence split (FR-ST-1): the cap-relevant `count` is written synchronously at its existing
    // call sites (accept, rollover, init) so it survives a crash. The cosmetic all-time stats use a
    // coalesced background flush so the hot per-suggestion path never blocks the main thread on disk I/O.
    private let saveQueue = DispatchQueue(label: "com.shadowtype.wordmeter.save", qos: .utility)
    private var dirty = false           // unpersisted in-memory changes (lock-guarded)
    private var flushScheduled = false  // a coalesced background flush is already pending (lock-guarded)

    // Production: per-install secret from the Keychain, store in Application Support.
    convenience init() {
        self.init(storeURL: WordMeter.defaultStoreURL(), secret: KeychainSecret.loadOrCreate())
    }

    // Single shared instance for the live counter (incremented on accept) and the read-only Settings
    // panes — same in-memory + on-disk record, so the menu meter and Settings never disagree and we
    // don't reconstruct (Keychain + file read + write) on every Settings refresh tick. Tests use the
    // injectable init(storeURL:secret:) to stay hermetic.
    static let shared = WordMeter()

    // Designated init — also the seam for tests (hermetic temp file + known secret) and for a
    // future app-group container path (PRD §4.1) without a storage migration.
    init(storeURL: URL, secret: Data) {
        self.storeURL = storeURL
        self.secret = secret
        let today = WordMeter.todayLocalString()
        if let loaded = WordMeter.load(from: storeURL, secret: secret) {
            self.record = loaded
        } else {
            // Missing or tamper-failed file -> start fresh for today (resets a forged count).
            self.record = Record(date: today, count: 0, installUUID: UUID().uuidString,
                                  lastSeenMaxDate: today, hmac: "")
        }
        rolloverIfNeeded()
        // Ensure a correctly-signed file always exists on disk after construction.
        lock.lock(); saveNow(); lock.unlock()
    }

    func increment(by words: Int) {
        guard words > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeededLocked()
        record.count += words
        record.wordsAllTime += words
        saveNow()
    }

    func todayCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeededLocked()
        return record.count
    }

    // MARK: - All-time stats (local Statistics dashboard; never transmitted)

    /// Count one inline completion as having been shown to the user (the rising edge of a fresh ghost).
    /// Pairs with `recordSuggestionAccepted()` to give a real acceptance rate. Not cap-relevant.
    func recordSuggestionShown() {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeededLocked()
        record.shownAllTime += 1
        scheduleFlush()   // coalesced off-main write — never block the hot render path on disk I/O
    }

    /// Count one shown completion as accepted (called once per suggestion, on its first accepted word).
    func recordSuggestionAccepted() {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeededLocked()
        record.acceptedAllTime += 1
        scheduleFlush()   // the synchronous increment() that follows an accept also flushes this
    }

    /// Cumulative accepted words since install (the "all-time accepted" figure).
    func allTimeWordCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return record.wordsAllTime
    }

    /// Fraction of shown completions the user accepted (0…1), or nil until at least one was shown.
    /// The single best predictor of perceived usefulness for inline completion (Ziegler et al., CACM 2024).
    func acceptanceRate() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard record.shownAllTime > 0 else { return nil }
        return Double(record.acceptedAllTime) / Double(record.shownAllTime)
    }

    /// The clock-rollback-guarded current local date (YYYY-MM-DD): never below the highest date ever
    /// observed (the `lastSeenMaxDate` high-water). After rollover, `record.date` IS that guarded date.
    func effectiveTodayLocalString() -> String {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeededLocked()
        return record.date
    }

    /// A "completed word" = a maximal run of non-whitespace characters in the accepted text (PRD §4.1).
    /// Emoji insertions are counted as 0 words by callers (they pass non-word accepts as empty/zero).
    static func wordCount(in text: String) -> Int {
        var count = 0
        var inRun = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inRun = false
            } else if !inRun {
                inRun = true
                count += 1
            }
        }
        return count
    }

    // MARK: - Rollover (+ clock-rollback guard)

    private func rolloverIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeededLocked()
    }

    private func rolloverIfNeededLocked() {
        let today = WordMeter.todayLocalString()
        // Clock-rollback guard (PRD §4.1): never let "today" fall below the highest date we've ever
        // observed. YYYY-MM-DD compares lexicographically == chronologically, so max() is the
        // high-water. Rolling the clock back keeps effectiveToday pinned -> no free reset.
        let effectiveToday = max(today, record.lastSeenMaxDate)
        var changed = false
        if record.date != effectiveToday {
            record.date = effectiveToday
            record.count = 0
            changed = true
        }
        if record.lastSeenMaxDate != effectiveToday {
            record.lastSeenMaxDate = effectiveToday   // monotonic; only ever advances
            changed = true
        }
        if changed { saveNow() }
    }

    // MARK: - Persistence (HMAC is applied/verified at these single choke points)

    // Caller holds `lock`. Synchronous, authoritative write of the whole record (sign + encode + atomic
    // write). Used for cap-relevant mutations (accept, rollover, init) where crash-durability matters.
    // Also persists any pending stat bumps, since the whole record is written.
    private func saveNow() {
        dirty = false
        record.hmac = WordMeter.mac(for: record, secret: secret)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    // Caller holds `lock`. Marks the record dirty and schedules a single coalesced background flush, so a
    // burst of cosmetic stat bumps (shown/accepted) collapses to one off-main disk write instead of one
    // write per event on the hot completion path.
    private func scheduleFlush() {
        dirty = true
        guard !flushScheduled else { return }
        flushScheduled = true
        saveQueue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.flush() }
    }

    /// Synchronously persist any unsaved in-memory changes. Safe to call from any thread. Invoked by the
    /// coalesced background flush, by tests for deterministic on-disk state, and should be called at app
    /// termination so the last shown-counts aren't lost.
    func flush() {
        lock.lock(); defer { lock.unlock() }
        flushScheduled = false
        guard dirty else { return }
        saveNow()
    }

    private static func load(from url: URL, secret: Data) -> Record? {
        guard let data = try? Data(contentsOf: url),
              let rec = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        guard verify(rec, secret: secret) else {
            NSLog("Shadowtype: WordMeter integrity check failed — resetting counter (PRD §4.1)")
            return nil
        }
        return rec
    }

    // MARK: - HMAC

    // Canonical payload over the authenticated fields (everything except `hmac`).
    private static func payload(for r: Record) -> Data {
        Data("\(r.date)|\(r.count)|\(r.installUUID)|\(r.lastSeenMaxDate)|\(r.wordsAllTime)|\(r.shownAllTime)|\(r.acceptedAllTime)".utf8)
    }

    private static func mac(for r: Record, secret: Data) -> String {
        let key = SymmetricKey(data: secret)
        return Data(HMAC<SHA256>.authenticationCode(for: payload(for: r), using: key)).base64EncodedString()
    }

    private static func verify(_ r: Record, secret: Data) -> Bool {
        guard let macData = Data(base64Encoded: r.hmac) else { return false }
        let key = SymmetricKey(data: secret)
        // Constant-time comparison (CryptoKit).
        return HMAC<SHA256>.isValidAuthenticationCode(macData, authenticating: payload(for: r), using: key)
    }

    // Build a correctly-signed record file. Used to provision/migrate and by tests to seed a
    // known counter state without reaching into the production Keychain/Application Support.
    static func makeSignedRecordData(date: String, count: Int, installUUID: String = "test-uuid",
                                     lastSeenMaxDate: String, secret: Data) -> Data {
        var r = Record(date: date, count: count, installUUID: installUUID,
                       lastSeenMaxDate: lastSeenMaxDate, hmac: "")
        r.hmac = mac(for: r, secret: secret)
        return (try? JSONEncoder().encode(r)) ?? Data()
    }

    // MARK: - Paths & dates

    private static func defaultStoreURL() -> URL {
        let base: URL
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first {
            base = appSupport
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        }
        // INTEGRATOR-NOTE: P2/M3 keeps this in Application Support. To satisfy PRD §4.1 ("app-group
        //   container") once the app ships an app-group entitlement, swap this base for
        //   FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:) — same filename.
        //   The HMAC already covers the "not plain UserDefaults / not hand-editable" intent.
        return base
            .appendingPathComponent("Shadowtype", isDirectory: true)
            .appendingPathComponent("meter.json", isDirectory: false)
    }

    private static func todayLocalString() -> String {
        // Compute Y-M-D via Calendar components rather than a DateFormatter: this runs on the hot
        // path (todayCount() is consulted on every fire() and every accept), and a DateFormatter is
        // one of the most expensive Foundation objects to construct. A fresh Calendar each call keeps
        // it thread-safe (no shared mutable formatter) and reflects a live time-zone change (PRD §4.1).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current // local system time zone (PRD §4.1)
        let c = cal.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Per-install secret (Keychain)

// A 32-byte random secret created once per install and kept in the login Keychain as a generic
// password. It never touches meter.json, so an attacker with the file alone can't forge the HMAC.
private enum KeychainSecret {
    private static let service = "com.shadowtype.wordmeter"
    private static let account = "hmac-key-v1"

    static func loadOrCreate() -> Data {
        if let existing = load() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Astronomically unlikely; fall back to UUID-derived entropy so the meter still works.
            bytes = Array((UUID().uuidString + UUID().uuidString).utf8.prefix(32))
        }
        let data = Data(bytes)
        store(data)
        return data
    }

    private static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return data
    }

    private static func store(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // ThisDeviceOnly: the anti-tamper secret must NOT migrate via iCloud Keychain or a
            // backup/restore to another Mac (that would let the same forge-valid meter.json move
            // across machines). It's a per-install secret by design (PRD §4.1).
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)   // idempotent: replace any prior value
        SecItemAdd(query as CFDictionary, nil)
    }
}
