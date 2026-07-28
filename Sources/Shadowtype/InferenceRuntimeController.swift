import Foundation

struct PowerPolicy {
    struct Settings: Equatable {
        var debounce: TimeInterval
        var maxTokens: Int
        var maxContextTokens: Int
    }

    enum Tier {
        case nominal
        case moderate
        case heavy
    }

    static func tier(thermalState: ProcessInfo.ThermalState, lowPower: Bool) -> Tier {
        switch thermalState {
        case .critical: return .heavy
        case .serious: return .moderate
        default: return lowPower ? .moderate : .nominal
        }
    }

    static func adjust(
        _ base: Settings,
        thermalState: ProcessInfo.ThermalState,
        lowPower: Bool
    ) -> Settings {
        switch tier(thermalState: thermalState, lowPower: lowPower) {
        case .nominal:
            return base
        case .moderate:
            return lighter(
                base,
                debounceScale: 2,
                debounceCap: 0.6,
                maxTokens: 12,
                contextTokens: 1024)
        case .heavy:
            return lighter(
                base,
                debounceScale: 3,
                debounceCap: 1.0,
                maxTokens: 8,
                contextTokens: 512)
        }
    }

    private static func lighter(
        _ base: Settings,
        debounceScale: Double,
        debounceCap: TimeInterval,
        maxTokens: Int,
        contextTokens: Int
    ) -> Settings {
        Settings(
            debounce: max(base.debounce, min(debounceCap, base.debounce * debounceScale)),
            maxTokens: min(base.maxTokens, maxTokens),
            maxContextTokens: min(base.maxContextTokens, contextTokens))
    }
}

final class InferenceRuntimeController {
    private let engine: InferenceEngine
    private let coordinator: CompletionCoordinator
    private let modelManager: ModelManager
    private let statusItem: StatusItemController
    private let defaults: UserDefaults

    private var currentModelURL: URL?
    private var idleUnloadMinutes = 0
    private var lastInputAt = Date()
    private var idleTimer: Timer?
    private var modelIdleUnloaded = false
    private var modelReloadInFlight = false

    init(
        engine: InferenceEngine,
        coordinator: CompletionCoordinator,
        modelManager: ModelManager,
        statusItem: StatusItemController,
        defaults: UserDefaults = .standard
    ) {
        self.engine = engine
        self.coordinator = coordinator
        self.modelManager = modelManager
        self.statusItem = statusItem
        self.defaults = defaults
    }

    func configureCompletion() {
        engine.stopAtFirstSentence = false
        applyCompletionLength()
    }

    func setCurrentModelURL(_ url: URL) {
        currentModelURL = url
    }

    func startIdleTimer() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.unloadModelIfIdle()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    func syncIdleUnloadSetting() {
        idleUnloadMinutes =
            (defaults.object(forKey: "shadowtype.unloadIdleMinutes") as? Int) ?? 10
    }

    func applyCompletionLength() {
        let length = CompletionLength.current(defaults: defaults)
        engine.maxWords = length.maxWords
        applyPowerPolicy()
        engine.stopAtSentenceAfterWords = length.sentenceStopAfterWords
    }

    static func configuredSettings(defaults: UserDefaults = .standard) -> PowerPolicy.Settings {
        let delayMs = defaults.object(forKey: "shadowtype.triggerDelayMs") as? Double ?? 50
        let contextTokens =
            (defaults.object(forKey: "shadowtype.contextWindowTokens") as? Int) ?? 1024
        return PowerPolicy.Settings(
            debounce: max(0.04, min(0.4, delayMs / 1000)),
            maxTokens: CompletionLength.current(defaults: defaults).maxTokens,
            maxContextTokens: contextTokens)
    }

