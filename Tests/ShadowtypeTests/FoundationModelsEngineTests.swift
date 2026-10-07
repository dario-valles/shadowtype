// FoundationModelsEngineTests — hermetic coverage for the Apple-model rewrite path: the pure output
// cleaning + language gate (FoundationModelsOutput), the engine's availability-gated load (injected, so no
// system model is touched), and CompletionCoordinator's opt-in routing with fallback to the local engine.
import XCTest
@testable import Shadowtype

final class FoundationModelsEngineTests: XCTestCase {

    // MARK: - FoundationModelsOutput.handlesLanguage

    func testLanguageGate() {
        let supported: Set<String> = ["en", "es", "zh"]
        XCTAssertTrue(FoundationModelsOutput.handlesLanguage("es", supported: supported))
        XCTAssertTrue(FoundationModelsOutput.handlesLanguage("EN", supported: supported))
        XCTAssertTrue(FoundationModelsOutput.handlesLanguage("zh-Hans", supported: supported))   // base code
        XCTAssertFalse(FoundationModelsOutput.handlesLanguage("ca", supported: supported))       // Catalan: no
        XCTAssertTrue(FoundationModelsOutput.handlesLanguage(nil, supported: supported))         // unknown: try
        XCTAssertFalse(FoundationModelsOutput.handlesLanguage("en", supported: []))              // unavailable
    }

    // MARK: - FoundationModelsOutput.clean

    private let fewShotPrompt = """
    Rewrite the text below in a polished, formal, professional tone.

    Text: hey can u send me that doc?
    Rewritten: Could you please send me that document?

    Text (in Spanish): oye, mañana no puedo
    Rewritten (in Spanish):
    """

    func testCleanPassesPlainAnswerThrough() {
        XCTAssertEqual(FoundationModelsOutput.clean("  Mañana no podré asistir.\n", prompt: fewShotPrompt),
                       "Mañana no podré asistir.")
    }

    func testCleanStripsEchoedCueLine() {
        XCTAssertEqual(FoundationModelsOutput.clean("Rewritten (in Spanish): Mañana no podré asistir.",
                                                    prompt: fewShotPrompt),
                       "Mañana no podré asistir.")
    }

    func testCleanStripsWholePromptEcho() {
        XCTAssertEqual(FoundationModelsOutput.clean(fewShotPrompt + " Mañana no podré asistir.", prompt: fewShotPrompt),
                       "Mañana no podré asistir.")
    }

    func testCleanStripsAssistantPreamble() {
        XCTAssertEqual(FoundationModelsOutput.clean("Sure, here's the rewritten text:\nMañana no podré asistir.",
                                                    prompt: fewShotPrompt),
                       "Mañana no podré asistir.")
        XCTAssertEqual(FoundationModelsOutput.clean("Claro, aquí tienes el texto:\n\nMañana no podré asistir.",
                                                    prompt: fewShotPrompt),
                       "Mañana no podré asistir.")
        // A first line that merely ends in ":" is content, not a preamble.
        XCTAssertEqual(FoundationModelsOutput.clean("Agenda:\n1. Budget", prompt: "x"), "Agenda:\n1. Budget")
    }

    func testCleanUnwrapsOnePairOfQuotes() {
        XCTAssertEqual(FoundationModelsOutput.clean("«la reunión sigue en pie»", prompt: "x"), "la reunión sigue en pie")
        XCTAssertEqual(FoundationModelsOutput.clean("\u{201C}Thank you.\u{201D}", prompt: "x"), "Thank you.")
        XCTAssertEqual(FoundationModelsOutput.clean("\"Thank you.\"", prompt: "x"), "Thank you.")
        // Two separate quotations are not one wrapped answer.
        XCTAssertEqual(FoundationModelsOutput.clean("\"Yes\" and \"no\"", prompt: "x"), "\"Yes\" and \"no\"")
    }

    func testCleanDropsRepeatedParagraph() {
        let answer = "No puedo asistir mañana, ¿podemos pasarlo al viernes?"
        XCTAssertEqual(FoundationModelsOutput.clean(answer + "\n\n" + answer, prompt: "x"), answer)
        // A repeat cut off by the token cap is dropped too.
        XCTAssertEqual(FoundationModelsOutput.clean(answer + "\n\n" + String(answer.prefix(30)), prompt: "x"), answer)
        // Distinct paragraphs are real structure and stay.
        XCTAssertEqual(FoundationModelsOutput.clean("Hi Ana,\n\nThe report is attached.", prompt: "x"),
                       "Hi Ana,\n\nThe report is attached.")
    }

    // MARK: - FoundationModelsEngine (availability injected — never touches the system model)

    func testEngineRefusesToLoadWhenSystemModelUnavailable() {
        let fm = FoundationModelsEngine(isSystemModelAvailable: { false })
        XCTAssertThrowsError(try fm.load(modelPath: ""))
        XCTAssertFalse(fm.isLoaded)
        XCTAssertThrowsError(try fm.generate(prompt: "x", maxTokens: 4, onToken: { _ in true })) { error in
            guard case InferenceError.notLoaded = error else { return XCTFail("expected notLoaded, got \(error)") }
        }
    }

