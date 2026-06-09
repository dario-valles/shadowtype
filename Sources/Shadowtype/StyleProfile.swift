// StyleProfile — on-device, encrypted, user-wipeable writing-style personalization (PRD FR-CTX-3, PAID).
// Biases generation toward the user's own phrasing WITHOUT an embedding model: it maintains a compact,
// lightweight model of how the user writes — (a) word + multi-word n-gram frequency counts and (b) a
// bounded recent list of accepted phrasings — and renders that into a short "style hint" string the
// integrator prepends as leading prompt context (the same prompt-prepend architecture used for OCR
// screen context, see ScreenContextProvider). Given the prompt-prepend design, surfacing the user's
// characteristic vocabulary + recent phrasings is how style actually reaches the generator.
//
// Privacy + tamper posture (PRD FR-CTX-3: "Stored encrypted in Application Support; never transmitted;
// user can wipe it"):
//   • The whole on-disk store is encrypted with AES-GCM (CryptoKit AES.GCM.seal) under a 32-byte
//     per-install secret kept in the Keychain — NEVER in this file. The Keychain-secret approach mirrors
//     WordMeter's KeychainSecret, but with a SEPARATE service/account so the two stores never share a key.
//   • Confidentiality (not just integrity): an attacker with the file alone sees only ciphertext, so the
//     user's learned phrasings are not readable on disk. A file written under a different secret fails to
//     decrypt and we fail closed to an empty profile (no crash) — same "missing/forged -> fresh" stance
//     as WordMeter.
//   • Nothing here ever leaves the device; this type does no networking.
//
// This is paid-gated at runtime by the integrator behind CompletionCoordinator.isLicensed (see notes);
// this component itself is gate-agnostic — it just learns + emits a hint when asked.
import Foundation
import Security
import CryptoKit

final class StyleProfile {
    // One learning bucket: the n-gram table + recent phrasings + a count of accepted inputs. Per-app
    // buckets let the Settings detail pane show "N inputs collected" and delete a single app's
    // contribution; at suggestion time the buckets are merged into one style hint.
    struct Bucket: Codable, Equatable {
        // Frequency table over normalized 1- and 2-word n-grams -> occurrence count. Bounded by
        // `maxNGrams` (lowest-count entries are pruned) so the table can't grow without limit.
        var nGramCounts: [String: Int]
        // Most-recently-accepted normalized phrasings, newest last. Bounded by `maxRecent`.
        var recentPhrases: [String]
        // Total accepted inputs folded into this bucket (the Cotypist "N inputs collected" figure).
        var inputCount: Int

