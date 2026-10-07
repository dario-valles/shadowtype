// SnippetStore — the user's text snippets (`;sig` -> signature), persisted as JSON in Application
// Support. Mirrors InstructionStore/AppRules: shared singleton, NSLock, injectable `init(storeURL:)`
// test seam, atomic write. Plain (no HMAC): these are the user's own strings.
//
// The coordinator's hot path and the Settings Snippets pane both read/mutate `SnippetStore.shared` —
// one instance, cached in memory, so a Settings edit reaches the next keystroke without a relaunch.
//
// Corrupt-file tolerance: an unreadable file, or entries that fail to decode / validate, never crash
// and never block the user — the readable entries load and the rest are skipped. Because the next edit
// rewrites the file, the ORIGINAL bytes are first copied aside to `snippets.json.corrupt-<epoch>` so
// nothing the user wrote is silently destroyed.
import Foundation

enum SnippetValidationError: Error, Equatable {
    case invalidName
    case duplicateName
    case emptyExpansion
    case notFound

    var message: String {
        switch self {
        case .invalidName:
            return "Use 1–\(SnippetTrigger.maxNameLength) letters, digits, “-” or “_” — no spaces."
        case .duplicateName:  return "A snippet with that name already exists."
        case .emptyExpansion: return "The snippet text can’t be empty."
        case .notFound:       return "That snippet no longer exists."
        }
    }
}

final class SnippetStore {
    private struct Record: Encodable {
        var version = 1
        var snippets: [Snippet]
    }

    // Lossy mirror of Record for reading: a malformed entry decodes to nil instead of failing the file.
    private struct LossyRecord: Decodable {
        let snippets: [LossySnippet]
    }

    private struct LossySnippet: Decodable {
        let value: Snippet?
        init(from decoder: Decoder) throws {
            value = try? Snippet(from: decoder)
        }
    }

    private struct Loaded {
        var snippets: [Snippet]
        var damaged: Bool
    }

    private let lock = NSLock()
    private let storeURL: URL
    private let now: () -> Date
    private var snippets: [Snippet]
    // True when the on-disk file held something we couldn't load; the first save backs it up first.
    private var backupPending: Bool

    convenience init() {
        self.init(storeURL: SnippetStore.defaultStoreURL())
    }

    static let shared = SnippetStore()

    // Designated init — also the hermetic test seam (temp file). `now` only stamps the corrupt backup.
    init(storeURL: URL, now: @escaping () -> Date = Date.init) {
        self.storeURL = storeURL
        self.now = now
        let loaded = SnippetStore.load(from: storeURL)
        self.snippets = loaded.snippets
        self.backupPending = loaded.damaged
    }

    // MARK: - Reads

    /// Every snippet, sorted by name (the order Settings lists them in).
    func all() -> [Snippet] {
        lock.lock(); defer { lock.unlock() }
        return snippets.sorted { $0.name < $1.name }
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return snippets.isEmpty
    }

    // MARK: - Validation

    /// Why (name, expansion) can't be saved — or nil when it can. `excluding` is the snippet being
    /// edited, so renaming a snippet to its own name isn't a duplicate.
    func validate(name: String, expansion: String, excluding id: UUID? = nil) -> SnippetValidationError? {
        lock.lock(); defer { lock.unlock() }
        return validateLocked(name: name, expansion: expansion, excluding: id)
    }

    // MARK: - Mutations

    /// Add a snippet. The name is stored normalized (trimmed, lowercased); the expansion verbatim.
    @discardableResult
    func add(name: String, expansion: String) -> Result<Snippet, SnippetValidationError> {
        lock.lock(); defer { lock.unlock() }
        if let error = validateLocked(name: name, expansion: expansion, excluding: nil) {
            return .failure(error)
        }
        guard let normalized = SnippetTrigger.normalizedName(name) else { return .failure(.invalidName) }
        let snippet = Snippet(name: normalized, expansion: expansion)
        snippets.append(snippet)
        save()
        return .success(snippet)
    }

    /// Replace the name and expansion of the snippet with `id`. nil on success.
    @discardableResult
    func update(id: UUID, name: String, expansion: String) -> SnippetValidationError? {
        lock.lock(); defer { lock.unlock() }
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return .notFound }
        if let error = validateLocked(name: name, expansion: expansion, excluding: id) { return error }
        guard let normalized = SnippetTrigger.normalizedName(name) else { return .invalidName }
        let updated = Snippet(id: id, name: normalized, expansion: expansion)
        guard snippets[index] != updated else { return nil }
        snippets[index] = updated
        save()
        return nil
    }

    func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets.remove(at: index)
        save()
    }

    // MARK: - Helpers

    // Caller holds `lock`.
    private func validateLocked(name: String, expansion: String, excluding id: UUID?) -> SnippetValidationError? {
        guard let normalized = SnippetTrigger.normalizedName(name) else { return .invalidName }
        if snippets.contains(where: { $0.name == normalized && $0.id != id }) { return .duplicateName }
        if expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyExpansion }
        return nil
    }

    // MARK: - Persistence

    // Caller holds `lock`.
    private func save() {
        guard let data = try? JSONEncoder().encode(Record(snippets: snippets)) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if backupPending {
            backupPending = false
            let stamp = Int(now().timeIntervalSince1970)
            let backup = storeURL.deletingLastPathComponent()
                .appendingPathComponent("\(storeURL.lastPathComponent).corrupt-\(stamp)")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: storeURL, to: backup)
            }
        }
        try? data.write(to: storeURL, options: .atomic)
    }

    // Missing file -> empty and clean. Unreadable file -> empty and damaged. Otherwise every entry
    // that decodes with a valid, unique name and a non-blank expansion; anything dropped marks damaged.
    private static func load(from url: URL) -> Loaded {
        guard let data = try? Data(contentsOf: url) else { return Loaded(snippets: [], damaged: false) }
        guard let record = try? JSONDecoder().decode(LossyRecord.self, from: data) else {
            return Loaded(snippets: [], damaged: true)
        }
        var out: [Snippet] = []
        var seen = Set<String>()
        var damaged = false
        for entry in record.snippets {
            guard var snippet = entry.value,
                  let name = SnippetTrigger.normalizedName(snippet.name),
                  !snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(name).inserted else {
                damaged = true
                continue
            }
            snippet.name = name
            out.append(snippet)
        }
        return Loaded(snippets: out, damaged: damaged)
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
            .appendingPathComponent("snippets.json", isDirectory: false)
    }
}
