// ImportedModelStore — JSON-backed registry of user-imported `.gguf` models (M3 BYOM local +
// M4 BYOM HF). Lives at `~/Library/Application Support/Shadowtype/imports.json`. Entries are
// unioned with `ModelCatalog.entries` by the Settings Models pane so an imported model is
// indistinguishable from a curated one from the user's perspective: same select/load/swap path,
// same UserDefaults `selectedModelID`.
//
// Storage shape:
//   { "version": 1, "imports": [ { id, name, fileName, linkedPath, originalPath, approxRAMGB,
//     source, createdAt } ] }
//
// Files are symlinked, not copied — a 26 GB Gemma-4 import shouldn't double on disk. The symlink
// lives under `~/Library/Application Support/Shadowtype/models/imported/`; deleting an import
// removes the symlink + JSON entry, never the user's original file.
import Foundation

struct ImportedModelEntry: Codable, Equatable, Identifiable {
    let id: String                    // "byom-<uuid>" — distinct from curated catalog ids
    var name: String                  // display name (defaults to file basename, user-renamable)
    var fileName: String              // basename (used inside Models pane rows)
    var linkedPath: String            // absolute path to the symlink under models/imported/
    var originalPath: String?         // source path (local import); nil for HF downloads
    var approxRAMGB: Double            // best-effort estimate from the file size on disk
    var source: Source                // .localFile or .huggingFace(repoURL)
    var createdAt: Date

    enum Source: String, Codable {
        case localFile
        case huggingFace
    }

    // Adapter: produce a ModelCatalogEntry so downstream code (Models pane, ModelManager,
    // AppDelegate's swap path) treats imported and curated models uniformly. `url` is a file://
    // URL pointing at the symlink so the downloader never touches it (the file is already local).
    //
    // BYOM (bring-your-own-model) is available to everyone; there is no runtime gate.
    // `paidOnly` is a legacy field that is always false.
    var asCatalogEntry: ModelCatalogEntry {
        ModelCatalogEntry(
            id: id,
            name: name,
            fileName: fileName,
            url: URL(fileURLWithPath: linkedPath),
            sha256: nil,
            approxRAMGB: approxRAMGB,
            downloadGB: 0,
            paidOnly: false
        )
    }
}

final class ImportedModelStore {
    static let shared = ImportedModelStore()

    private let storeURL: URL
    private let importsDir: URL
    private let queue = DispatchQueue(label: "com.shadowtype.imports")
    private var cached: [ImportedModelEntry] = []
    private var loaded = false

    init(storeURL: URL? = nil, importsDir: URL? = nil) {
        let appSupport = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                       in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let base = appSupport.appendingPathComponent("Shadowtype", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.storeURL = storeURL ?? base.appendingPathComponent("imports.json")
        self.importsDir = importsDir ?? base.appendingPathComponent("models/imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.importsDir, withIntermediateDirectories: true)
    }

    // Returns the live snapshot. Lazy first-load so launch doesn't pay the disk read until a
    // surface (Models pane, AppDelegate's startup model resolver) actually asks.
    func entries() -> [ImportedModelEntry] {
        queue.sync {
            if !loaded { loadFromDisk(); loaded = true }
            return cached
        }
    }

    func find(id: String) -> ImportedModelEntry? {
        entries().first(where: { $0.id == id })
    }

    // Persist a freshly-imported entry. Caller has already placed the symlink + validated the GGUF.
    func insert(_ entry: ImportedModelEntry) {
        queue.sync {
            if !loaded { loadFromDisk(); loaded = true }
            // Dedup by linkedPath: re-importing the same target replaces the prior entry.
            cached.removeAll(where: { $0.linkedPath == entry.linkedPath })
            cached.append(entry)
            writeToDisk()
        }
    }

    // Remove the symlink + JSON entry. Returns true if anything was removed. Never touches the
    // user's original file (only the symlink).
    @discardableResult
    func remove(id: String) -> Bool {
        queue.sync {
            if !loaded { loadFromDisk(); loaded = true }
            guard let idx = cached.firstIndex(where: { $0.id == id }) else { return false }
            let entry = cached.remove(at: idx)
            // Remove the symlink; ignore failure (file might already be gone).
            try? FileManager.default.removeItem(atPath: entry.linkedPath)
            writeToDisk()
            return true
        }
    }

    // Create the unique symlink for a fresh import + return the absolute path to it. The caller
    // then constructs the ImportedModelEntry pointing at this path and calls `insert(_:)`.
    // Naming: prefer the original basename; on collision append "-2", "-3", … so a second
    // "Qwen3.gguf" import doesn't overwrite the first.
    //
    // Review #4 fixes:
    //   (a) Serialized under `queue.sync` like every other mutator — concurrent imports of the
    //       same filename no longer race past the collision check.
    //   (b) `pathExists(...)` uses lstat semantics (URLResourceValues.isSymbolicLinkKey OR
    //       fileExists) so a broken symlink from a deleted source counts as "occupied" and gets
    //       a -N suffix, instead of being invisible to fileExists then tripping EEXIST on
    //       createSymbolicLink.
    func createSymlink(from source: URL) throws -> String {
        try queue.sync {
            let base = source.lastPathComponent
            let fm = FileManager.default
            try fm.createDirectory(at: importsDir, withIntermediateDirectories: true)
            var candidate = importsDir.appendingPathComponent(base)
            if Self.pathExists(at: candidate) {
                let nameNoExt = (base as NSString).deletingPathExtension
                let ext = (base as NSString).pathExtension
                for i in 2...999 {
                    let trial = importsDir.appendingPathComponent(ext.isEmpty
                        ? "\(nameNoExt)-\(i)" : "\(nameNoExt)-\(i).\(ext)")
                    if !Self.pathExists(at: trial) { candidate = trial; break }
                }
                if Self.pathExists(at: candidate) {
                    throw NSError(domain: "ImportedModelStore", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "ran out of unique suffixes for \(base)"])
                }
            }
            try fm.createSymbolicLink(at: candidate, withDestinationURL: source)
            return candidate.path
        }
    }

    // FileManager.fileExists(atPath:) follows symlinks — a dangling link from a deleted source
    // returns false, then createSymbolicLink(at:) throws EEXIST because the link node still
    // occupies the path. Use lstat-equivalent checks: a path is "occupied" if either a regular
    // file/dir lives there, or it's a symbolic link (broken or not).
    private static func pathExists(at url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        if let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           vals.isSymbolicLink == true { return true }
        return false
    }

    func generateID() -> String {
        "byom-" + UUID().uuidString.lowercased()
    }

    // --- Persistence -------------------------------------------------------------------------

    private struct Wire: Codable {
        let version: Int
        let imports: [ImportedModelEntry]
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { cached = []; return }
        guard let data = try? Data(contentsOf: storeURL) else { cached = []; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let wire = try decoder.decode(Wire.self, from: data)
            cached = wire.imports
        } catch {
            NSLog("Shadowtype: ImportedModelStore failed to decode imports.json (\(error)); starting empty")
            cached = []
        }
    }

    private func writeToDisk() {
        let wire = Wire(version: 1, imports: cached)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(wire)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            NSLog("Shadowtype: ImportedModelStore failed to write imports.json: \(error)")
        }
    }
}
