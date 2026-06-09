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
    private let lock = NSLock()
    private let storeURL: URL
    private var byBundle: [String: AppConfig]

    static let shared = AppSettingsStore()

    convenience init() { self.init(storeURL: AppSettingsStore.defaultStoreURL()) }

    // Designated init / test seam.
    init(storeURL: URL) {
        self.storeURL = storeURL
        self.byBundle = AppSettingsStore.load(from: storeURL) ?? [:]
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

    func set(_ value: TriState, _ field: WritableKeyPath<AppConfig, TriState>, forBundleId bundleId: String) {
        guard !bundleId.isEmpty else { return }
        lock.lock()
        var cfg = byBundle[bundleId] ?? AppConfig()
        cfg[keyPath: field] = value
        if cfg.isDefault { byBundle[bundleId] = nil }   // drop no-op entries
        else { byBundle[bundleId] = cfg }
        save()
        lock.unlock()
        AppSettingsStore.notifyChanged()
    }

    /// Drop every override for an app (used by the per-app "reset" affordance).
    func clear(bundleId: String) {
        lock.lock()
        let had = byBundle[bundleId] != nil
        if had { byBundle[bundleId] = nil; save() }
        lock.unlock()
        if had { AppSettingsStore.notifyChanged() }
    }

    // Posted on the main queue so observers (e.g. the Tab tap refresh) don't touch UI off-thread. The
    // store itself is mutated on the main thread today, but the hop keeps it safe regardless of caller.
    private static func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .shadowtypeAppSettingsDidChange, object: nil)
        }
    }

    // MARK: - Persistence (mirrors AppRules)

    private func save() {
        guard let data = try? JSONEncoder().encode(byBundle) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    private static func load(from url: URL) -> [String: AppConfig]? {
        guard let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode([String: AppConfig].self, from: data) else { return nil }
        return m
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
