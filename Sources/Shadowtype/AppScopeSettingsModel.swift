import SwiftUI

@MainActor
final class AppScopeSettingsModel: ObservableObject {
    enum Kind: Hashable {
        case app
        case domain
    }

    struct TargetRef: Hashable {
        let kind: Kind
        let key: String
    }

    @Published var defaultOn = true
    @Published private(set) var disabledApps: Set<String> = []
    @Published private(set) var disabledDomains: Set<String> = []
    @Published private(set) var enabledApps: Set<String> = []
    @Published private(set) var enabledDomains: Set<String> = []
    @Published var selection: TargetRef?
    @Published private(set) var addedApps: Set<String> = []
    @Published private(set) var addedDomains: Set<String> = []
    @Published var addText = ""
    @Published private(set) var detailTick = 0
    @Published private(set) var appSettingsError: String?

    private let rules: AppRules
    private let appSettings: AppSettingsStore
    private let instructions: InstructionStore

    init(
        rules: AppRules = .shared,
        appSettings: AppSettingsStore = .shared,
        instructions: InstructionStore = .shared
    ) {
        self.rules = rules
        self.appSettings = appSettings
        self.instructions = instructions
    }

    func addTarget(isApp: Bool) {
        let value = addText.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        if isApp {
            addedApps.insert(value)
            selection = TargetRef(kind: .app, key: value)
        } else {
            let domain = value.lowercased()
            addedDomains.insert(domain)
            selection = TargetRef(kind: .domain, key: domain)
        }
        addText = ""
    }

    func setDefaultEnabled(_ enabled: Bool) {
        rules.setDefaultEnabled(enabled)
        refreshRules()
    }

    func appCompletionsBinding(_ key: String) -> Binding<TriState> {
        Binding(
            get: {
                if self.disabledApps.contains(key) { return .off }
                if self.enabledApps.contains(key) { return .on }
                return .auto
            },
            set: { state in
                switch state {
                case .on:
                    self.rules.setEnabled(true, bundleId: key)
                case .off:
                    self.rules.setEnabled(false, bundleId: key)
                case .auto:
                    self.rules.setEnabled(
                        self.rules.defaultEnabled(forBundleId: key),
                        bundleId: key
                    )
                }
                self.refreshRules()
            }
        )
    }

    func domainCompletionsBinding(_ key: String) -> Binding<TriState> {
        Binding(
            get: {
                if self.disabledDomains.contains(key) { return .off }
                if self.enabledDomains.contains(key) { return .on }
                return .auto
            },
            set: { state in
                switch state {
                case .on:
                    self.rules.setEnabled(true, domain: key)
                case .off:
                    self.rules.setEnabled(false, domain: key)
                case .auto:
                    self.rules.setEnabled(self.rules.defaultEnabled(), domain: key)
                }
                self.refreshRules()
            }
        )
    }

    func configBinding(
        _ field: WritableKeyPath<AppConfig, TriState>,
        bundleId: String
    ) -> Binding<TriState> {
        Binding(
            get: {
                _ = self.detailTick
                return self.appSettings.config(forBundleId: bundleId)[keyPath: field]
            },
            set: { state in
                let saved = self.appSettings.set(state, field, forBundleId: bundleId)
                self.appSettingsError = saved
                    ? nil
                    : "Couldn’t save this app override. Check that Shadowtype can write to Application Support, then try again."
                self.detailTick += 1
            }
        )
    }

    func instructionBinding(_ bundleId: String) -> Binding<String> {
        Binding(
            get: { self.instructions.instruction(forBundleId: bundleId) ?? "" },
            set: {
                self.instructions.setInstruction(
                    $0.isEmpty ? nil : $0,
                    forBundleId: bundleId
                )
            }
        )
    }

    func refreshDetail() {
        detailTick += 1
    }

    func refreshRules() {
        defaultOn = rules.defaultEnabled()
        disabledApps = Set(rules.disabledBundleIds())
        disabledDomains = Set(rules.disabledDomains())
        enabledApps = Set(rules.enabledBundleIds())
        enabledDomains = Set(rules.enabledDomains())
    }
}
