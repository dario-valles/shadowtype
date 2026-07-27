// PromptHeadStabilityTests — the end-to-end guard on the invariant the whole prompt/KV design rests on.
//
// The engine reuses KV by longest-common-PREFIX (InferenceEngine.reuseLength). Every context block —
// instruction, style, clipboard, screen OCR, post-caret — is assembled IN FRONT of the caret text, so if
// any of them changes while the user types, the streams diverge at the first token and each fire pays a
// full cold prefill instead of the warm path. The individual pieces have their own unit tests
// (anchoredTail, trimToWindow, the de-drafted OCR block); this file asserts the property that actually
// matters, on the WHOLE assembled prompt, with every block switched on at once.
//
// It exists because the composition regressed while each piece stayed correct: anchoredTail pins the
// prefix window's START, but its LENGTH grows a byte per keystroke, and while the prefix shared one
// allocation pass with the context blocks that byte came out of the OCR block's budget — re-cutting a
// block that sits in front of the prefix, on every keystroke. Measured 120 distinct heads across 120
// keystrokes: the anchoring was fully defeated, and no existing test could see it.
import XCTest
@testable import Shadowtype

final class PromptHeadStabilityTests: XCTestCase {

    private func head(of prompt: String) -> String {
        if let r = prompt.range(of: "\n\nText (in English):\n") ?? prompt.range(of: "\n\nText:\n") {
            return String(prompt[..<r.upperBound])
        }
        return "<no-marker>"
    }

    /// Every block on (paid instruction + style + screen OCR + post-caret + language steer), budget
    /// binding, draft growing one character per keystroke: the head must not move.
    func testHeadIsByteStableWithEveryContextBlockPresent() throws {
        let ocr = (1...40).map { "Screen line \($0) of surrounding conversation context." }.joined(separator: "\n")
        let suffix = "\n\nThis paragraph already follows the caret and must not be duplicated."
        let base = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 60)

        var heads = Set<String>()
        var prompts: [String] = []
        for i in 0..<120 {
            let p = CompletionCoordinator.assemblePrompt(
                prefix: base + String(repeating: "x", count: i), isLicensed: true,
                instruction: "Reply in a friendly tone", styleHint: "favors: concise; direct",
                styleEnabled: true, clipboard: nil, clipboardEnabled: false,
                ocr: ocr, ocrEnabled: true, postCaret: suffix,
                steerLanguageName: "English", totalChars: 3520)
            prompts.append(p.prompt)
            heads.insert(head(of: p.prompt))
        }
        // Guard against passing vacuously: a run where the budget dropped EVERY block would have no
        // `Text:` marker and a constant "<no-marker>" head, which is stable and worthless. The head must
        // really be carrying context.
        let sample = try XCTUnwrap(prompts.last)
        XCTAssertTrue(sample.hasPrefix("Context:\n"), "no context survived — the stability check is vacuous")
        XCTAssertTrue(sample.contains("Screen line"), "screen context was dropped entirely")
        XCTAssertTrue(sample.contains("follows the caret"), "post-caret block was dropped entirely")
        // The head may change when the prefix window RE-ANCHORS (once per anchor step, so at most once or
        // twice across a 120-byte burst) — that is the design. What must never happen is the regression
        // this file was written for: one distinct head per keystroke.
        XCTAssertLessThanOrEqual(heads.count, 2,
                                 "prompt head mutated \(heads.count)x across 120 keystrokes — KV reuse is defeated")

        // The stronger form of the same property: each prompt is a strict EXTENSION of the previous one,
        // which is exactly what reuseLength needs. The prefix window re-anchors in steps, so a small
        // number of non-extension steps is expected; one per anchor step, not one per keystroke.
        let nonExtensions = (1..<prompts.count).filter { !prompts[$0].hasPrefix(prompts[$0 - 1]) }.count
        XCTAssertLessThanOrEqual(nonExtensions, 3, "expected re-anchor steps only, got \(nonExtensions)")
    }

    /// The Free default (no licence, screen context off) must still be the bare prefix — no framing, no
    /// wasted cap — and equally stable.
    func testFreeDefaultStaysBarePrefixAndStable() {
        let base = String(repeating: "words in a draft ", count: 40)
        var heads = Set<String>()
        for i in 0..<60 {
            let draft = base + String(repeating: "y", count: i)
            let p = CompletionCoordinator.assemblePrompt(
                prefix: draft, isLicensed: false,
                instruction: "ignored when unlicensed", styleHint: "ignored", styleEnabled: true,
                clipboard: "ignored", clipboardEnabled: true, ocr: nil, ocrEnabled: false,
                postCaret: nil, steerLanguageName: nil, totalChars: 3520)
            XCTAssertFalse(p.prompt.contains("Context:\n"), "unlicensed context leaked into the prompt")
            // Compared against the trailing-whitespace-trimmed draft: assemblePrompt deliberately drops a
            // dangling space so the base model predicts the next space-prefixed word.
            XCTAssertTrue(draft.trimmingCharacters(in: .whitespaces).hasSuffix(p.prompt),
                          "free path must be a plain tail of the draft")
            heads.insert(String(p.prompt.prefix(32)))
        }
        XCTAssertLessThanOrEqual(heads.count, 2, "free-path head slid \(heads.count) times")
    }
}