    func testEngineLoadsWhenAvailableAndAdvertisesNoChatOrFIM() throws {
        let fm = FoundationModelsEngine(isSystemModelAvailable: { true })
        try fm.load(modelPath: "/ignored")
        XCTAssertTrue(fm.isLoaded)
        XCTAssertFalse(fm.modelSupportsChat)
        XCTAssertFalse(fm.supportsFIM)
        XCTAssertNil(fm.modelChatTemplate)
        XCTAssertEqual(fm.contextWindowTokens, 4096)
        fm.unload()
        XCTAssertFalse(fm.isLoaded)
    }

    // MARK: - CompletionCoordinator opt-in routing

    private final class ScriptedEngine: InferenceEngineProtocol {
        var isLoaded: Bool
        var stopAtFirstSentence = false
        var maxWords = 0
        var stopAtSentenceAfterWords = 0
        var maxContextTokens = 0
        var modelChatTemplate: String? = nil
        var modelArchitecture: String? = nil
        var modelSupportsChat = false
        var supportsFIM = false
        let output: String
        let failure: Error?
        private(set) var calls = 0
        init(loaded: Bool = true, output: String = "", failure: Error? = nil) {
            isLoaded = loaded; self.output = output; self.failure = failure
        }
        func load(modelPath: String) throws { isLoaded = true }
        func unload() { isLoaded = false }
        func requestCancel() {}
        func releaseSeq(_ seqID: Int32) {}
        func generate(prompt: String, maxTokens: Int, seqID: Int32, params: SamplingParams,
                      requiredPrefix: [UInt8]?, onToken: (String) -> Bool,
                      onSample: ((Float, Bool) -> Void)?) throws {
            calls += 1
            if let failure { throw failure }
            if !output.isEmpty { _ = onToken(output) }
        }
    }

    private func rewrite(_ selection: String, llama: ScriptedEngine, apple: ScriptedEngine?,
                         languages: Set<String> = ["en", "es"]) -> String? {
        let c = CompletionCoordinator(engine: llama, overlay: OverlayRenderer(), context: EditContextTracker())
        c.appleRewriteEngine = apple
        c.appleRewriteLanguages = languages
        let done = expectation(description: "rewrite completion")
        var result: String?
        c.rewrite(selection: selection, action: .formal) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }

    private let english = "hey can you send me the report when you get a chance, thanks a lot"
    private let catalan = "Ei, demà no puc venir a la reunió, ho podem passar a divendres? Gràcies per avisar-me."

    func testOptInRewriteUsesAppleModelForSupportedLanguage() {
        let llama = ScriptedEngine(output: "local result")
        let apple = ScriptedEngine(output: "Could you please send me the report? Thank you.")
        XCTAssertEqual(rewrite(english, llama: llama, apple: apple), "Could you please send me the report? Thank you.")
        XCTAssertEqual(apple.calls, 1)
        XCTAssertEqual(llama.calls, 0)
    }

    func testOptInRewriteFallsBackToLocalModelOnError() {
        let llama = ScriptedEngine(output: "local result")
        let apple = ScriptedEngine(failure: InferenceError.modelLoadFailed("guardrail"))
        XCTAssertEqual(rewrite(english, llama: llama, apple: apple), "local result")
        XCTAssertEqual(apple.calls, 1)
        XCTAssertEqual(llama.calls, 1)
    }

    func testOptInRewriteFallsBackOnEmptyAnswer() {
        let llama = ScriptedEngine(output: "local result")
        let apple = ScriptedEngine(output: "")
        XCTAssertEqual(rewrite(english, llama: llama, apple: apple), "local result")
        XCTAssertEqual(llama.calls, 1)
    }

    func testOptInRewriteSkipsAppleModelForUnsupportedLanguage() {
        let llama = ScriptedEngine(output: "local result")
        let apple = ScriptedEngine(output: "apple result")
        XCTAssertEqual(rewrite(catalan, llama: llama, apple: apple), "local result")
        XCTAssertEqual(apple.calls, 0)
        XCTAssertEqual(llama.calls, 1)
    }

    func testAppleModelAloneMakesRewriteReady() {
        let llama = ScriptedEngine(loaded: false)
        let apple = ScriptedEngine(output: "Could you please send me the report?")
        let c = CompletionCoordinator(engine: llama, overlay: OverlayRenderer(), context: EditContextTracker())
        XCTAssertFalse(c.isRewriteReady)
        c.appleRewriteEngine = apple
        XCTAssertTrue(c.isRewriteReady)
        XCTAssertEqual(rewrite(english, llama: llama, apple: apple), "Could you please send me the report?")
        XCTAssertEqual(llama.calls, 0)
    }

    func testRewriteWithoutOptInIsUnchanged() {
        let llama = ScriptedEngine(output: "local result")
        XCTAssertEqual(rewrite(english, llama: llama, apple: nil), "local result")
        XCTAssertEqual(llama.calls, 1)
    }
}
