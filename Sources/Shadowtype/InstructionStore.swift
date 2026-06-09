// InstructionStore — custom global + per-app AI instructions (FR-PA-3, paid).
// PAID tier: the user can write a free-form GLOBAL instruction that steers every completion
// (e.g. "be concise, no emojis") and PER-APP overrides keyed by frontmost bundle id (e.g. casual
// in Slack, formal in Mail). Persisted as JSON in Application Support so the choice survives
// relaunch. Mirrors AppRules exactly: shared singleton, NSLock, injectable `init(storeURL:)` test
// seam, atomic write.
//
// Like AppRules (and unlike WordMeter) this is plain (no HMAC): these are user preferences, not an
// anti-tamper counter — editing the file just changes the user's own prompt text, which is harmless.
//
// The coordinator's prompt assembly and the Settings Instructions pane both read/mutate
// `InstructionStore.shared` — a single instance. InstructionStore caches its record in memory
// (loaded once at init), so these MUST share one instance or a Settings edit wouldn't reach the
// coordinator until relaunch. Tests use the injectable `init(storeURL:)` instead and stay hermetic.
//
// Gating: every read of effectiveInstruction() at the coordinator MUST be wrapped in
// `CompletionCoordinator.isLicensed` — this is a paid feature. The store itself is gate-agnostic.
import Foundation

final class InstructionStore {
    private struct Record: Codable {
        var globalInstruction: String
        var perApp: [String: String]
    }

    private let lock = NSLock()
    private let storeURL: URL
    private let defaults: UserDefaults
    private var record: Record

    // Production: store in Application Support alongside app-rules.json / meter.json.
    convenience init() {
        self.init(storeURL: InstructionStore.defaultStoreURL())
    }

    // The one instance shared by the coordinator's prompt assembly and the Settings Instructions pane.
    static let shared = InstructionStore()

    // Designated init — also the seam for hermetic tests (temp file + injectable defaults). Loads
    // existing instructions. `defaults` backs only the personalization seed (name/languages/voice),
    // not the instruction text itself (which lives in `instructions.json`).
    init(storeURL: URL, defaults: UserDefaults = .standard) {
        self.storeURL = storeURL
        self.defaults = defaults
        self.record = InstructionStore.load(from: storeURL)
            ?? Record(globalInstruction: "", perApp: [:])
    }

    // MARK: - Global instruction (FR-PA-3)

    /// The free-form global instruction applied to every completion. Empty string when unset.
    func globalInstruction() -> String {
        lock.lock(); defer { lock.unlock() }
        return record.globalInstruction
    }

    /// Replace the global instruction. Stored verbatim (the user owns leading/trailing whitespace);
    /// effectiveInstruction() does the trimming-aware emptiness check at read time.
    func setGlobalInstruction(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard record.globalInstruction != text else { return }
        record.globalInstruction = text
        save()
    }

    // MARK: - Per-app override (FR-PA-3)

    /// The per-app override for `bundleId`, or nil when none is set. Stored verbatim.
    func instruction(forBundleId bundleId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return record.perApp[bundleId]
    }

    /// Set or remove a per-app override. Passing nil — or text that is empty/whitespace-only —
    /// removes the override entirely (so the app falls back to the global instruction).
    func setInstruction(_ text: String?, forBundleId bundleId: String) {
        guard !bundleId.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard record.perApp[bundleId] != text else { return }
            record.perApp[bundleId] = text
        } else {
            guard record.perApp[bundleId] != nil else { return }
            record.perApp.removeValue(forKey: bundleId)
        }
        save()
    }

    // MARK: - Resolution

    /// FR-PA-3 precedence: the per-app override for `bundleId` if present and non-empty, else the
    /// global instruction if non-empty, else nil. Emptiness is whitespace-trimmed so a string of
    /// spaces never produces a useless prompt block. Returns the verbatim (untrimmed) text so the
    /// user's own intentional formatting reaches the model.
    func effectiveInstruction(bundleId: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let bundleId, let override = record.perApp[bundleId], !Self.isBlank(override) {
            return override
        }
        return Self.isBlank(record.globalInstruction) ? nil : record.globalInstruction
    }

    /// All per-app overrides, for the Settings Instructions pane listing. Bundle id -> instruction.
    func allPerApp() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return record.perApp
    }

    // MARK: - Personalization seed (onboarding -> default global instruction)

    // The three voice presets the onboarding "Make it yours" step and the Settings "Reset to Default"
    // button share. Stored as the rawValue so the default can be recomposed later.
    enum Voice: String, CaseIterable {
        case friendly, concise, formal

        var label: String {
            switch self {
            case .friendly: return "Friendly & professional"
            case .concise:  return "Concise"
            case .formal:   return "Formal"
            }
        }

        var sentence: String {
            switch self {
            case .friendly: return "Write in a friendly, professional and empathetic voice. Keep your sentences short, concise and readable."
            case .concise:  return "Write concisely and directly. Keep your sentences short and easy to read."
            case .formal:   return "Write in a formal, professional voice. Keep your sentences clear and precise."
            }
        }
    }

    private enum PersonalizeKey {
        static let name      = "shadowtype.personalize.name"
        static let languages = "shadowtype.personalize.languages"
        static let voice     = "shadowtype.personalize.voice"
    }

    /// Pure (testable): compose a default global instruction from the personalization inputs. Empty
    /// name/languages are skipped, so a user who fills nothing still gets a clean voice line. Touches
    /// no UserDefaults — inputs are parameters.
    static func composeDefault(name: String, languages: String, voice: Voice?) -> String {
        var parts: [String] = []
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = languages.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { parts.append("My name is \(n).") }
        if !l.isEmpty { parts.append("I usually write in \(l).") }
        parts.append((voice ?? .friendly).sentence)
        return parts.joined(separator: " ")
    }

    /// The raw personalization inputs (verbatim) for recomposition and the onboarding field prefill.
    /// Empty strings / nil when never captured.
    func personalizationInputs() -> (name: String, languages: String, voice: Voice?) {
        let n = defaults.string(forKey: PersonalizeKey.name) ?? ""
        let l = defaults.string(forKey: PersonalizeKey.languages) ?? ""
        let v = defaults.string(forKey: PersonalizeKey.voice).flatMap(Voice.init(rawValue:))
        return (n, l, v)
    }

    /// Store the onboarding personalization inputs and seed the global instruction from them. Updates
    /// the global when it's still blank OR still equal to the default composed from the PREVIOUS
    /// inputs (i.e. an untouched auto-seed) — so live typing in the onboarding step keeps recomposing,
    /// but a global the user has hand-edited is never clobbered.
    func seedGlobalFromPersonalization(name: String, languages: String, voice: Voice?) {
        let prev = personalizationInputs()
        let prevDefault = Self.composeDefault(name: prev.name, languages: prev.languages, voice: prev.voice)
        defaults.set(name, forKey: PersonalizeKey.name)
        defaults.set(languages, forKey: PersonalizeKey.languages)
        defaults.set(voice?.rawValue, forKey: PersonalizeKey.voice)
        let current = globalInstruction()
        if Self.isBlank(current) || current == prevDefault {
            setGlobalInstruction(Self.composeDefault(name: name, languages: languages, voice: voice))
        }
    }

    /// "Reset to Default": recompose the global from the stored personalization inputs (a generic
    /// friendly voice line when they were never captured).
    func resetGlobalToDefault() {
        let (n, l, v) = personalizationInputs()
        setGlobalInstruction(Self.composeDefault(name: n, languages: l, voice: v))
    }

    // MARK: - Helpers

    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            .appendingPathComponent("instructions.json", isDirectory: false)
    }
}
