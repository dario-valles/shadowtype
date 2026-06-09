import XCTest
@testable import Shadowtype

final class RewriteActionTests: XCTestCase {

    // Every action produces a prompt that ends at the continuation point and includes the selection.
    func testPromptShapePerAction() {
        for action in RewriteAction.allCases {
            let p = RewriteAction.prompt(for: action, selection: "the quick brown fox")
            XCTAssertTrue(p.hasSuffix("Rewritten:"), "\(action) prompt must end at the continuation point")
            XCTAssertTrue(p.contains("\nText: the quick brown fox\nRewritten:"),
                          "\(action) prompt must place the selection in the final Text block")
            // Exactly two "Text:" blocks: one exemplar + the real selection.
            XCTAssertEqual(p.components(separatedBy: "Text:").count - 1, 2,
                           "\(action) prompt should have one exemplar plus the selection")
        }
    }

    // userTone is woven into the task line only when non-empty.
    func testUserToneAppendedWhenPresent() {
        let withTone = RewriteAction.prompt(for: .improve, selection: "hi", userTone: "Be concise, no emojis.")
        XCTAssertTrue(withTone.contains("Be concise, no emojis."))

        let nilTone = RewriteAction.prompt(for: .improve, selection: "hi", userTone: nil)
        XCTAssertFalse(nilTone.contains("style preference"))

        let blankTone = RewriteAction.prompt(for: .improve, selection: "hi", userTone: "   \n  ")
        XCTAssertFalse(blankTone.contains("style preference"),
                       "Whitespace-only tone must be treated as absent")
    }

    // cleanOutput cuts at the first fresh few-shot block the base model rolls into.
    func testCleanOutputStopsAtNextBlock() {
        let raw = " Could you send me the document?\n\nText: another example\nRewritten: ..."
        XCTAssertEqual(RewriteAction.cleanOutput(raw), "Could you send me the document?")
    }

    func testCleanOutputStopsAtSingleLineTextMarker() {
        let raw = "Shorter version here.\nText: next"
        XCTAssertEqual(RewriteAction.cleanOutput(raw), "Shorter version here.")
    }

    // A trailing paragraph break (model "ends then starts a new template/list") is dropped.
    func testCleanOutputStopsAtParagraphBreak() {
        let raw = "First clean sentence.\n\nThen some unrelated trailing garbage."
        XCTAssertEqual(RewriteAction.cleanOutput(raw), "First clean sentence.")
    }

    // When the SELECTION was multi-paragraph, a `\n\n` in the output is a real paragraph the model
    // preserved — it must NOT be truncated (the data-loss bug). The few-shot markers still bound runaway.
    func testCleanOutputKeepsParagraphsForMultilineSelection() {
        let raw = "First rewritten paragraph.\n\nSecond rewritten paragraph."
        XCTAssertEqual(RewriteAction.cleanOutput(raw, selectionWasMultiline: true),
                       "First rewritten paragraph.\n\nSecond rewritten paragraph.")
        // The runaway marker still cuts even in multiline mode.
        let runaway = "Para one.\n\nPara two.\n\nText: next example"
        XCTAssertEqual(RewriteAction.cleanOutput(runaway, selectionWasMultiline: true),
                       "Para one.\n\nPara two.")
    }

    func testCleanOutputStripsEchoedLabelAndQuotes() {
        XCTAssertEqual(RewriteAction.cleanOutput("Rewritten: Hello there."), "Hello there.")
        XCTAssertEqual(RewriteAction.cleanOutput("\"Hello there.\""), "Hello there.")
        XCTAssertEqual(RewriteAction.cleanOutput("\u{201C}Hello there.\u{201D}"), "Hello there.")
    }

    func testCleanOutputTrimsSurroundingWhitespace() {
        XCTAssertEqual(RewriteAction.cleanOutput("  \n  trimmed me  \t"), "trimmed me")
    }

    // maxTokens scales with selection length and stays within [64, 1024]. The 1024 ceiling avoids the
    // mid-rewrite truncation of the old 256-token cap on paragraph-sized selections ("only part replaced").
    func testMaxTokensBounds() {
        XCTAssertEqual(RewriteAction.maxTokens(forSelection: ""), 64, "floor for empty/tiny selection")
        XCTAssertEqual(RewriteAction.maxTokens(forSelection: "hi"), 64, "tiny selection hits the floor")

        let huge = String(repeating: "word ", count: 2000)   // 10k chars
        XCTAssertEqual(RewriteAction.maxTokens(forSelection: huge), 1024, "huge selection hits the cap")

        let medium = String(repeating: "a", count: 400)       // ~100 tokens
        let m = RewriteAction.maxTokens(forSelection: medium)
        XCTAssertGreaterThan(m, 64)
        XCTAssertLessThan(m, 1024)
    }

    // When the caller passes a detected language, the prompt MUST carry an explicit "Write … in <Lang>"
    // directive AND tag the selection block with `Text (in <Lang>):` / `Rewritten (in <Lang>):`. Without
    // both, the English exemplar dominates and base models emit English regardless of the selection.
    func testPromptInjectsLanguageSteer() {
        let p = RewriteAction.prompt(for: .improve, selection: "hola mundo", language: "Spanish")
        XCTAssertTrue(p.contains("Write the rewritten text in Spanish."))
        XCTAssertTrue(p.contains("\nText (in Spanish): hola mundo\n"))
        XCTAssertTrue(p.hasSuffix("Rewritten (in Spanish):"))
        // Exemplar stays English-tagged (the steer is on the real block, not the exemplar).
        XCTAssertTrue(p.contains("\nText: i think the meeting"))

        // nil / blank language => unchanged shape (no directive, plain markers).
        for blank: String? in [nil, "", "   "] {
            let q = RewriteAction.prompt(for: .improve, selection: "hi", language: blank)
            XCTAssertFalse(q.contains("Write the rewritten text in"))
            XCTAssertTrue(q.hasSuffix("Rewritten:"))
        }
    }

    // The localized halt markers (`Text (in Spanish):`, `Rewritten (in Spanish):`) must cut runaway
    // just like the plain ones — otherwise the model's next fresh exemplar block leaks into the result.
    func testCleanOutputStopsAtLocalizedTextMarker() {
        let raw = "Hola, ¿qué tal?\n\nText (in Spanish): otro ejemplo\nRewritten (in Spanish): ..."
        XCTAssertEqual(RewriteAction.cleanOutput(raw), "Hola, ¿qué tal?")

        let multi = "Primer párrafo.\n\nSegundo párrafo.\n\nText (in Spanish): siguiente"
        XCTAssertEqual(RewriteAction.cleanOutput(multi, selectionWasMultiline: true),
                       "Primer párrafo.\n\nSegundo párrafo.")
    }
}
