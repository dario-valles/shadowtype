// ConfidenceGateTests — pure coverage for the suggestion-quality gates added to fight intermittent
// word-salad from the small base model: the per-token confidence accumulator, the cross-language drift
// guard, and the upgraded OCR request config. No llama/Vision runtime needed — runs under `swift test`.
import XCTest
import Vision
@testable import Shadowtype

final class ConfidenceGateTests: XCTestCase {

    // MARK: - ConfidenceGate

    func testFirstTokenRejectedWhenBelowThreshold() {
        var gate = ConfidenceGate(firstTokenMinProb: 0.10, meanMinProb: 0.08)
        gate.record(prob: 0.04, isFirst: true)
        XCTAssertTrue(gate.firstTokenRejected)
    }

    func testFirstTokenKeptWhenConfident() {
        var gate = ConfidenceGate(firstTokenMinProb: 0.10, meanMinProb: 0.08)
        gate.record(prob: 0.62, isFirst: true)
        XCTAssertFalse(gate.firstTokenRejected)
        XCTAssertFalse(gate.meanRejected)
    }

    func testNoContentTokenNeverRejects() {
        let gate = ConfidenceGate(firstTokenMinProb: 0.10, meanMinProb: 0.08)
        XCTAssertFalse(gate.firstTokenRejected)
        XCTAssertFalse(gate.meanRejected)
        XCTAssertEqual(gate.meanProb, 1.0, accuracy: 1e-9)
    }

    func testMeanProbIsGeometricMean() {
        var gate = ConfidenceGate(firstTokenMinProb: 0.0, meanMinProb: 0.0)
        gate.record(prob: 0.5, isFirst: true)
        gate.record(prob: 0.5, isFirst: false)
        XCTAssertEqual(gate.meanProb, 0.5, accuracy: 1e-6)
    }

    func testMeanRejectedWhenOneTokenNearZeroDragsItDown() {
        var gate = ConfidenceGate(firstTokenMinProb: 0.0, meanMinProb: 0.08)
        // A confident first token must not mask a near-zero later token (geometric mean punishes it).
        gate.record(prob: 0.9, isFirst: true)
        gate.record(prob: 0.0005, isFirst: false)
        XCTAssertFalse(gate.firstTokenRejected)
        XCTAssertTrue(gate.meanRejected)
    }

    func testOnlyFirstContentTokenSetsFirstProb() {
        var gate = ConfidenceGate(firstTokenMinProb: 0.10, meanMinProb: 0.0)
        gate.record(prob: 0.5, isFirst: true)
        gate.record(prob: 0.01, isFirst: true)   // a stray second isFirst must not overwrite
        XCTAssertEqual(gate.firstProb ?? -1, 0.5, accuracy: 1e-9)
    }

    // MARK: - languageDrifts

    func testLanguageDriftSpanishPrefixEnglishSuggestion() {
        let prefix = "Esa es una historia de una princesa que vive en un castillo y pasa mucho tiempo pensando"
        let suggestion = "the quick brown fox jumps over the lazy sleeping dog every single morning"
        XCTAssertTrue(CompletionCoordinator.languageDrifts(prefix: prefix, suggestion: suggestion))
    }

    func testNoDriftWhenBothSpanish() {
        let prefix = "Esa es una historia de una princesa que vive en un castillo y pasa mucho tiempo pensando"
        let suggestion = "en cómo llegar al baile antes de la medianoche"
        XCTAssertFalse(CompletionCoordinator.languageDrifts(prefix: prefix, suggestion: suggestion))
    }

    func testNoDriftOnShortPrefix() {
        // Below the min prefix length the read is unreliable, so never suppress.
        XCTAssertFalse(CompletionCoordinator.languageDrifts(prefix: "Para ", suggestion: "the lazy dog runs"))
    }

    // MARK: - OCR request config (§2)

    func testRecognizeRequestIsAccurateMultilingual() {
        let req = ScreenContextProvider.makeRecognizeTextRequest(preferredLanguages: ["es-ES", "en-US"])
        XCTAssertEqual(req.recognitionLevel, .accurate)
        XCTAssertTrue(req.usesLanguageCorrection)
        XCTAssertEqual(req.recognitionLanguages, ["es-ES", "en-US"])
    }

    func testRecognizeRequestEmptyLanguagesStillAccurate() {
        let req = ScreenContextProvider.makeRecognizeTextRequest(preferredLanguages: [])
        XCTAssertEqual(req.recognitionLevel, .accurate)
        XCTAssertTrue(req.usesLanguageCorrection)
    }
}