        init(nGramCounts: [String: Int] = [:], recentPhrases: [String] = [], inputCount: Int = 0) {
            self.nGramCounts = nGramCounts
            self.recentPhrases = recentPhrases
            self.inputCount = inputCount
        }
        // Tolerant: a pre-bucket file has no inputCount; absent fields decode to empty/zero.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nGramCounts   = try c.decodeIfPresent([String: Int].self, forKey: .nGramCounts) ?? [:]
            recentPhrases = try c.decodeIfPresent([String].self, forKey: .recentPhrases) ?? []
            inputCount    = try c.decodeIfPresent(Int.self, forKey: .inputCount) ?? 0
        }
    }

    // On-disk (pre-encryption) record: a bucket per app plus a `legacy` bucket that holds the old single
    // global profile (migrated on first load) and any nil-bundle accepts. The entire encoded Record is
    // sealed with AES-GCM before it touches disk, so none of these fields are ever stored in plaintext.
    private struct Record: Codable {
        var perApp: [String: Bucket]
        var legacy: Bucket

        init(perApp: [String: Bucket] = [:], legacy: Bucket = Bucket()) {
            self.perApp = perApp
            self.legacy = legacy
        }
        // Migration: a NEW file carries `perApp`; an OLD (pre-bucket) file has nGramCounts/recentPhrases
        // at the top level — decode that as one Bucket and seat it as `legacy` so existing learning
        // survives the upgrade.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let per = try c.decodeIfPresent([String: Bucket].self, forKey: .perApp) {
                perApp = per
                legacy = try c.decodeIfPresent(Bucket.self, forKey: .legacy) ?? Bucket()
            } else {
                perApp = [:]
                legacy = (try? Bucket(from: decoder)) ?? Bucket()
            }
        }
        private enum CodingKeys: String, CodingKey { case perApp, legacy }
    }

    private let lock = NSLock()
    private let storeURL: URL
    private let secret: Data
    private var record: Record
    // recordAccepted() runs on the MAIN thread (it's called from the Tab-accept path). The encrypt +
    // atomic-write is therefore done on this background serial queue so the JSON-encode + AES-GCM-seal +
    // fsync never adds latency to an accept. Serial + FIFO so writes (and wipe's delete) stay ordered;
    // the in-memory `record` (under `lock`) remains the source of truth read by styleHint().
    private let persistQueue = DispatchQueue(label: "com.shadowtype.styleprofile.persist", qos: .utility)

    // Bounded growth (PRD FR-CTX-3): keep the on-device model small + cheap to load/seal.
    private let maxRecent = 50          // recent accepted phrasings retained
    private let maxNGrams = 400         // distinct 1-/2-word n-grams retained (lowest counts pruned)
    private let maxPhraseWords = 6      // ignore long phrasings as "style" — they're content, not voice
    private let minWordLength = 2       // skip 1-char tokens from the n-gram table (noise)

    // Production: per-install secret from the Keychain, store in Application Support next to the other
    // Shadowtype stores.
    convenience init() {
        self.init(storeURL: StyleProfile.defaultStoreURL(), secret: KeychainSecret.loadOrCreate())
    }

    // Single shared instance: the coordinator records accepted text and builds the style hint on the
    // same in-memory record, so learning is immediately reflected in the next prompt without a reload.
    // Tests use the injectable init(storeURL:secret:) to stay hermetic.
    static let shared = StyleProfile()

    // Designated init — also the seam for tests (hermetic temp file + known secret). A missing or
    // undecryptable file (wrong secret / corruption) loads as an empty profile and never throws.
    init(storeURL: URL, secret: Data) {
        self.storeURL = storeURL
        self.secret = secret
        self.record = StyleProfile.load(from: storeURL, secret: secret) ?? Record()
    }

    // MARK: - Learning (FR-CTX-3)

    /// Learn from an accepted phrasing in a given app: fold its words/2-grams into that app's bucket
    /// (or the `legacy` bucket when `bundleId` is nil), push the normalized phrase onto the bounded
    /// recent list, bump the bucket's input count, then persist (encrypted). No-op for empty/
    /// whitespace-only input or for pastes longer than `maxPhraseWords` (not representative "style").
    func recordAccepted(_ text: String, bundleId: String? = nil) {
        let words = StyleProfile.tokenize(text)
        guard !words.isEmpty, words.count <= maxPhraseWords else { return }

        lock.lock(); defer { lock.unlock() }
        if let bundleId {
            var b = record.perApp[bundleId] ?? Bucket()
            fold(words, into: &b)
            record.perApp[bundleId] = b
        } else {
            fold(words, into: &record.legacy)
        }
        persist(record)   // snapshot written off the main thread (serial, ordered)
    }

    // Caller holds `lock`. Fold an accepted phrasing's unigrams (>= minWordLength) and adjacent bigrams
    // into a bucket, de-dup the phrase onto its bounded recent list, prune the table, and bump the count.
    private func fold(_ words: [String], into bucket: inout Bucket) {
        for w in words where w.count >= minWordLength {
            bucket.nGramCounts[w, default: 0] += 1
        }
        if words.count >= 2 {
            for i in 0..<(words.count - 1) {
                bucket.nGramCounts[words[i] + " " + words[i + 1], default: 0] += 1
            }
        }
        StyleProfile.pruneNGrams(&bucket.nGramCounts, max: maxNGrams)

        let phrase = words.joined(separator: " ")
        bucket.recentPhrases.removeAll { $0 == phrase }
        bucket.recentPhrases.append(phrase)
        if bucket.recentPhrases.count > maxRecent {
            bucket.recentPhrases.removeFirst(bucket.recentPhrases.count - maxRecent)
        }
        bucket.inputCount += 1
    }

    // MARK: - Prompt hint (FR-CTX-3)

    /// A short, prepend-ready style hint built from the user's most representative material — the most
    /// recent phrasings plus the most frequent multi-word n-grams (which carry phrasing character better
    /// than single words) — capped to `maxChars`. Returns nil when the profile is empty (so the
    /// integrator simply prepends nothing). The shape mirrors how OCR context is surfaced: a tagged
    /// leading line the model can condition on.
    func styleHint(maxChars: Int) -> String? {
        guard maxChars > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }

        // Merge every bucket's n-gram counts (legacy + all per-app) into one frequency table — the hint
        // reflects the user's voice across all apps that contributed. Turning collect-inputs off for an
        // app simply stops new folds; its existing data still counts until the app is deleted.
        var merged = record.legacy.nGramCounts
        for b in record.perApp.values {
            for (k, v) in b.nGramCounts { merged[k, default: 0] += v }
        }
        guard !merged.isEmpty else { return nil }

        // Style = register/vocabulary, NOT verbatim content. Emit only the user's most frequent SHORT
        // n-grams (1- and 2-word). We deliberately DO NOT surface `recentPhrases` (sentence-level content
        // the base model parrots verbatim across unrelated contexts — a Notes story bleeding into a Slack
        // message). Also skip any n-gram containing a digit: stray numerals are noise, not style.
        let isStyleToken: (String) -> Bool = { !$0.contains(where: { $0.isNumber }) }

        // Most frequent multi-word n-grams first (carry phrasing register; ties broken alphabetically).
        let topBigrams = merged
            .filter { $0.key.contains(" ") && isStyleToken($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8)
            .map { $0.key }

        // Most frequent single words — short, so they keep the hint non-empty under a tight budget.
        let topWords = merged
            .filter { !$0.key.contains(" ") && isStyleToken($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8)
            .map { $0.key }

        // Bigrams first (phrasing register), then unigrams as budget-friendly fallbacks. De-dup overlaps.
        var items: [String] = []
        var seen = Set<String>()
        for b in topBigrams where seen.insert(b).inserted { items.append(b) }
        for w in topWords where seen.insert(w).inserted { items.append(w) }
        guard !items.isEmpty else { return nil }

        // Build the tagged hint, adding items only while they fit under maxChars (never truncating an
        // item mid-word — a partial phrase would be misleading style guidance).
        let prefix = "User writing style — favors: "
        guard prefix.count < maxChars else { return nil }
        var hint = prefix
        var added = 0
        for item in items {
            let piece = (added == 0 ? "" : "; ") + item
            // Skip an item that overflows the budget rather than stopping: a later, shorter item
            // (e.g. a single high-frequency word) may still fit, so a tight cap stays non-empty.
            if hint.count + piece.count > maxChars { continue }
            hint += piece
            added += 1
        }
        guard added > 0 else { return nil }
        return hint
    }

    // MARK: - Wipe (FR-CTX-3: "user can wipe it")

    /// Clear the in-memory profile and delete the on-disk store. Idempotent; safe if no file exists.
    /// The delete is enqueued on `persistQueue` so it lands AFTER any in-flight write (FIFO) — otherwise
    /// a pending recordAccepted write could recreate the file just after wipe removed it.
    func wipe() {
        lock.lock(); record = Record(); lock.unlock()
        let url = storeURL
        persistQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Inputs collected for one app (the Cotypist "N inputs collected" figure). 0 for an unknown app.
    func inputCount(forBundleId bundleId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return record.perApp[bundleId]?.inputCount ?? 0
    }

    /// Delete a single app's contribution (the per-app "Delete" button). Other apps + legacy are kept.
    func deleteApp(bundleId: String) {
        lock.lock()
        let had = record.perApp.removeValue(forKey: bundleId) != nil
        let snapshot = record
        lock.unlock()
        guard had else { return }
        persist(snapshot)
    }

    /// Block until all queued writes/deletes have flushed. For tests (deterministic round-trips) and a
    /// clean shutdown; not used on the hot path.
    func flushPendingWrites() { persistQueue.sync {} }

    /// Read-only snapshot for the Personalization pane: distinct learned n-grams and the encrypted
    /// store's on-disk size. Cheap; never touches the hot path.
    func profileStats() -> (phrases: Int, sizeBytes: Int) {
        lock.lock()
        var keys = Set(record.legacy.nGramCounts.keys)
        for b in record.perApp.values { keys.formUnion(b.nGramCounts.keys) }
        let phrases = keys.count
        lock.unlock()
        let size = ((try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.size]) as? Int) ?? 0
        return (phrases, size)
    }

    // MARK: - Bounded growth

    // Keep only the `max` highest-count entries; drop the rest. Ties broken alphabetically so pruning is
    // deterministic (matters for the hint's stability across launches). Pure (operates on the passed map).
    static func pruneNGrams(_ counts: inout [String: Int], max: Int) {
        guard counts.count > max else { return }
        let kept = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(max)
        counts = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    // MARK: - Tokenization

    // Normalize an accepted string to a list of lowercased word tokens: split on non-alphanumerics so
    // punctuation never becomes part of an n-gram, and lowercase so "Thanks"/"thanks" share a count.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    // MARK: - Persistence (AES-GCM at these single choke points)

    // Encode -> AES-GCM seal under the per-install secret -> atomic write, on the background serial queue
    // (FIFO with wipe). `snapshot` is a by-value copy of the record taken on the caller's thread, so the
    // write sees a consistent state without holding `lock` across the IO. A seal failure (astronomically
    // unlikely) simply skips the write, leaving the prior file intact.
    private func persist(_ snapshot: Record) {
        let url = storeURL, secret = secret
        persistQueue.async {
            guard let plaintext = try? JSONEncoder().encode(snapshot),
                  let sealed = try? StyleProfile.seal(plaintext, secret: secret) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? sealed.write(to: url, options: .atomic)
        }
    }

    // Missing / corrupt / wrong-secret file -> nil (fail closed to an empty profile, no crash).
    private static func load(from url: URL, secret: Data) -> Record? {
        guard let sealed = try? Data(contentsOf: url) else { return nil }
        guard let plaintext = try? open(sealed, secret: secret) else {
            NSLog("Shadowtype: StyleProfile decryption failed — starting empty (PRD FR-CTX-3)")
            return nil
        }
        return try? JSONDecoder().decode(Record.self, from: plaintext)
    }

    // MARK: - AES-GCM (CryptoKit)

    // The on-disk bytes are the AES-GCM combined representation (nonce ‖ ciphertext ‖ tag), so there is
    // no separate IV to manage and tampering is detected on open.
    private static func seal(_ plaintext: Data, secret: Data) throws -> Data {
        let key = SymmetricKey(data: secret)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw StyleProfileError.sealFailed }
        return combined
    }

    private static func open(_ sealed: Data, secret: Data) throws -> Data {
        let key = SymmetricKey(data: secret)
        let box = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(box, using: key)
    }

    private enum StyleProfileError: Error { case sealFailed }

    // MARK: - Paths

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
            .appendingPathComponent("style-profile.bin", isDirectory: false)
    }
}

// MARK: - Per-install secret (Keychain)

// A 32-byte random AES key created once per install and kept in the login Keychain as a generic
// password. SEPARATE service/account from WordMeter's so the two stores never share a key. It never
// touches style-profile.bin, so the file alone reveals only ciphertext.
private enum KeychainSecret {
    private static let service = "com.shadowtype.styleprofile"
    private static let account = "aes-key-v1"

    static func loadOrCreate() -> Data {
        if let existing = load() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Astronomically unlikely; fall back to UUID-derived entropy so the profile still works.
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
            // ThisDeviceOnly: the personalization key must NOT migrate via iCloud Keychain or a
            // backup/restore — the encrypted profile is per-install by design (PRD FR-CTX-3).
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)   // idempotent: replace any prior value
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            // If the key can't be stored, the next launch mints a different one and the existing encrypted
            // profile becomes undecryptable (silently wiped). Surface it rather than swallow the OSStatus.
            NSLog("Shadowtype: StyleProfile Keychain store failed (OSStatus \(status)); profile may not persist across launches")
        }
    }
}