    func applyPowerPolicy() {
        let info = ProcessInfo.processInfo
        let applied = PowerPolicy.adjust(
            Self.configuredSettings(defaults: defaults),
            thermalState: info.thermalState,
            lowPower: info.isLowPowerModeEnabled)
        coordinator.debounce = applied.debounce
        coordinator.maxTokens = applied.maxTokens
        engine.maxContextTokens = applied.maxContextTokens
        coordinator.promptCharBudget =
            CompletionCoordinator.promptBudgetBytes(forContextTokens: applied.maxContextTokens)
    }

    func swapModel(to entry: ModelCatalogEntry) {
        modelReloadInFlight = true
        modelManager.onDownloadProgress = { fraction in
            DispatchQueue.main.async {
                var info: [String: Any] = ["id": entry.id]
                if let fraction {
                    info["fraction"] = fraction
                }
                NotificationCenter.default.post(
                    name: Notification.Name("shadowtypeModelDownloadProgress"),
                    object: nil,
                    userInfo: info)
            }
        }
        Task {
            defer { self.modelManager.onDownloadProgress = nil }
            do {
                let url = try await modelManager.ensureModel(entry)
                let fallback = self.currentModelURL?.path
                await MainActor.run {
                    self.coordinator.reloadModel(
                        at: url.path,
                        fallbackPath: fallback
                    ) { [weak self] ok, loadError in
                        guard let self else { return }
                        self.modelReloadInFlight = false
                        if ok {
                            self.modelIdleUnloaded = false
                            self.currentModelURL = url
                            self.statusItem.setModelName(
                                url.deletingPathExtension().lastPathComponent)
                            self.defaults.set(
                                entry.id,
                                forKey: ModelManager.selectedModelDefaultsKey)
                        } else {
                            NSLog(
                                "Shadowtype: model swap to \(entry.id) did not load; keeping previous model")
                        }
                        var info: [String: Any] = ["id": entry.id, "ok": ok]
                        if let loadError {
                            info["error"] = loadError
                        }
                        NotificationCenter.default.post(
                            name: .shadowtypeModelDidChange,
                            object: nil,
                            userInfo: info)
                        NotificationCenter.default.post(
                            name: .shadowtypeEngineLoadStateChanged,
                            object: nil,
                            userInfo: ["loaded": self.coordinator.isModelLoaded])
                    }
                }
            } catch {
                NSLog("Shadowtype: model swap to \(entry.id) failed: \(error)")
                let message =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self.modelReloadInFlight = false
                    NotificationCenter.default.post(
                        name: .shadowtypeModelDidChange,
                        object: nil,
                        userInfo: ["id": entry.id, "ok": false, "error": message])
                }
            }
        }
    }

    func noteActivityAndReloadIfNeeded() {
        lastInputAt = Date()
        guard modelIdleUnloaded,
              !modelReloadInFlight,
              let url = currentModelURL else { return }
        modelIdleUnloaded = false
        modelReloadInFlight = true
        coordinator.reloadModel(at: url.path, fallbackPath: nil) { [weak self] ok, _ in
            guard let self else { return }
            self.modelReloadInFlight = false
            if ok {
                self.statusItem.setModelName(url.deletingPathExtension().lastPathComponent)
            } else {
                NSLog(
                    "Shadowtype: idle reload of \(url.lastPathComponent) failed; model stays unloaded until the next model swap or relaunch")
            }
        }
    }

    private func unloadModelIfIdle() {
        guard idleUnloadMinutes > 0,
              !modelIdleUnloaded,
              !modelReloadInFlight,
              !coordinator.hasInFlightAPIRequests,
              coordinator.isModelLoaded else { return }
        guard Date().timeIntervalSince(lastInputAt) >= Double(idleUnloadMinutes) * 60 else {
            return
        }
        coordinator.unloadModel()
        modelIdleUnloaded = true
        statusItem.setModelName("idle — wakes on your next keystroke")
        Diag.log("idle: unloaded model after \(idleUnloadMinutes) min")
    }

    func shutdown() {
        idleTimer?.invalidate()
        idleTimer = nil
    }
}
