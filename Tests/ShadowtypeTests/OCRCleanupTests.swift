// OCRCleanupTests — pure-function coverage for the FR-CTX-1 screen-OCR cleanup helpers that feed the
// completion prompt: denoise (chrome filtering) and removingDraftEcho (de-duplicating the user's own
// draft). No ScreenCaptureKit / Vision needed — runs under `swift test`.
import XCTest
import NaturalLanguage
@testable import Shadowtype

final class OCRCleanupTests: XCTestCase {

    // MARK: - denoise

    func testDenoiseDropsChromeAndShortTokens() {
        let input = """
        Send
        $39
        Tranche 1
        On it. I'll build the Apple-clean light theme.
        explore a lighter/Apple-clean variant of the hero?
        """
        let out = ScreenContextProvider.denoise(input)
        XCTAssertFalse(out.contains("Send"))
        XCTAssertFalse(out.contains("$39"))
        XCTAssertFalse(out.contains("Tranche 1"))
        XCTAssertTrue(out.contains("Apple-clean light theme"))
        XCTAssertTrue(out.contains("variant of the hero?"))
    }

    // The AX page-text path passes dropShortLines:false because its text is EXACT: short signature /
    // name rows (a 2-word name, a title like "VP Sales") must survive so the model can complete a name.
    // The default (OCR) path still drops them as lone-token chrome.
    func testDenoiseKeepsShortSignatureLinesWhenDropShortLinesFalse() {
        let input = """
        estas seguro de que no te has equivocado?
        --
        Jane Appleseed
        VP Sales
        """
        let dropped = ScreenContextProvider.denoise(input)                       // OCR default
        XCTAssertFalse(dropped.contains("Jane Appleseed"))
        XCTAssertFalse(dropped.contains("VP Sales"))
        let kept = ScreenContextProvider.denoise(input, dropShortLines: false)   // AX path
        XCTAssertTrue(kept.contains("Jane Appleseed"))
        XCTAssertTrue(kept.contains("VP Sales"))
        // Digit chrome (a phone number) is still dropped even when short lines are kept.
        XCTAssertFalse(ScreenContextProvider.denoise("675.089.798", dropShortLines: false).contains("675"))
    }

    func testDenoiseKeepsLongUnpunctuatedSentence() {
        // > 2 words and > 16 chars: real prose, kept even without sentence punctuation.
        let line = "the user is writing a long line without any punctuation at all here"
        XCTAssertEqual(ScreenContextProvider.denoise(line), line)
    }

    func testDenoiseDropsBlankLines() {
        XCTAssertEqual(ScreenContextProvider.denoise("a real sentence, kept.\n\n\n"), "a real sentence, kept.")
    }

    // MARK: - digit-heavy chrome (date/time/number noise that primed stray-digit garbage)

    func testDenoiseDropsDateHeaderLine() {
        // Multi-word date header the ≤2-word rule keeps, but the digit-fraction rule drops.
        let input = """
        3 June 2026 at 08:20
        Esa es una historia de una princesa que vive en un castillo.
        12/09/2025
        """
        let out = ScreenContextProvider.denoise(input)
        XCTAssertFalse(out.contains("2026"))
        XCTAssertFalse(out.contains("12/09/2025"))
        XCTAssertTrue(out.contains("una princesa que vive en un castillo"))
    }

    func testDenoiseKeepsProseWithOccasionalNumber() {
        // A sentence that merely mentions a year stays well under 30% digits — kept.
        let line = "We met in 2019 at the conference downtown and it was great"
        XCTAssertEqual(ScreenContextProvider.denoise(line), line)
    }

    func testIsDigitHeavyThreshold() {
        XCTAssertTrue(ScreenContextProvider.isDigitHeavy("3 June 2026 at 08:20"))
        XCTAssertTrue(ScreenContextProvider.isDigitHeavy("28/04/2026"))
        XCTAssertFalse(ScreenContextProvider.isDigitHeavy("una historia de una princesa"))
        XCTAssertFalse(ScreenContextProvider.isDigitHeavy(""))
    }

    func testDenoiseDropsTruncatedRowsAndUrls() {
        let input = """
        El cuento de la ce...
        La llamada del hér...
        https://guests.ren.example/abc
        This is a genuine sentence the user can actually read.
        """
        let out = ScreenContextProvider.denoise(input)
        XCTAssertFalse(out.contains("..."))
        XCTAssertFalse(out.contains("http"))
        XCTAssertTrue(out.contains("genuine sentence the user can actually read"))
    }

    // MARK: - substantialContextOrNil (chrome-only block -> drop to prefix-only)

