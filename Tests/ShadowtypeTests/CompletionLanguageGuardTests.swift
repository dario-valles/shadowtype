import NaturalLanguage
import XCTest
@testable import Shadowtype

final class CompletionLanguageGuardTests: XCTestCase {
    func testHealedGenerationStillSuppressesWrongLanguage() {
        let prefixReason = CompletionCoordinator.languageRejectionReason(
            checkPrefixDup: true,
            generationIsHealed: true,
            prefixLanguage: .catalan,
            suggestion: "I know that my team can finish the project tomorrow morning",
            contextLang: .catalan
        )
        let contextReason = CompletionCoordinator.languageRejectionReason(
            checkPrefixDup: true,
            generationIsHealed: true,
            prefixLanguage: nil,
            suggestion: "I know that my team can finish the project tomorrow morning",
            contextLang: .catalan
        )
        let staleRemainderReason = CompletionCoordinator.languageRejectionReason(
            checkPrefixDup: false,
            generationIsHealed: true,
            prefixLanguage: .catalan,
            suggestion: "I know that my team can finish the project tomorrow morning",
            contextLang: .catalan
        )

        XCTAssertEqual(prefixReason, "lang-drift")
        XCTAssertEqual(contextReason, "context-lang conflict")
        XCTAssertNil(staleRemainderReason)
    }

    func testPersonalizedLanguagesParseSloppyNamesAndISOCodes() {
        let named = CompletionCoordinator.parsePersonalizedLanguages(
            "English, Spanish, catalan")
        let coded = CompletionCoordinator.parsePersonalizedLanguages("ca, es")

        XCTAssertEqual(Set(named), Set([.english, .spanish, .catalan]))
        XCTAssertEqual(coded, [.catalan, .spanish])
    }

    func testEmptyAndGarbagePersonalizedLanguagesPreserveUnconstrainedDetection() {
        XCTAssertTrue(CompletionCoordinator.parsePersonalizedLanguages("").isEmpty)
        XCTAssertTrue(CompletionCoordinator.parsePersonalizedLanguages("asdf, ???").isEmpty)

        let clearEnglish = "This is a clearly written English sentence about the project schedule."
        XCTAssertEqual(
            CompletionCoordinator.dominantLanguage(clearEnglish, minConfidence: 0.50),
            CompletionCoordinator.dominantLanguage(
                clearEnglish, minConfidence: 0.50, languageConstraints: [])
        )
        XCTAssertEqual(
            CompletionCoordinator.dominantLanguage(clearEnglish, minConfidence: 0.50),
            .english
        )
    }

    func testDeclaredLanguagesConstrainCatalanDetection() {
        let text = "Aquesta conversa parla de la feina i de tot el que hem de preparar demà."

        XCTAssertEqual(
            CompletionCoordinator.dominantLanguage(
                text, minConfidence: 0.50,
                languageConstraints: [.english, .spanish, .catalan]
            ),
            .catalan
        )
    }

    // The declared list must not become a filter. Constraining the recognizer up front scores this
    // German sentence en:0.71 (vs de:1.00 unconstrained) — confident enough to clear both the 0.70
    // floor and the 0.10 margin, which would steer a German thread into English and suppress a correct
    // German ghost. Threads here really do carry undeclared languages: the report that prompted this
    // work had a German guest message on screen.
    func testUndeclaredLanguageStillDetectedDespiteDeclaredList() {
        let german = "Ich komme eigentlich erst um 1 Uhr in Malaga an, die Uhrzeit kann man nicht aussuchen"
        XCTAssertEqual(
            CompletionCoordinator.dominantLanguage(
                german, minConfidence: 0.70,
                languageConstraints: [.english, .spanish, .catalan]
            ),
            .german
        )
    }

    // The flip side: where the OPEN read is too ambiguous to clear the bar, the declared languages are
    // allowed to break the tie. This short Catalan line reads ca:0.76/it:0.19 unconstrained — under the
    // 0.80 the drift guard uses — and ca:0.94 once narrowed to what the user says they write in.
    func testDeclaredLanguagesBreakTieOnlyWhenOpenReadIsAmbiguous() {
        let shortCatalan = "la solucio jo la tiraria mes per alla"
        XCTAssertNil(
            CompletionCoordinator.dominantLanguage(shortCatalan, minConfidence: 0.80))
        XCTAssertEqual(
            CompletionCoordinator.dominantLanguage(
                shortCatalan, minConfidence: 0.80,
                languageConstraints: [.english, .spanish, .catalan]
            ),
            .catalan
        )
    }

    func testMixedLanguageBlobFailsCloseHypothesisMargin() {
        let mixed = "This message is about work. Podemos empezar mañana."
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish]
        recognizer.processString(mixed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }

        XCTAssertEqual(hypotheses.count, 2)
        XCTAssertLessThan(hypotheses[0].value - hypotheses[1].value, 0.10)
        XCTAssertNil(
            CompletionCoordinator.dominantLanguage(
                mixed, minConfidence: 0.40,
                languageConstraints: [.english, .spanish]
            )
        )
    }
}
