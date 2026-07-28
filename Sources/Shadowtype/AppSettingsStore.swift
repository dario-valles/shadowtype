// AppSettingsStore — per-app behavior tri-states that sit ALONGSIDE AppRules (Cotypist parity).
// AppRules owns the master "enable completions" switch (it already carries expiry, menu pause, and the
// global default). This store owns the *other* per-app knobs the Cotypist detail pane exposes:
// mid-line completions, autocorrect, Disable Tab, and collect-inputs — each a three-state
// Default / On / Off, where "Default" (.auto) defers to the corresponding global setting.
//
// Same shape as AppRules deliberately: NSLock, atomic JSON in Application Support, a `shared` singleton,
// and an injectable init(storeURL:) test seam. Decoding is tolerant so a file written by an older build
// (missing a field) still loads.
import Foundation

/// Per-app override for a boolean behavior. `.auto` follows the global setting; `.on`/`.off` force it.
enum TriState: String, Codable, CaseIterable {
    case auto, on, off

    /// Resolve against the global default. Pure — the single place the three-state collapses to a Bool.
    static func resolve(_ state: TriState, globalDefault: Bool) -> Bool {
        switch state {
        case .auto: return globalDefault
        case .on:   return true
        case .off:  return false
        }
    }
}

struct AppConfig: Codable, Equatable {
    var midLine: TriState
    var autocorrect: TriState
    var disableTab: TriState
    var collectInputs: TriState
    var rightArrowAccept: TriState
    // Terminal shell-command mode: auto-fire a single shell-command ghost at a plain shell prompt.
    // Default OFF (terminals stay quiet); the global default passed at resolve() is false. The
    // force-activate hotkey produces a command regardless of this toggle.
    var shellCommands: TriState

    init(midLine: TriState = .auto, autocorrect: TriState = .auto,
         disableTab: TriState = .auto, collectInputs: TriState = .auto,
         rightArrowAccept: TriState = .auto, shellCommands: TriState = .auto) {
        self.midLine = midLine
        self.autocorrect = autocorrect
        self.disableTab = disableTab
        self.collectInputs = collectInputs
        self.rightArrowAccept = rightArrowAccept
        self.shellCommands = shellCommands
    }

    // Tolerant: a field absent from an older file falls back to .auto (the inert default).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        midLine          = try c.decodeIfPresent(TriState.self, forKey: .midLine) ?? .auto
        autocorrect      = try c.decodeIfPresent(TriState.self, forKey: .autocorrect) ?? .auto
        disableTab       = try c.decodeIfPresent(TriState.self, forKey: .disableTab) ?? .auto
        collectInputs    = try c.decodeIfPresent(TriState.self, forKey: .collectInputs) ?? .auto
        rightArrowAccept = try c.decodeIfPresent(TriState.self, forKey: .rightArrowAccept) ?? .auto
        shellCommands    = try c.decodeIfPresent(TriState.self, forKey: .shellCommands) ?? .auto
    }

    /// An all-`.auto` config carries no overrides — used to prune empty entries so the store and the
    /// Settings app-list don't accumulate no-op rows.
    var isDefault: Bool {
        midLine == .auto && autocorrect == .auto && disableTab == .auto
            && collectInputs == .auto && rightArrowAccept == .auto && shellCommands == .auto
    }
}

final class AppSettingsStore {
    private static let formatVersion = 1

    private struct Envelope: Encodable {
        let version: Int
        let apps: [String: AppConfig]
    }

    private struct LoadResult {
        let apps: [String: AppConfig]
        let canPersist: Bool
    }

    private let lock = NSLock()
    private let storeURL: URL
    private let createDirectory: (URL) throws -> Void
    private let atomicWrite: (Data, URL) throws -> Void
    private let canPersist: Bool
    private var byBundle: [String: AppConfig]

    static let shared = AppSettingsStore()

    convenience init() { self.init(storeURL: AppSettingsStore.defaultStoreURL()) }

    // Designated init / test seams. The persistence closures let tests exercise failures without
    // relying on process privileges or a particular filesystem.
    init(
        storeURL: URL,
        createDirectory: @escaping (URL) throws -> Void = {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        },
        atomicWrite: @escaping (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) {
        self.storeURL = storeURL
        self.createDirectory = createDirectory
        self.atomicWrite = atomicWrite
        let loaded = AppSettingsStore.load(from: storeURL)
        self.byBundle = loaded.apps
        self.canPersist = loaded.canPersist
    }

    // MARK: - Query

    func config(forBundleId bundleId: String?) -> AppConfig {
        guard let bundleId else { return AppConfig() }
        lock.lock(); defer { lock.unlock() }
        return byBundle[bundleId] ?? AppConfig()
    }

    /// Resolve one field for an app against its global default. Convenience over config()+TriState.resolve.
    func resolve(_ field: KeyPath<AppConfig, TriState>, forBundleId bundleId: String?,
                 globalDefault: Bool) -> Bool {
        TriState.resolve(config(forBundleId: bundleId)[keyPath: field], globalDefault: globalDefault)
    }

    /// Bundle ids that carry at least one non-`.auto` override (for the Settings app list).
    func configuredBundleIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(byBundle.keys)
    }