    func testSubstantialContextDropsChromeOnly() {
        // Notes-sidebar residue after dedup: short section headers, no real prose -> nil.
        let chrome = "fl Recently Deleted\nPrevious 30 Days"
        XCTAssertNil(ScreenContextProvider.substantialContextOrNil(chrome))
    }

    func testSubstantialContextKeepsChatHistory() {
        let chat = "Can you review the deployment plan before Friday afternoon please?\nSure, sending notes now."
        XCTAssertEqual(ScreenContextProvider.substantialContextOrNil(chat), chat)
    }

    func testSubstantialContextNilPassthrough() {
        XCTAssertNil(ScreenContextProvider.substantialContextOrNil(nil))
    }

    // MARK: - removingDocumentEcho (de-dup the focused doc, already in the AX prefix, from OCR)

    func testRemovingDocumentEchoStripsRegurgitatedBody() {
        let prefix = "Esa es una historia de una princesa que vive en un castillo y que una noche va a un baile.\nEl cuento de la cenicienta es un cuento de "
        let ocr = """
        El cuento de la cenicienta
        Esa es una historia de una princesa que vive en un castillo y que una noche va a un baile.
        Previous 30 Days
        """
        let out = ScreenContextProvider.removingDocumentEcho(ocr, prefix: prefix)
        XCTAssertFalse(out?.contains("una noche va a un baile") ?? true)   // doc body removed
        XCTAssertFalse(out?.contains("El cuento de la cenicienta") ?? true) // title removed (in prefix)
        XCTAssertTrue(out?.contains("Previous 30 Days") ?? false)          // genuinely-new screen text kept
    }

    func testRemovingDocumentEchoKeepsNewContext() {
        // Screen text NOT in the prefix (e.g. a chat history above the composer) survives.
        let prefix = "Thanks, I'll take a look at "
        let ocr = "Can you review the deployment plan before Friday?\nThanks, I'll take a look at"
        let out = ScreenContextProvider.removingDocumentEcho(ocr, prefix: prefix)
        XCTAssertEqual(out, "Can you review the deployment plan before Friday?")
    }

    func testRemovingDocumentEchoShortLinesKept() {
        // Below minEchoLen, lines pass through even if echoed (too short to match safely).
        let out = ScreenContextProvider.removingDocumentEcho("hola\nadios", prefix: "hola adios amigo")
        XCTAssertEqual(out, "hola\nadios")
    }

    func testRemovingDocumentEchoNilPassthrough() {
        XCTAssertNil(ScreenContextProvider.removingDocumentEcho(nil, prefix: "anything"))
    }

    // MARK: - removingDraftEcho

    func testRemovingDraftEchoStripsComposerLine() {
        let ocr = "explore a lighter/Apple-clean variant of the hero?\nLighter apple"
        let out = ScreenContextProvider.removingDraftEcho(ocr, draft: "Lighter apple")
        XCTAssertEqual(out, "explore a lighter/Apple-clean variant of the hero?")
    }

    func testRemovingDraftEchoStripsDraftPlusGhost() {
        // The OCR captured the composer line as draft + the ghost suggestion appended to it.
        let ocr = "context line here.\nLighter apple pieIngredients: 1 lb apples"
        let out = ScreenContextProvider.removingDraftEcho(ocr, draft: "Lighter apple")
        XCTAssertEqual(out, "context line here.")
    }

    func testRemovingDraftEchoShortDraftIsNoOp() {
        let ocr = "It is a nice day.\nI"
        XCTAssertEqual(ScreenContextProvider.removingDraftEcho(ocr, draft: "I"), ocr)
    }

    func testRemovingDraftEchoNilPassthrough() {
        XCTAssertNil(ScreenContextProvider.removingDraftEcho(nil, draft: "Lighter apple"))
    }

    func testRemovingDraftEchoAllEchoReturnsNil() {
        XCTAssertNil(ScreenContextProvider.removingDraftEcho("Lighter apple", draft: "Lighter apple"))
    }

    // MARK: - ocrTextEquivalent (re-capture change guard: only a meaningful change busts the KV cache)

    func testOCREquivalentIgnoresWhitespaceReflow() {
        // Same words, different line breaks / trailing spaces (OCR jitter) -> NOT a change.
        let a = "Can you review the deployment plan\nbefore Friday afternoon please?"
        let b = "Can you review the deployment plan before Friday afternoon please?  "
        XCTAssertTrue(CompletionCoordinator.ocrTextEquivalent(a, b))
    }

