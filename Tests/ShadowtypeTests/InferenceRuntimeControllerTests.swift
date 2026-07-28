import XCTest
@testable import Shadowtype

final class InferenceRuntimeControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "InferenceRuntimeControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    func testConfiguredSettingsUsesProductionDefaults() {
        let settings = InferenceRuntimeController.configuredSettings(defaults: defaults)

        XCTAssertEqual(
            settings,
            PowerPolicy.Settings(debounce: 0.05, maxTokens: 16, maxContextTokens: 1024))
    }

    func testConfiguredSettingsMapsLengthAndClampsDelay() {
        defaults.set(5.0, forKey: "shadowtype.triggerDelayMs")
        defaults.set(2048, forKey: "shadowtype.contextWindowTokens")
        defaults.set(CompletionLength.extraLong.rawValue, forKey: CompletionLength.defaultsKey)

        var settings = InferenceRuntimeController.configuredSettings(defaults: defaults)
        XCTAssertEqual(
            settings,
            PowerPolicy.Settings(debounce: 0.04, maxTokens: 40, maxContextTokens: 2048))

        defaults.set(900.0, forKey: "shadowtype.triggerDelayMs")
        settings = InferenceRuntimeController.configuredSettings(defaults: defaults)
        XCTAssertEqual(settings.debounce, 0.4)
    }
}
