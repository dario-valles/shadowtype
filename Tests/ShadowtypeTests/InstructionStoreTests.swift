// InstructionStore — global + per-app AI instructions (FR-PA-3, paid).
// Pure logic + on-disk persistence; hermetic via the injectable storeURL init (like AppRules).
import XCTest
@testable import Shadowtype

final class InstructionStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-instructions-\(UUID().uuidString).json")
    }

    // MARK: - Defaults

    func testDefaultsEmpty() {
        let store = InstructionStore(storeURL: tempURL())
        XCTAssertEqual(store.globalInstruction(), "")
        XCTAssertNil(store.instruction(forBundleId: "com.apple.Mail"))
        XCTAssertNil(store.effectiveInstruction(bundleId: nil))
        XCTAssertNil(store.effectiveInstruction(bundleId: "com.apple.Mail"))
        XCTAssertTrue(store.allPerApp().isEmpty)
    }

    // MARK: - Global set/get + persistence

    func testGlobalSetGet() {
        let store = InstructionStore(storeURL: tempURL())
        store.setGlobalInstruction("Be concise. No emojis.")
        XCTAssertEqual(store.globalInstruction(), "Be concise. No emojis.")
    }

    func testGlobalPersistsAcrossInstances() {
        let url = tempURL()
        do {
            let store = InstructionStore(storeURL: url)
            store.setGlobalInstruction("Write formally.")
        }
        let reloaded = InstructionStore(storeURL: url)
        XCTAssertEqual(reloaded.globalInstruction(), "Write formally.")
    }

    // MARK: - Per-app set/get/remove

    func testPerAppSetGet() {
        let store = InstructionStore(storeURL: tempURL())
        store.setInstruction("Keep it casual.", forBundleId: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(store.instruction(forBundleId: "com.tinyspeck.slackmacgap"),
                       "Keep it casual.")
        XCTAssertNil(store.instruction(forBundleId: "com.apple.Mail"))
    }

    func testPerAppRemoveWithNil() {
        let store = InstructionStore(storeURL: tempURL())
        store.setInstruction("Casual.", forBundleId: "com.slack")
        store.setInstruction(nil, forBundleId: "com.slack")
        XCTAssertNil(store.instruction(forBundleId: "com.slack"))
        XCTAssertTrue(store.allPerApp().isEmpty)
    }

    func testPerAppRemoveWithEmptyOrWhitespace() {
        let store = InstructionStore(storeURL: tempURL())
        store.setInstruction("Casual.", forBundleId: "com.slack")
        store.setInstruction("   \n  ", forBundleId: "com.slack")
        XCTAssertNil(store.instruction(forBundleId: "com.slack"))
        XCTAssertTrue(store.allPerApp().isEmpty)
    }

    func testPerAppEmptyBundleIdIgnored() {
        let store = InstructionStore(storeURL: tempURL())
        store.setInstruction("anything", forBundleId: "")
        XCTAssertTrue(store.allPerApp().isEmpty)
    }

    func testPerAppPersistsAcrossInstances() {
        let url = tempURL()
        do {
            let store = InstructionStore(storeURL: url)
            store.setInstruction("Casual.", forBundleId: "com.slack")
            store.setGlobalInstruction("Formal.")
        }
        let reloaded = InstructionStore(storeURL: url)
        XCTAssertEqual(reloaded.instruction(forBundleId: "com.slack"), "Casual.")
        XCTAssertEqual(reloaded.globalInstruction(), "Formal.")
    }

    // MARK: - effectiveInstruction precedence (FR-PA-3)

    func testEffectivePerAppBeatsGlobal() {
        let store = InstructionStore(storeURL: tempURL())
        store.setGlobalInstruction("Be formal.")
        store.setInstruction("Be casual.", forBundleId: "com.slack")
        XCTAssertEqual(store.effectiveInstruction(bundleId: "com.slack"), "Be casual.")
    }

    func testEffectiveFallsBackToGlobal() {
        let store = InstructionStore(storeURL: tempURL())
        store.setGlobalInstruction("Be formal.")
        // No override for Mail -> global applies.
        XCTAssertEqual(store.effectiveInstruction(bundleId: "com.apple.Mail"), "Be formal.")
        // Nil bundle -> global applies.
        XCTAssertEqual(store.effectiveInstruction(bundleId: nil), "Be formal.")
    }

    func testEffectiveNilWhenBothEmpty() {
        let store = InstructionStore(storeURL: tempURL())
        XCTAssertNil(store.effectiveInstruction(bundleId: "com.slack"))
        store.setGlobalInstruction("   ") // whitespace-only is treated as empty
        XCTAssertNil(store.effectiveInstruction(bundleId: "com.slack"))
    }

    func testEffectiveWhitespaceGlobalIsNil() {
        let store = InstructionStore(storeURL: tempURL())
        store.setGlobalInstruction("\n\t  ")
        XCTAssertNil(store.effectiveInstruction(bundleId: nil))
    }

    // MARK: - Personalization seed + default composition

    private func tempDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "gw-test-\(UUID().uuidString)")!
        return d
    }

    func testComposeDefaultAllFields() {
        let s = InstructionStore.composeDefault(
            name: "Jane Appleseed", languages: "English, Spanish and Catalan", voice: .friendly)
        XCTAssertEqual(s,
            "My name is Jane Appleseed. I usually write in English, Spanish and Catalan. " +
            "Write in a friendly, professional and empathetic voice. Keep your sentences short, concise and readable.")
    }

    func testComposeDefaultSkipsEmptyAndDefaultsVoice() {
        // Empty name/languages drop out; nil voice falls back to friendly.
        let s = InstructionStore.composeDefault(name: "  ", languages: "", voice: nil)
        XCTAssertEqual(s, InstructionStore.Voice.friendly.sentence)
    }

    func testSeedComposesGlobalWhenBlank() {
        let store = InstructionStore(storeURL: tempURL(), defaults: tempDefaults())
        store.seedGlobalFromPersonalization(name: "Ada", languages: "English", voice: .concise)
        XCTAssertEqual(store.globalInstruction(),
            InstructionStore.composeDefault(name: "Ada", languages: "English", voice: .concise))
        let p = store.personalizationInputs()
        XCTAssertEqual(p.name, "Ada"); XCTAssertEqual(p.languages, "English"); XCTAssertEqual(p.voice, .concise)
    }

    func testSeedLiveRecomposesUntouchedDefault() {
        // Successive seeds (live typing) keep recomposing while the global is still the auto-seed.
        let store = InstructionStore(storeURL: tempURL(), defaults: tempDefaults())
        store.seedGlobalFromPersonalization(name: "A", languages: "", voice: .friendly)
        store.seedGlobalFromPersonalization(name: "Ada Lovelace", languages: "English", voice: .formal)
        XCTAssertEqual(store.globalInstruction(),
            InstructionStore.composeDefault(name: "Ada Lovelace", languages: "English", voice: .formal))
    }

    func testSeedDoesNotClobberUserEditedGlobal() {
        let store = InstructionStore(storeURL: tempURL(), defaults: tempDefaults())
        store.setGlobalInstruction("My own hand-written instruction.")
        store.seedGlobalFromPersonalization(name: "Ada", languages: "English", voice: .friendly)
        XCTAssertEqual(store.globalInstruction(), "My own hand-written instruction.")
        // Inputs are still recorded so Reset to Default can use them later.
        XCTAssertEqual(store.personalizationInputs().name, "Ada")
    }

    func testResetGlobalToDefaultRecomposesFromStoredInputs() {
        let store = InstructionStore(storeURL: tempURL(), defaults: tempDefaults())
        store.seedGlobalFromPersonalization(name: "Ada", languages: "English", voice: .friendly)
        store.setGlobalInstruction("scratch edit")
        store.resetGlobalToDefault()
        XCTAssertEqual(store.globalInstruction(),
            InstructionStore.composeDefault(name: "Ada", languages: "English", voice: .friendly))
    }

    // MARK: - allPerApp listing

    func testAllPerAppListing() {
        let store = InstructionStore(storeURL: tempURL())
        store.setInstruction("Casual.", forBundleId: "com.slack")
        store.setInstruction("Formal.", forBundleId: "com.apple.Mail")
        let all = store.allPerApp()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all["com.slack"], "Casual.")
        XCTAssertEqual(all["com.apple.Mail"], "Formal.")
    }
}