    func testOCREquivalentDetectsNewProse() {
        // A genuinely new line (e.g. user scrolled to fresh content) -> change.
        let a = "Monta la tabla de escalado real cuando tengas los tramos."
        let b = "Monta la tabla de escalado real cuando tengas los tramos.\nIdioma español, precios formato ES."
        XCTAssertFalse(CompletionCoordinator.ocrTextEquivalent(a, b))
    }

    func testOCREquivalentNilAndEmptyAreEqual() {
        XCTAssertTrue(CompletionCoordinator.ocrTextEquivalent(nil, ""))
        XCTAssertTrue(CompletionCoordinator.ocrTextEquivalent(nil, "   \n  "))
        XCTAssertTrue(CompletionCoordinator.ocrTextEquivalent(nil, nil))
    }

    func testOCREquivalentNilVsContentIsChange() {
        XCTAssertFalse(CompletionCoordinator.ocrTextEquivalent(nil, "a real sentence here"))
    }

    // MARK: - thread-aware reply context (AX page-text v1 cleanup pipeline)

    // The AX backend reads the whole page top→bottom, then runs the same cleanup as OCR:
    // denoise → clamp(tail) → removingDraftEcho → removingQuotedReplyBlock (web-mail only). Assert a
    // Gmail-shaped page reduces to the opened message prose while the inbox chrome (top) and the
    // user's own draft (bottom) drop out.
    func testAXPageTextReducesToThreadProse() throws {
        // Synthetic page text in document order: inbox sidebar chrome, the opened email being replied
        // to, then the reply compose draft + signature at the bottom.
        let page = """
        Inbox
        98
        Promotions
        LinkedIn
        Zed v1.5 is out!
        We are seeing a crash when the app loads a large model on macOS 14, can you reproduce it?
        Thanks for the report — could you tell us which model and how much RAM the machine has?
        This is a real
        --
        Jane Appleseed
        """
        let draft = "This is a real"
        let denoised = ScreenContextProvider.denoise(page)
        let tail = ScreenContextProvider.clamp(denoised, to: 4000)
        let deDraft = ScreenContextProvider.removingDraftEcho(tail, draft: draft)
        let ctx = ScreenContextProvider.substantialContextOrNil(deDraft)

        let result = try XCTUnwrap(ctx)
        // The opened-thread prose survives.
        XCTAssertTrue(result.contains("crash when the app loads a large model"))
        XCTAssertTrue(result.contains("which model and how much RAM"))
        // The user's own draft is gone (it's already in the prefix).
        XCTAssertFalse(result.contains("This is a real"))
        // Single-token inbox chrome is gone.
        XCTAssertFalse(result.contains("\nInbox"))
        XCTAssertFalse(result.contains("Promotions"))
    }

    // MARK: - quoted reply block stripping (Gmail/Outlook chrome)

    func testRemovingQuotedReplyBlockDropsAttributionAndQuotedLines() throws {
        let input = """
        Hi Alice,
        Thanks for the report.
        On Mon, Jun 4, 2026 at 10:23, Alice <alice@x.com> wrote:
        > we're seeing a crash
        > on macOS 14
        > with a 7B model
        """
        let out = try XCTUnwrap(ScreenContextProvider.removingQuotedReplyBlock(input))
        XCTAssertTrue(out.contains("Hi Alice"))
        XCTAssertTrue(out.contains("Thanks for the report"))
        XCTAssertFalse(out.contains("wrote:"))
        XCTAssertFalse(out.contains("we're seeing a crash"))
        XCTAssertFalse(out.contains(">"))
    }

    func testRemovingQuotedReplyBlockHandlesSpanishAttribution() throws {
        let input = """
        Hola Alicia,
        Gracias por el informe.
        El lunes, 4 de junio de 2026, Alicia <alicia@x.com> escribió:
        > vemos un cierre inesperado
        > en macOS 14
        """
        let out = try XCTUnwrap(ScreenContextProvider.removingQuotedReplyBlock(input))
        XCTAssertTrue(out.contains("Gracias por el informe"))
        XCTAssertFalse(out.contains("escribió:"))
        XCTAssertFalse(out.contains("cierre inesperado"))
    }

    func testRemovingQuotedReplyBlockNoOpOnPlainProse() {
        // A normal page has no attribution / quote chars → input passes through unchanged.
        let input = "Just a normal paragraph.\nAnother line that ends with a colon:\nMore prose."
        XCTAssertEqual(ScreenContextProvider.removingQuotedReplyBlock(input), input)
    }