    // MARK: - Mutation

    @discardableResult
    func set(
        _ value: TriState,
        _ field: WritableKeyPath<AppConfig, TriState>,
        forBundleId bundleId: String
    ) -> Bool {
        guard !bundleId.isEmpty else { return false }
        lock.lock()
        let previous = byBundle
        var cfg = byBundle[bundleId] ?? AppConfig()
        cfg[keyPath: field] = value
        if cfg.isDefault { byBundle[bundleId] = nil }   // drop no-op entries
        else { byBundle[bundleId] = cfg }
        guard byBundle != previous else {
            lock.unlock()
            return true
        }
        do {
            try save()
        } catch {
            byBundle = previous
            lock.unlock()
            NSLog("Shadowtype: AppSettingsStore failed to persist setting: \(error)")
            return false
        }
        lock.unlock()
        AppSettingsStore.notifyChanged()
        return true
    }

    /// Drop every override for an app (used by the per-app "reset" affordance).
    @discardableResult
    func clear(bundleId: String) -> Bool {
        lock.lock()
        guard let previousConfig = byBundle.removeValue(forKey: bundleId) else {
            lock.unlock()
            return true
        }
        do {
            try save()
        } catch {
            byBundle[bundleId] = previousConfig
            lock.unlock()
            NSLog("Shadowtype: AppSettingsStore failed to clear setting: \(error)")
            return false
        }
        lock.unlock()
        AppSettingsStore.notifyChanged()
        return true
    }

    // Posted on the main queue so observers (e.g. the Tab tap refresh) don't touch UI off-thread. The
    // store itself is mutated on the main thread today, but the hop keeps it safe regardless of caller.
    private static func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .shadowtypeAppSettingsDidChange, object: nil)
        }
    }

    // MARK: - Persistence (mirrors AppRules)

    private func save() throws {
        guard canPersist else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSURLErrorKey: storeURL,
                NSLocalizedDescriptionKey: "The existing settings file could not be quarantined."
            ])
        }
        let envelope = Envelope(version: Self.formatVersion, apps: byBundle)
        let data = try JSONEncoder().encode(envelope)
        try createDirectory(storeURL.deletingLastPathComponent())
        try atomicWrite(data, storeURL)
    }

    private static func load(from url: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadResult(apps: [:], canPersist: true)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return quarantine(url, reason: "could not read settings: \(error)", recovered: [:])
        }

        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return quarantine(url, reason: "top-level JSON is not an object", recovered: [:])
            }
            root = object
        } catch {
            return quarantine(url, reason: "malformed JSON: \(error)", recovered: [:])
        }

        let rawApps: [String: Any]
        var recoveryReasons: [String] = []
        if root["version"] != nil || root["apps"] != nil {
            guard let apps = root["apps"] as? [String: Any] else {
                return quarantine(url, reason: "versioned envelope has no apps object", recovered: [:])
            }
            rawApps = apps
            if (root["version"] as? NSNumber)?.intValue != formatVersion {
                recoveryReasons.append("unsupported settings version \(String(describing: root["version"]))")
            }
        } else {
            // Pre-versioning files were a bare bundle-id → AppConfig dictionary.
            rawApps = root
        }

        var recovered: [String: AppConfig] = [:]
        let decoder = JSONDecoder()
        for (bundleId, rawConfig) in rawApps {
            do {
                guard JSONSerialization.isValidJSONObject(rawConfig) else {
                    throw CocoaError(.propertyListReadCorrupt)
                }
                let entryData = try JSONSerialization.data(withJSONObject: rawConfig)
                let config = try decoder.decode(AppConfig.self, from: entryData)
                if !config.isDefault {
                    recovered[bundleId] = config
                }
            } catch {
                recoveryReasons.append("\(bundleId): \(error)")
            }
        }

        guard !recoveryReasons.isEmpty else {
            return LoadResult(apps: recovered, canPersist: true)
        }
        return quarantine(
            url,
            reason: "recovered valid entries; " + recoveryReasons.joined(separator: "; "),
            recovered: recovered
        )
    }

    private static func quarantine(
        _ url: URL,
        reason: String,
        recovered: [String: AppConfig]
    ) -> LoadResult {
        let quarantineURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(UUID().uuidString)")
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try FileManager.default.moveItem(at: url, to: quarantineURL)
            NSLog(
                "Shadowtype: AppSettingsStore quarantined invalid settings at %@ (%@)",
                quarantineURL.path,
                reason
            )
            return LoadResult(apps: recovered, canPersist: true)
        } catch {
            NSLog(
                "Shadowtype: AppSettingsStore could not quarantine invalid settings at %@ (%@; %@); refusing to overwrite it",
                url.path,
                reason,
                String(describing: error)
            )
            return LoadResult(apps: recovered, canPersist: false)
        }
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
            .appendingPathComponent("app-settings.json", isDirectory: false)
    }
}
