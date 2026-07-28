import XCTest
@testable import Shadowtype

@MainActor
final class AppScopeSettingsModelTests: XCTestCase {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    private func makeModel(
        rules: AppRules? = nil,
        appSettings: AppSettingsStore? = nil
    ) -> AppScopeSettingsModel {
        AppScopeSettingsModel(
            rules: rules ?? AppRules(storeURL: tempURL("rules")),
            appSettings: appSettings ?? AppSettingsStore(storeURL: tempURL("settings")),
            instructions: InstructionStore(storeURL: tempURL("instructions"))
        )
    }

    func testAddTargetTrimsAppsAndNormalizesDomains() {
        let model = makeModel()
        model.addText = "  com.example.Writer  "
        model.addTarget(isApp: true)
        XCTAssertEqual(model.addedApps, ["com.example.Writer"])
        XCTAssertEqual(
            model.selection,
            .init(kind: .app, key: "com.example.Writer")
        )
        XCTAssertEqual(model.addText, "")

        model.addText = "  Docs.Example.COM "
        model.addTarget(isApp: false)
        XCTAssertEqual(model.addedDomains, ["docs.example.com"])
        XCTAssertEqual(
            model.selection,
            .init(kind: .domain, key: "docs.example.com")
        )
    }

    func testRefreshRulesMirrorsPersistedDefaultsAndOverrides() {
        let rules = AppRules(storeURL: tempURL("rules"))
        rules.setDefaultEnabled(false)
        rules.setEnabled(true, bundleId: "com.example.Writer")
        rules.setEnabled(true, domain: "docs.example.com")
        let model = makeModel(rules: rules)

        model.refreshRules()

        XCTAssertFalse(model.defaultOn)
        XCTAssertEqual(model.enabledApps, ["com.example.Writer"])
        XCTAssertEqual(model.enabledDomains, ["docs.example.com"])
        XCTAssertTrue(model.disabledApps.isEmpty)
        XCTAssertTrue(model.disabledDomains.isEmpty)
    }

    func testCompletionBindingsWriteRulesAndRefreshState() {
        let model = makeModel()
        model.refreshRules()

        let appBinding = model.appCompletionsBinding("com.example.Writer")
        appBinding.wrappedValue = .off
        XCTAssertEqual(appBinding.wrappedValue, .off)
        XCTAssertEqual(model.disabledApps, ["com.example.Writer"])
        appBinding.wrappedValue = .auto
        XCTAssertEqual(appBinding.wrappedValue, .auto)

        let domainBinding = model.domainCompletionsBinding("docs.example.com")
        domainBinding.wrappedValue = .off
        XCTAssertEqual(domainBinding.wrappedValue, .off)
        XCTAssertEqual(model.disabledDomains, ["docs.example.com"])
    }

    func testConfigBindingSurfacesPersistenceFailureWithoutChangingStoredValue() {
        let settings = AppSettingsStore(
            storeURL: tempURL("settings"),
            atomicWrite: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let model = makeModel(appSettings: settings)
        let binding = model.configBinding(\.autocorrect, bundleId: "com.example.Writer")

        binding.wrappedValue = .on

        XCTAssertEqual(binding.wrappedValue, .auto)
        XCTAssertNotNil(model.appSettingsError)
        XCTAssertEqual(model.detailTick, 1)
    }
}