    func testRemovingQuotedReplyBlockDropsOutlookOriginalMessageBlock() throws {
        // Outlook-style reply: separator + From/Sent/To/Subject header + quoted body. Everything
        // from the separator down is the original message and should vanish.
        let input = """
        Hi Alice,
        Thanks for the report.
        -----Original Message-----
        From: Alice <alice@x.com>
        Sent: Monday, June 4, 2026 10:23
        To: Bob <bob@x.com>
        Subject: Crash on macOS 14
        We are seeing a crash when the app loads a large model on macOS 14.
        """
        let out = try XCTUnwrap(ScreenContextProvider.removingQuotedReplyBlock(input))
        XCTAssertTrue(out.contains("Hi Alice"))
        XCTAssertTrue(out.contains("Thanks for the report"))
        XCTAssertFalse(out.contains("Original Message"))
        XCTAssertFalse(out.contains("From:"))
        XCTAssertFalse(out.contains("crash when the app loads"))
    }

    func testRemovingQuotedReplyBlockHandlesSpanishOutlookSeparator() throws {
        let input = """
        Hola Alicia,
        Gracias por el informe.
        -----Mensaje original-----
        De: Alicia
        Enviado: lunes, 4 de junio de 2026
        Asunto: Cierre inesperado
        Vemos un cierre inesperado al cargar el modelo.
        """
        let out = try XCTUnwrap(ScreenContextProvider.removingQuotedReplyBlock(input))
        XCTAssertTrue(out.contains("Gracias por el informe"))
        XCTAssertFalse(out.contains("Mensaje original"))
        XCTAssertFalse(out.contains("cierre inesperado al cargar"))
    }

    func testIsOriginalMessageSeparatorRecognizesLocalizedForms() {
        XCTAssertTrue(ScreenContextProvider.isOriginalMessageSeparator("-----Original Message-----"))
        XCTAssertTrue(ScreenContextProvider.isOriginalMessageSeparator("-----Mensaje original-----"))
        XCTAssertTrue(ScreenContextProvider.isOriginalMessageSeparator("---Message d'origine---"))
        XCTAssertTrue(ScreenContextProvider.isOriginalMessageSeparator("-----Ursprüngliche Nachricht-----"))
        XCTAssertFalse(ScreenContextProvider.isOriginalMessageSeparator("------"))
        XCTAssertFalse(ScreenContextProvider.isOriginalMessageSeparator("Original Message"))   // no dashes
        XCTAssertFalse(ScreenContextProvider.isOriginalMessageSeparator(""))
    }

    func testStripTrailingQuotedBlockTruncatesAtOutlookSeparator() {
        let prefix = """
        Hi Alice,
        Thanks.
        -----Original Message-----
        From: Alice
        Subject: Crash
        old content
        """
        let out = ScreenContextProvider.stripTrailingQuotedBlock(prefix)
        XCTAssertTrue(out.contains("Thanks"))
        XCTAssertFalse(out.contains("Original Message"))
        XCTAssertFalse(out.contains("From:"))
    }

    func testStripTrailingQuotedBlockRemovesTailOnly() {
        // Caret sat below the trimmed-content reveal: prefix tail is attribution + ">"-lines.
        let prefix = """
        Hi Alice,
        Thanks for the report.

        On Mon, Jun 4, 2026, Alice wrote:
        > we're seeing a crash
        > on macOS 14
        """
        let out = ScreenContextProvider.stripTrailingQuotedBlock(prefix)
        XCTAssertTrue(out.contains("Thanks for the report"))
        XCTAssertFalse(out.contains("wrote:"))
        XCTAssertFalse(out.contains(">"))
    }

    func testStripTrailingQuotedBlockKeepsProseAfterQuote() {
        // Rare but real: user typed NEW prose AFTER an attribution. Don't drop the new prose.
        let prefix = """
        On Mon, Alice wrote:
        > old quote
        Following up here
        """
        let out = ScreenContextProvider.stripTrailingQuotedBlock(prefix)
        XCTAssertTrue(out.contains("Following up here"))
    }

    func testPrefixAfterEmailQuoteStripScopedToWebMail() {
        let prefix = "On Mon, Alice wrote:\n> stuff"
        // mail.google.com → strip applies.
        XCTAssertEqual(CompletionCoordinator.prefixAfterEmailQuoteStrip(prefix, host: "mail.google.com"), "")
        // Non-web-mail host → input returned unchanged (no false positives outside email).
        XCTAssertEqual(CompletionCoordinator.prefixAfterEmailQuoteStrip(prefix, host: "github.com"), prefix)
        XCTAssertEqual(CompletionCoordinator.prefixAfterEmailQuoteStrip(prefix, host: nil), prefix)
        XCTAssertNil(CompletionCoordinator.prefixAfterEmailQuoteStrip(nil, host: "mail.google.com"))
    }

