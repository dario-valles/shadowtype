// Post-caret conditioning (item 14): the model used to be told NOTHING about the text after the caret.
// caretAtLineEnd() only means "the next character is a newline" — not end-of-document — so editing
// paragraph 2 of a 5-paragraph mail, the completion happily duplicated or contradicted what sat three
// lines below. assemblePrompt now carries an `After the cursor:` block, and these tests pin the two
// properties that make it safe: it never starves the caret text, and it never moves the prompt HEAD
// during a typing burst (the head is what the engine's longest-common-prefix KV reuse matches on).
import XCTest
@testable import Shadowtype

final class PostCaretContextTests: XCTestCase {

    private let marker = "\n\nText:\n"

    private func assemble(prefix: String, postCaret: String?, budget: Int = 4000,
                          ocr: String? = nil) -> String {
        CompletionCoordinator.assemblePrompt(
            prefix: prefix, isLicensed: true,
            instruction: nil, styleHint: nil, styleEnabled: false,
            clipboard: nil, clipboardEnabled: false,
            ocr: ocr, ocrEnabled: ocr != nil,
            postCaret: postCaret,
            totalChars: budget).prompt
    }

    // MARK: - The block itself

    func testBlockSitsImmediatelyBeforeTheTextMarker() {
        let p = assemble(prefix: "Thanks for the ", postCaret: "\n\nBest,\nDario")
        XCTAssertEqual(p, "Context:\nAfter the cursor:\nBest,\nDario\n\nText:\nThanks for the")
    }

    // Rendered LAST of the context blocks: adjacency to the `Text:` marker is what makes the
    // before/after relationship legible to a base model, and appending at the end leaves every earlier
    // block's bytes untouched so a fire with the block still shares a KV prefix with one without it.
    func testBlockRendersAfterScreenContext() {
        let p = assemble(prefix: "so I ", postCaret: "and then we can ship it.",
                         ocr: "the meeting is on Thursday")
        let ocrAt = p.range(of: "the meeting is on Thursday")!.lowerBound
        let postAt = p.range(of: "After the cursor:")!.lowerBound
        XCTAssertLessThan(ocrAt, postAt)
        XCTAssertTrue(p.hasSuffix("\(marker)so I"))
    }

    // The label must not contain `Text:` / `Text (`: those are literal stop markers on the rewrite path
    // (SamplingParams.rewriteDefaults) and the marker this very prompt ends with. A block header that
    // collided with them would be a stop string embedded in the prompt.
    func testBlockLabelDoesNotCollideWithTheStopMarkers() {
        let block = CompletionCoordinator.postCaretBlock("something follows")!
        XCTAssertFalse(block.contains("Text:"))
        XCTAssertFalse(block.contains("Text ("))
    }

    // MARK: - Gating

    func testNoPostCaretTextIsByteIdenticalToTheOldPrompt() {
        let baseline = assemble(prefix: "the quick brown", postCaret: nil)
        XCTAssertEqual(baseline, "the quick brown")   // bare prefix, no framing at all
        // Whitespace-only (the caret sitting above a blank line, or trailing newlines at end of
        // document) says nothing and must not introduce a block — nor let the head appear/disappear as
        // that whitespace churns.
        for empty in ["", "\n", "\n\n\n", "   ", " \n \n"] {
            XCTAssertEqual(assemble(prefix: "the quick brown", postCaret: empty), baseline, "\(empty.debugDescription)")
        }
        XCTAssertNil(CompletionCoordinator.postCaretBlock("\n\n"))
        XCTAssertNil(CompletionCoordinator.postCaretBlock(nil))
    }

    // Shell mode never reaches assemblePrompt at all — assembleShellPrompt is a separate few-shot
    // `$ command` framing with no context blocks — so the post-caret block can't leak into a terminal.
    func testShellPromptCarriesNoPostCaretBlock() {
        let p = CompletionCoordinator.assembleShellPrompt(prefix: "git che",
                                                          terminalBuffer: "$ git status\n$ ")
        XCTAssertFalse(p.contains("After the cursor:"))
    }

    // MARK: - Truncation direction

    func testTruncationKeepsTheTextNEARESTTheCaret() {
        let near = String(repeating: "near ", count: 40)     // 200 bytes
        let far  = String(repeating: "far ", count: 40)
        let block = CompletionCoordinator.postCaretBlock(near + far, maxBytes: 100)!
        XCTAssertTrue(block.hasPrefix("After the cursor:\nnear near"))
        XCTAssertFalse(block.contains("far"))
        // The header is not charged against maxBytes — the cap bounds the post-caret TEXT.
        XCTAssertEqual(PromptSectionBudget.cost(block.replacingOccurrences(of: "After the cursor:\n", with: "")), 100)
    }

