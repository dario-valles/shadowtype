// AppSettingsStore — per-app behavior tri-states (mid-line, autocorrect, Disable Tab, collect-inputs).
// Pure resolution + on-disk persistence; hermetic via the injectable storeURL init (like AppRules).
import XCTest
@testable import Shadowtype

final class AppSettingsStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-appsettings-\(UUID().uuidString).json")
    }

    // MARK: - Tri-state resolution (the one place three-state collapses to a Bool)

    func testResolvePure() {
        XCTAssertTrue(TriState.resolve(.on, globalDefault: false))
        XCTAssertFalse(TriState.resolve(.off, globalDefault: true))
        XCTAssertTrue(TriState.resolve(.auto, globalDefault: true))
        XCTAssertFalse(TriState.resolve(.auto, globalDefault: false))
    }

    func testDefaultConfigIsAllAuto() {
        let store = AppSettingsStore(storeURL: tempURL())
        let cfg = store.config(forBundleId: "com.apple.mail")
        XCTAssertEqual(cfg, AppConfig())
        XCTAssertTrue(cfg.isDefault)
        // Resolve falls through to the global default when unset.
        XCTAssertTrue(store.resolve(\.midLine, forBundleId: "com.apple.mail", globalDefault: true))
        XCTAssertFalse(store.resolve(\.autocorrect, forBundleId: "com.apple.mail", globalDefault: false))
    }

    func testNilBundleResolvesToGlobalDefault() {
        let store = AppSettingsStore(storeURL: tempURL())
        XCTAssertTrue(store.resolve(\.disableTab, forBundleId: nil, globalDefault: true))
        XCTAssertFalse(store.resolve(\.disableTab, forBundleId: nil, globalDefault: false))
    }

    // MARK: - Set / override / prune

    func testSetOverridesGlobal() {
        let store = AppSettingsStore(storeURL: tempURL())
        store.set(.off, \.midLine, forBundleId: "com.apple.mail")
        XCTAssertFalse(store.resolve(\.midLine, forBundleId: "com.apple.mail", globalDefault: true))
        store.set(.on, \.autocorrect, forBundleId: "com.apple.mail")
        XCTAssertTrue(store.resolve(\.autocorrect, forBundleId: "com.apple.mail", globalDefault: false))
        XCTAssertEqual(store.configuredBundleIds(), ["com.apple.mail"])
    }

    func testSettingBackToAutoPrunesEmptyEntry() {
        let store = AppSettingsStore(storeURL: tempURL())
        store.set(.off, \.midLine, forBundleId: "com.apple.mail")
        XCTAssertEqual(store.configuredBundleIds(), ["com.apple.mail"])
        // Returning the only override to .auto leaves an all-auto config — pruned so the app list
        // doesn't accumulate no-op rows.
        store.set(.auto, \.midLine, forBundleId: "com.apple.mail")
        XCTAssertTrue(store.configuredBundleIds().isEmpty)
    }

    func testClearRemovesApp() {
        let store = AppSettingsStore(storeURL: tempURL())
        store.set(.on, \.collectInputs, forBundleId: "com.apple.mail")
        store.clear(bundleId: "com.apple.mail")
        XCTAssertTrue(store.configuredBundleIds().isEmpty)
        XCTAssertEqual(store.config(forBundleId: "com.apple.mail"), AppConfig())
    }

    // MARK: - Persistence + tolerant decode

    func testPersistsAcrossReload() {
        let url = tempURL()
        do {
            let store = AppSettingsStore(storeURL: url)
            store.set(.off, \.disableTab, forBundleId: "com.apple.dt.Xcode")
            store.set(.on, \.collectInputs, forBundleId: "com.apple.mail")
        }
        let reloaded = AppSettingsStore(storeURL: url)
        XCTAssertEqual(reloaded.config(forBundleId: "com.apple.dt.Xcode").disableTab, .off)
        XCTAssertEqual(reloaded.config(forBundleId: "com.apple.mail").collectInputs, .on)
    }

    func testTolerantDecodeOfMissingFields() throws {
        let url = tempURL()
        // A file written by an older build with only one field present.
        let legacy = #"{"com.apple.mail":{"autocorrect":"off"}}"#
        try legacy.data(using: .utf8)!.write(to: url)
        let store = AppSettingsStore(storeURL: url)
        let cfg = store.config(forBundleId: "com.apple.mail")
        XCTAssertEqual(cfg.autocorrect, .off)
        XCTAssertEqual(cfg.midLine, .auto)        // absent → inert default
        XCTAssertEqual(cfg.collectInputs, .auto)
        XCTAssertEqual(cfg.rightArrowAccept, .auto)
    }

    func testRightArrowAcceptOverride() {
        let store = AppSettingsStore(storeURL: tempURL())
        // Default ON globally → resolved on for unset apps.
        XCTAssertTrue(store.resolve(\.rightArrowAccept, forBundleId: "com.apple.mail", globalDefault: true))
        store.set(.off, \.rightArrowAccept, forBundleId: "com.apple.mail")
        XCTAssertFalse(store.resolve(\.rightArrowAccept, forBundleId: "com.apple.mail", globalDefault: true))
    }

    func testMissingFileLoadsEmpty() {
        let store = AppSettingsStore(storeURL: tempURL())
        XCTAssertTrue(store.configuredBundleIds().isEmpty)
    }

    func testShellCommandsRoundTripAndDefault() {
        let url = tempURL()
        let store = AppSettingsStore(storeURL: url)
        // Default OFF when unset (globalDefault false).
        XCTAssertFalse(store.resolve(\.shellCommands, forBundleId: "com.googlecode.iterm2", globalDefault: false))
        store.set(.on, \.shellCommands, forBundleId: "com.googlecode.iterm2")
        XCTAssertTrue(store.resolve(\.shellCommands, forBundleId: "com.googlecode.iterm2", globalDefault: false))
        // Persists + reloads.
        let reloaded = AppSettingsStore(storeURL: url)
        XCTAssertEqual(reloaded.config(forBundleId: "com.googlecode.iterm2").shellCommands, .on)
    }

    func testShellCommandsTolerantDecodeAndPruning() {
        let url = tempURL()
        // Older file with no shellCommands key.
        try? #"{"com.apple.Terminal":{"midLine":"on"}}"#.data(using: .utf8)!.write(to: url)
        let store = AppSettingsStore(storeURL: url)
        XCTAssertEqual(store.config(forBundleId: "com.apple.Terminal").shellCommands, .auto)
        // Setting back to .auto everywhere prunes the entry (isDefault).
        store.set(.auto, \.midLine, forBundleId: "com.apple.Terminal")
        XCTAssertFalse(store.configuredBundleIds().contains("com.apple.Terminal"))
    }
}