    // Composite: the AX page-text path now also passes through removingQuotedReplyBlock — the quoted
    // history at the bottom of a Gmail thread is gone while the new prose above survives.
    func testAXPageTextReducesToThreadProseWithQuotedHistoryDropped() throws {
        let page = """
        Inbox
        Promotions
        We are seeing a crash when the app loads a large model on macOS 14, can you reproduce it?
        Thanks for the report — could you tell us which model and how much RAM the machine has?
        On Mon, Jun 4, 2026, Alice <alice@x.com> wrote:
        > We are seeing a crash when the app loads a large model on macOS 14
        > Can you reproduce it?
        This is a real
        """
        let draft = "This is a real"
        let denoised = ScreenContextProvider.denoise(page)
        let tail = ScreenContextProvider.clamp(denoised, to: 4000)
        let deDraft = ScreenContextProvider.removingDraftEcho(tail, draft: draft)
        let deQuoted = ScreenContextProvider.removingQuotedReplyBlock(deDraft)
        let ctx = try XCTUnwrap(ScreenContextProvider.substantialContextOrNil(deQuoted))
        XCTAssertTrue(ctx.contains("crash when the app loads a large model"))
        XCTAssertFalse(ctx.contains("wrote:"))
        // The DUPLICATED quoted line is gone (it survives once via the top thread message).
        XCTAssertFalse(ctx.contains("> We are seeing a crash"))
    }

    // MARK: - context re-fire cap (stops the ghost cycling through suggestions during a pause)

    func testContextRefireCapBoundsToOnce() {
        // First context-upgrade re-fire for a focus session: allowed.
        XCTAssertTrue(CompletionCoordinator.shouldRefireForContext(count: 0, max: 1))
        // Cap reached: no further re-fire, regardless of how the prefix read drifts (kills the churn).
        XCTAssertFalse(CompletionCoordinator.shouldRefireForContext(count: 1, max: 1))
        XCTAssertFalse(CompletionCoordinator.shouldRefireForContext(count: 5, max: 1))
        // A larger cap allows that many before stopping.
        XCTAssertTrue(CompletionCoordinator.shouldRefireForContext(count: 1, max: 2))
        XCTAssertFalse(CompletionCoordinator.shouldRefireForContext(count: 2, max: 2))
    }

    // MARK: - language steering + context-language drift suppression (match the conversation, else hide)

    func testEnglishLanguageNameMapsCode() {
        XCTAssertEqual(CompletionCoordinator.englishLanguageName(NLLanguage("ca")), "Catalan")
        XCTAssertEqual(CompletionCoordinator.englishLanguageName(.spanish), "Spanish")
    }

    func testAssemblePromptSteerMarkerOnlyWhenNamed() {
        let ctx = "Aquesta és una conversa en català sobre la feina i les rutines del dia."
        let steered = CompletionCoordinator.assemblePrompt(
            prefix: "També necesito ", isLicensed: false,
            instruction: nil, styleHint: nil, styleEnabled: false,
            clipboard: nil, clipboardEnabled: false,
            ocr: ctx, ocrEnabled: true, steerLanguageName: "Catalan")
        XCTAssertTrue(steered.contains("\n\nText (in Catalan):\n"))
        XCTAssertFalse(steered.contains("\n\nText:\n"))

        // nil steer is byte-identical to the bare-marker output (guards KV-reuse identity).
        let bare = CompletionCoordinator.assemblePrompt(
            prefix: "També necesito ", isLicensed: false,
            instruction: nil, styleHint: nil, styleEnabled: false,
            clipboard: nil, clipboardEnabled: false,
            ocr: ctx, ocrEnabled: true)
        XCTAssertTrue(bare.contains("\n\nText:\n"))
        XCTAssertFalse(bare.contains("Text (in"))
    }

    func testSuggestionConflictsWithContext() {
        // Spanish completion in a Catalan thread → conflict (this is the live bug).
        XCTAssertTrue(CompletionCoordinator.suggestionConflictsWithContext(
            suggestion: "ayuda con un email para mi jefe", contextLang: NLLanguage("ca")))
        // Catalan completion in a Catalan thread → no conflict.
        XCTAssertFalse(CompletionCoordinator.suggestionConflictsWithContext(
            suggestion: "ajuda amb un correu per al meu cap", contextLang: NLLanguage("ca")))
        // Short/ambiguous suggestion → never collateral.
        XCTAssertFalse(CompletionCoordinator.suggestionConflictsWithContext(
            suggestion: "ok", contextLang: NLLanguage("ca")))
    }
}