    func testHeadWindowNeverSplitsAMultiByteCharacter() {
        // "é" is 2 UTF-8 bytes: a 3-byte window over "aéb" must keep "aé", not half of "é".
        XCTAssertEqual(PromptSectionBudget.headWithinCost("aéb", maxCost: 3), "aé")
        XCTAssertEqual(PromptSectionBudget.headWithinCost("aéb", maxCost: 2), "a")
        XCTAssertEqual(PromptSectionBudget.headWithinCost("aéb", maxCost: 0), "")
        XCTAssertEqual(PromptSectionBudget.headWithinCost("aéb", maxCost: 99), "aéb")
    }

    // MARK: - KV stability (the make-or-break: this block sits in FRONT of the prefix)

    // The text after the caret does not change while the user types before it, so the block must not
    // either. With the head byte-identical and the prefix only growing, each prompt is a STRICT
    // EXTENSION of the previous one — exactly the shape InferenceEngine's longest-common-prefix reuse
    // needs to skip re-prefilling the context region on every keystroke.
    func testPromptHeadIsByteStableAcrossATypingBurst() {
        let suffix = "\n\nThe deadline is Friday and the venue has changed to the annex."
        let typed = "Hi Ana, I wanted to check whether the room booking still stands"
        var prompts: [String] = []
        for n in stride(from: 8, through: typed.count, by: 1) {
            prompts.append(assemble(prefix: String(typed.prefix(n)), postCaret: suffix))
        }
        let head = String(prompts[0][..<prompts[0].range(of: marker)!.upperBound])
        for p in prompts {
            XCTAssertTrue(p.hasPrefix(head), "prompt head moved: \(p.prefix(120).debugDescription)")
        }
        // …and strictly extending, keystroke to keystroke (a trailing-space keystroke is trimmed away by
        // assemblePrompt, so compare only the strictly-growing steps).
        for (a, b) in zip(prompts, prompts.dropFirst()) where a.count < b.count {
            XCTAssertTrue(b.hasPrefix(a), "not a strict extension at \(a.count) -> \(b.count)")
        }
    }

    // Under a budget tight enough to bind, the block is taken WHOLE or dropped — never re-cut to
    // "whatever the growing prefix left over", which would shrink the prompt head by a few bytes per
    // keystroke and force a cold re-prefill on every fire.
    func testBlockIsNeverPartiallyTrimmedAsThePrefixGrows() {
        let suffix = String(repeating: "tail ", count: 12)          // 60 bytes
        let whole = CompletionCoordinator.postCaretBlock(suffix)!
        var seenWhole = false, seenAbsent = false
        for n in stride(from: 60, through: 200, by: 1) {
            let p = assemble(prefix: String(repeating: "a", count: n), postCaret: suffix, budget: 200)
            if p.contains("After the cursor:") {
                XCTAssertTrue(p.contains(whole), "post-caret block was mutated at prefix \(n)")
                seenWhole = true
            } else {
                seenAbsent = true
            }
        }
        XCTAssertTrue(seenWhole, "budget never left room — the test proves nothing")
        XCTAssertTrue(seenAbsent, "budget never bound — the test proves nothing")
    }

    // MARK: - Budget rank

    // Below the prefix: the caret text is never starved to make room for the post-caret block.
    func testCaretTextIsNeverStarvedByThePostCaretBlock() {
        let draft = "the important thing I am actually writing right now at the caret"
        let p = assemble(prefix: draft, postCaret: String(repeating: "z ", count: 400), budget: 120)
        XCTAssertTrue(p.hasSuffix("at the caret"), "\(p.debugDescription)")
    }

    // Above screen context, deliberately. The OCR block declares its whole length as maxChars, so under
    // a binding budget it consumes everything the higher priorities left; ranked below it, the
    // post-caret block would be dead weight in practice whenever screen context is on.
    func testPostCaretOutranksScreenContextUnderPressure() {
        let p = assemble(prefix: "so I ", postCaret: "and we ship on Friday.",
                         budget: 120, ocr: String(repeating: "screen noise ", count: 40))
        XCTAssertTrue(p.contains("and we ship on Friday."))
    }
}
