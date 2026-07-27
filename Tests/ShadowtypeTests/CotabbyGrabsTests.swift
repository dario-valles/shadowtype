// CotabbyGrabsTests — pure coverage for the stability/quality/feature primitives reimplemented from
// the Cotabby competitive analysis: ghost-font stabilization, overlay stability gate, capability
// flicker gate, prompt section budget, RTL detection, insertion strategy, insertion safety, and the
// inference engine router scaffold. No AX/llama/AppKit runtime needed — runs under `swift test`.
import XCTest
import AppKit
import CoreGraphics
@testable import Shadowtype

final class CotabbyGrabsTests: XCTestCase {

    // MARK: - #1 GhostFontSizeStabilizer

    func testStabilizerFloorsToSessionMinimum() {
        var s = GhostFontSizeStabilizer()
        XCTAssertEqual(s.stabilizedCaretHeight(20, focusSessionKey: 1), 20)
        XCTAssertEqual(s.stabilizedCaretHeight(60, focusSessionKey: 1), 20)   // tall fallback clamped down
        XCTAssertEqual(s.stabilizedCaretHeight(14, focusSessionKey: 1), 14)   // a smaller real reading lowers it
        XCTAssertEqual(s.stabilizedCaretHeight(60, focusSessionKey: 1), 14)
    }

    func testStabilizerResetsOnNewSession() {
        var s = GhostFontSizeStabilizer()
        _ = s.stabilizedCaretHeight(14, focusSessionKey: 1)
        XCTAssertEqual(s.stabilizedCaretHeight(40, focusSessionKey: 2), 40)   // fresh field, no stale ceiling
    }

    func testStabilizerPassesNonPositiveThrough() {
        var s = GhostFontSizeStabilizer()
        _ = s.stabilizedCaretHeight(18, focusSessionKey: 7)
        XCTAssertEqual(s.stabilizedCaretHeight(0, focusSessionKey: 7), 0)     // a bad poll can't pin the min to 0
        XCTAssertEqual(s.stabilizedCaretHeight(18, focusSessionKey: 7), 18)
    }

    func testStabilizerIgnoresImplausiblySmallReadings() {
        // Plausibility floor: a sub-8pt caret height is AX noise (collapsed rect mid-relayout) — it
        // passes through unchanged and must NOT lower the session minimum.
        var s = GhostFontSizeStabilizer()
        XCTAssertEqual(s.stabilizedCaretHeight(18, focusSessionKey: 9), 18)
        XCTAssertEqual(s.stabilizedCaretHeight(5, focusSessionKey: 9), 5)     // noise passes through…
        XCTAssertEqual(s.stabilizedCaretHeight(40, focusSessionKey: 9), 18)   // …but the min held at 18
        // Exactly at the floor is a plausible tiny line and DOES participate.
        XCTAssertEqual(s.stabilizedCaretHeight(GhostFontSizeStabilizer.minPlausibleCaretHeight,
                                               focusSessionKey: 9), 8)
        XCTAssertEqual(s.stabilizedCaretHeight(18, focusSessionKey: 9), 8)
    }

    // MARK: - #2 OverlayStabilityGate

    private func cand(_ text: String, _ caret: CGRect, _ seq: UInt64,
                      opacity: CGFloat = 1, rtl: Bool = false, fontKey: String? = "Sys:16") -> OverlayStabilityGate.Rendered {
        OverlayStabilityGate.Rendered(text: text, caretRect: caret, focusSeq: seq,
                                      opacity: opacity, rtl: rtl, fontKey: fontKey)
    }

    func testGatePresentsWhenNothingShown() {
        XCTAssertTrue(OverlayStabilityGate.shouldRePresent(
            last: nil, candidate: cand("x", CGRect(x: 1, y: 2, width: 0, height: 16), 1)))
    }

    func testGateHoldsWhenStable() {
        let last = cand("hello", CGRect(x: 10, y: 20, width: 0, height: 16), 3)
        XCTAssertFalse(OverlayStabilityGate.shouldRePresent(
            last: last,
            candidate: cand("hello", CGRect(x: 10.4, y: 20.3, width: 0, height: 16), 3)))  // sub-pixel drift held
    }

    func testGateRePresentsOnTextOrFocusOrMove() {
        let last = cand("hello", CGRect(x: 10, y: 20, width: 0, height: 16), 3)
        let base = CGRect(x: 10, y: 20, width: 0, height: 16)
        XCTAssertTrue(OverlayStabilityGate.shouldRePresent(last: last, candidate: cand("hello world", base, 3)))
        XCTAssertTrue(OverlayStabilityGate.shouldRePresent(last: last, candidate: cand("hello", base, 4)))
        XCTAssertTrue(OverlayStabilityGate.shouldRePresent(
            last: last, candidate: cand("hello", CGRect(x: 40, y: 20, width: 0, height: 16), 3)))
    }

    func testGateRePresentsOnOpacityFontOrRTL() {
        let base = CGRect(x: 10, y: 20, width: 0, height: 16)
        let last = cand("hi", base, 3, opacity: 1, rtl: false, fontKey: "A:16")
        XCTAssertTrue(OverlayStabilityGate.shouldRePresent(             // fade step must redraw (#7)
            last: last, candidate: cand("hi", base, 3, opacity: 0.4, rtl: false, fontKey: "A:16")))
        XCTAssertTrue(OverlayStabilityGate.shouldRePresent(             // host font appeared (#3)
            last: last, candidate: cand("hi", base, 3, opacity: 1, rtl: false, fontKey: "B:16")))
        XCTAssertTrue(OverlayStabilityGate.shouldRePresent(             // RTL flip (#3)
            last: last, candidate: cand("hi", base, 3, opacity: 1, rtl: true, fontKey: "A:16")))
    }

    func testGateNullCaretHandling() {
        let last = cand("hi", .null, 1)
        XCTAssertFalse(OverlayStabilityGate.shouldRePresent(
            last: last, candidate: cand("hi", .null, 1)))            // both null → hold
        XCTAssertTrue(OverlayStabilityGate.shouldRePresent(
            last: last, candidate: cand("hi", CGRect(x: 1, y: 1, width: 0, height: 16), 1))) // null→real → re-present
    }

    // MARK: - #3 FocusCapabilityFlickerGate

    func testFlickerSuppressedThenReleased() {
        var gate = FocusCapabilityFlickerGate()
        XCTAssertEqual(gate.evaluate(hasContext: true, focusSeq: 5), .apply)      // good read
        XCTAssertEqual(gate.evaluate(hasContext: false, focusSeq: 5), .suppress(pendingMissCount: 1)) // 1st miss held
        XCTAssertEqual(gate.evaluate(hasContext: false, focusSeq: 5), .apply)     // 2nd consecutive → tear down
    }

    func testFlickerRecoversBeforeThreshold() {
        var gate = FocusCapabilityFlickerGate()
        _ = gate.evaluate(hasContext: true, focusSeq: 1)
        XCTAssertEqual(gate.evaluate(hasContext: false, focusSeq: 1), .suppress(pendingMissCount: 1))
        XCTAssertEqual(gate.evaluate(hasContext: true, focusSeq: 1), .apply)      // recovered
        XCTAssertEqual(gate.evaluate(hasContext: false, focusSeq: 1), .suppress(pendingMissCount: 1)) // counter reset
    }

    func testFlickerPropagatesImmediatelyOnFocusChange() {
        var gate = FocusCapabilityFlickerGate()
        _ = gate.evaluate(hasContext: true, focusSeq: 1)
        // A miss on a DIFFERENT focus session is a genuine focus change → no debounce.
        XCTAssertEqual(gate.evaluate(hasContext: false, focusSeq: 2), .apply)
    }

    func testFlickerAppliesWhenNeverSupported() {
        var gate = FocusCapabilityFlickerGate()
        XCTAssertEqual(gate.evaluate(hasContext: false, focusSeq: 9), .apply)     // nothing to hold
    }

    // MARK: - #8 PromptSectionBudget

    func testBudgetKeepsHighPriorityDropsLow() {
        let sections = [
            PromptSection(name: "ocr", content: String(repeating: "o", count: 100), priority: 20,
                          minChars: 10, maxChars: 100, truncation: .preserveEnd),
            PromptSection(name: "prefix", content: String(repeating: "p", count: 50), priority: 1000,
                          minChars: 0, maxChars: 50, truncation: .preserveEnd),
        ]
        let out = PromptSectionBudget.allocate(sections, totalChars: 60)
        // Prefix (priority 1000) filled first → 50; only 10 left, below ocr.minChars (10 fits exactly).
        XCTAssertEqual(out.first(where: { $0.name == "prefix" })?.content.count, 50)
        XCTAssertEqual(out.first(where: { $0.name == "ocr" })?.content.count, 10)
    }

    func testBudgetDropsSectionBelowMinChars() {
        let sections = [
            PromptSection(name: "prefix", content: String(repeating: "p", count: 55), priority: 1000,
                          minChars: 0, maxChars: 55, truncation: .preserveEnd),
            PromptSection(name: "ocr", content: String(repeating: "o", count: 100), priority: 20,
                          minChars: 20, maxChars: 100, truncation: .preserveEnd),
        ]
        let out = PromptSectionBudget.allocate(sections, totalChars: 60)
        XCTAssertNil(out.first(where: { $0.name == "ocr" }))   // only 5 left < minChars 20 → dropped
        XCTAssertEqual(out.count, 1)
    }

    func testBudgetPreservesOriginalOrderAndUnboundedIsLossless() {
        let sections = [
            PromptSection(name: "a", content: "AAAA", priority: 10, minChars: 0, maxChars: 4, truncation: .preserveStart),
            PromptSection(name: "b", content: "BBBB", priority: 99, minChars: 0, maxChars: 4, truncation: .preserveEnd),
        ]
        let out = PromptSectionBudget.allocate(sections, totalChars: .max)
        XCTAssertEqual(out.map(\.name), ["a", "b"])            // fill priority doesn't reorder output
        XCTAssertEqual(out.map(\.content), ["AAAA", "BBBB"])   // unbounded → nothing trimmed
    }

    // The property the anchored window exists for: while the user types, the KEPT WINDOW'S HEAD must hold
    // still, so each assembled prompt is a strict extension of the last one and the engine's
    // longest-common-prefix KV reuse survives. A plain `.preserveEnd` cut slides one byte per keystroke and
    // diverges at the first token, forcing a cold re-prefill on every fire.
    func testAnchoredTailHeadIsStableAcrossKeystrokes() {
        let maxCost = 1000, anchor = 512
        var heads = Set<String>()
        // Simulate 200 consecutive keystrokes on a draft already past the budget.
        for n in 1500...1700 {
            let draft = String(repeating: "x", count: n - 20) + String(repeating: "y", count: 20)
            let win = PromptSectionBudget.anchoredTail(draft, maxCost: maxCost, anchor: anchor)
            XCTAssertLessThanOrEqual(PromptSectionBudget.cost(win), maxCost)   // never exceeds the cap
            XCTAssertTrue(draft.hasSuffix(win))                                // always the caret-side tail
            heads.insert(String(win.prefix(24)))
        }
        // 201 keystrokes spanning 200 bytes of growth: an unanchored window would produce ~201 distinct
        // heads (one re-prefill each). Anchored to 512, it re-anchors at most once.
        XCTAssertLessThanOrEqual(heads.count, 2, "window head slid \(heads.count) times; anchoring is broken")
    }

    func testAnchoredTailIsLosslessUnderBudgetAndNeverExceedsCap() {
        XCTAssertEqual(PromptSectionBudget.anchoredTail("hello", maxCost: 1000), "hello")   // fits → untouched
        // Rounding the drop UP keeps the window at or below the cap, never above it.
        for n in 900...1100 {
            let s = String(repeating: "z", count: n)
            XCTAssertLessThanOrEqual(PromptSectionBudget.cost(PromptSectionBudget.anchoredTail(s, maxCost: 1000, anchor: 64)), 1000)
        }
    }

    func testBudgetTruncationEnds() {
        let preserveEnd = [PromptSection(name: "x", content: "abcdef", priority: 1, minChars: 0, maxChars: 6, truncation: .preserveEnd)]
        XCTAssertEqual(PromptSectionBudget.allocate(preserveEnd, totalChars: 3).first?.content, "def")
        let preserveStart = [PromptSection(name: "x", content: "abcdef", priority: 1, minChars: 0, maxChars: 6, truncation: .preserveStart)]
        XCTAssertEqual(PromptSectionBudget.allocate(preserveStart, totalChars: 3).first?.content, "abc")
    }

    func testBudgetCostsBytesAndTruncatesOnGraphemeBoundary() {
        // "é" is 2 UTF-8 bytes; " é" (space + é) is 3 bytes. A 2-byte budget can't fit the whole thing,
        // and truncation must not split the multi-byte scalar — it keeps the trailing whole grapheme.
        let s = [PromptSection(name: "x", content: "aé", priority: 1, minChars: 0,
                               maxChars: PromptSectionBudget.cost("aé"), truncation: .preserveEnd)]
        XCTAssertEqual(PromptSectionBudget.cost("aé"), 3)                 // 'a'(1) + 'é'(2)
        XCTAssertEqual(PromptSectionBudget.allocate(s, totalChars: 2).first?.content, "é") // keeps whole 'é', drops 'a'
        XCTAssertNil(PromptSectionBudget.allocate(s, totalChars: 1).first)  // 'é' won't fit in 1 byte → section dropped
    }

    // assemblePrompt keeps prior behavior when the budget isn't constraining, and protects the prefix
    // when it is.
    func testAssemblePromptUnboundedUnchanged() {
        let p = CompletionCoordinator.assemblePrompt(
            prefix: "the quick brown", isLicensed: true,
            instruction: "be terse", styleHint: nil, styleEnabled: false,
            clipboard: nil, clipboardEnabled: false, ocr: nil, ocrEnabled: false)
        XCTAssertEqual(p.prompt, "Context:\nbe terse\n\nText:\nthe quick brown")
    }

    func testAssemblePromptBudgetProtectsPrefix() {
        let bigOCR = String(repeating: "z ", count: 4000)   // ~8000 chars of screen noise
        let p = CompletionCoordinator.assemblePrompt(
            prefix: "my real sentence so far", isLicensed: false,
            instruction: nil, styleHint: nil, styleEnabled: false,
            clipboard: nil, clipboardEnabled: false, ocr: bigOCR, ocrEnabled: true,
            totalChars: 200)
        XCTAssertTrue(p.prompt.hasSuffix("Text:\nmy real sentence so far"))  // caret text never starved
        XCTAssertLessThanOrEqual(p.prompt.count, 260)                        // budget + framing overhead
    }

    // The other half of "never starved": the prefix must not starve the CONTEXT either. It used to
    // declare its own full length as maxChars, so any draft longer than the budget took 100% of it and
    // every context block trimmed to "" — instruction/style/clipboard/OCR silently vanished in long
    // documents and the caller got the bare prefix (the flat-document shape that yields word-salad).
    func testAssemblePromptKeepsContextWhenPrefixOverflowsBudget() {
        let budget = 1000
        let bigPrefix = String(repeating: "a ", count: 5000)   // 10 000 bytes of draft — 10× the budget
        let p = CompletionCoordinator.assemblePrompt(
            prefix: bigPrefix, isLicensed: true,
            instruction: "reply in a friendly tone", styleHint: nil, styleEnabled: false,
            clipboard: nil, clipboardEnabled: false, ocr: nil, ocrEnabled: false,
            totalChars: budget)
        XCTAssertTrue(p.prompt.hasPrefix("Context:\n"))                 // framing survives…
        XCTAssertTrue(p.prompt.contains("reply in a friendly tone"))    // …and so does the instruction
        // The prefix is capped at 65% of the budget: still dominant, no longer unbounded. Asserted as a
        // RANGE, not an exact 650: the window is anchor-quantized (PromptSectionBudget.anchoredTail) so its
        // head holds still while typing, which costs up to one step of kept bytes. The bounds still fail if
        // the cap is removed (unbounded → 10 000) or if the prefix collapses.
        let keptPrefix = p.prompt.components(separatedBy: "\n\nText:\n").last ?? ""
        XCTAssertLessThanOrEqual(PromptSectionBudget.cost(keptPrefix), 650)
        XCTAssertGreaterThan(PromptSectionBudget.cost(keptPrefix), 650 - 650 / 4)
        // Whole prompt stays inside the budget plus the framing the sections aren't charged for.
        XCTAssertLessThanOrEqual(PromptSectionBudget.cost(p.prompt), budget + 64)
    }

    // assemblePrompt reports whether the OCR block SURVIVED, because CompletionCoordinator arms the
    // render-time context-language suppression off that fact: hiding a ghost for "drifting" from screen
    // context that the budget dropped means suppressing on evidence the model was never given.
    func testAssemblePromptReportsWhetherOCRSurvivedTheBudget() {
        let screen = "Aquesta és una conversa en català sobre la feina."
        let fits = CompletionCoordinator.assemblePrompt(
            prefix: "També necesito ", isLicensed: false,
            instruction: nil, styleHint: nil, styleEnabled: false,
            clipboard: nil, clipboardEnabled: false, ocr: screen, ocrEnabled: true,
            totalChars: 2000)
        XCTAssertTrue(fits.ocrKept)
        XCTAssertTrue(fits.prompt.contains(screen))

        // Prefix takes its 65%, the higher-priority (paid) instruction takes the rest → OCR, lowest
        // priority, has nothing left and is dropped. The instruction is sized to exactly the room the
        // prefix leaves: directive blocks are all-or-nothing now (see assemblePrompt), so handing this
        // case an oversized one would just drop it and leave the remainder to OCR, testing nothing.
        let budget = 100
        let draft = String(repeating: "draft ", count: 200)
        let keptPrefix = PromptSectionBudget.anchoredTail(
            CompletionCoordinator.trimmingTrailingInlineWhitespace(draft), maxCost: budget / 100 * 65)
        let instruction = String(repeating: "i", count: budget - PromptSectionBudget.cost(keptPrefix))
        let starved = CompletionCoordinator.assemblePrompt(
            prefix: draft, isLicensed: true,
            instruction: instruction, styleHint: nil, styleEnabled: false,
            clipboard: nil, clipboardEnabled: false, ocr: screen, ocrEnabled: true,
            totalChars: budget)
        XCTAssertFalse(starved.ocrKept)
        XCTAssertFalse(starved.prompt.contains("català"))
        XCTAssertTrue(starved.prompt.contains(instruction))   // the paid block still wins over OCR
    }

    // The style hint used to fill at priority 60 — above clipboard AND above screen context — so under
    // budget pressure a vocabulary nudge crowded out the text the next word is actually ABOUT. It is now
    // the first block dropped.
    func testStyleHintIsDroppedBeforeScreenContext() {
        let style = "Writing style: favours words like alpha; beta; gamma"
        let screen = "the meeting is on Thursday and the venue has changed"
        let tight = CompletionCoordinator.assemblePrompt(
            prefix: "so I ", isLicensed: true,
            instruction: nil, styleHint: style, styleEnabled: true,
            clipboard: nil, clipboardEnabled: false, ocr: screen, ocrEnabled: true,
            totalChars: 80)
        XCTAssertTrue(tight.ocrKept)
        XCTAssertTrue(tight.prompt.contains(screen))
        XCTAssertFalse(tight.prompt.contains("alpha"))
        // Control: with room for both, nothing is dropped and the render order is unchanged.
        let roomy = CompletionCoordinator.assemblePrompt(
            prefix: "so I ", isLicensed: true,
            instruction: nil, styleHint: style, styleEnabled: true,
            clipboard: nil, clipboardEnabled: false, ocr: screen, ocrEnabled: true,
            totalChars: 2000)
        XCTAssertEqual(roomy.prompt, "Context:\n\(style)\n\n\(screen)\n\nText:\nso I")
    }

    // A directive block's meaning lives in its wording, so the budget must never MUTATE one: trimmed to
    // its tail, "Always reply in formal Spanish, never use contractions" becomes the different — and
    // contradictory — instruction "never use contractions". It is taken whole or not at all.
    func testDirectiveBlockIsDroppedWholeNotTruncated() {
        // The prefix takes its 65%, leaving less than the instruction's full length. Old behaviour kept
        // whatever fit from the TAIL — "…ply in formal Spanish, never use contractions".
        let p = CompletionCoordinator.assemblePrompt(
            prefix: String(repeating: "Hola ", count: 40), isLicensed: true,
            instruction: "Always reply in formal Spanish, never use contractions",
            styleHint: nil, styleEnabled: false,
            clipboard: nil, clipboardEnabled: false, ocr: nil, ocrEnabled: false,
            totalChars: 100)
        XCTAssertFalse(p.prompt.contains("never use contractions"))  // no mutated instruction…
        XCTAssertFalse(p.prompt.contains("Context:"))                // …the block is gone entirely
        XCTAssertTrue(p.prompt.hasSuffix("Hola"))                    // bare prefix
    }

    // The prompt budget is derived from the engine's live token cap instead of a hardcoded 6000 that
    // assumed a 4096-token window: the default window is 1024 tokens, so a 6000-byte prompt was
    // front-trimmed by InferenceEngine.generate() — and the front is the `Context:` header plus every
    // context block. Must stay under ~4 bytes/token (English prose) at every picker step.
    func testPromptBudgetFitsInsideTheEngineTokenCap() {
        for tokens in [512, 1024, 2048, 3072] {   // the Settings → Context picker steps
            let budget = CompletionCoordinator.promptBudgetBytes(forContextTokens: tokens)
            XCTAssertLessThan(budget, tokens * 4, "budget must under-fill the window at \(tokens)")
            XCTAssertGreaterThan(budget, tokens, "budget shouldn't be needlessly tiny at \(tokens)")
        }
        // Strictly monotone in the setting, and the old hardcoded 6000 is now out of reach at the default.
        XCTAssertLessThan(CompletionCoordinator.promptBudgetBytes(forContextTokens: 1024), 6000)
        XCTAssertGreaterThan(CompletionCoordinator.promptBudgetBytes(forContextTokens: 3072),
                             CompletionCoordinator.promptBudgetBytes(forContextTokens: 2048))
        // A degenerate/absent setting can never yield a zero or negative budget.
        XCTAssertGreaterThanOrEqual(CompletionCoordinator.promptBudgetBytes(forContextTokens: 0), 256)
    }

    // MARK: - OverlayRenderer pure geometry/colors (RTL clamp + appearance-adaptive palette)

    func testRTLOriginClampsToScreenLeftEdge() {
        // Right edge anchored at the caret when it fits…
        XCTAssertEqual(OverlayRenderer.rtlOriginX(caretMinX: 500, width: 120, screenMinX: 0), 380)
        // …clamped to the screen's minX when the panel would slide off the left bezel.
        XCTAssertEqual(OverlayRenderer.rtlOriginX(caretMinX: 80, width: 120, screenMinX: 0), 0)
        // Multi-monitor: a screen left of the main one has a negative minX — clamp to THAT edge.
        XCTAssertEqual(OverlayRenderer.rtlOriginX(caretMinX: -1400, width: 200, screenMinX: -1440), -1440)
    }

    func testAdaptiveOverlayColors() {
        // Light-mode values are exactly the historical hardcoded ones (no visual change for light users).
        XCTAssertEqual(OverlayRenderer.ghostTextColor(dark: false),
                       NSColor(white: 0.55, alpha: 0.6))
        XCTAssertEqual(OverlayRenderer.hintBackgroundColor(dark: false), NSColor(white: 0.5, alpha: 0.10))
        XCTAssertEqual(OverlayRenderer.hintBorderColor(dark: false), NSColor(white: 0.5, alpha: 0.38))
        XCTAssertEqual(OverlayRenderer.hintLabelColor(dark: false), NSColor(white: 0.42, alpha: 0.95))
        // Dark variants are LIGHTER (legible on dark backgrounds) at comparable alpha.
        XCTAssertGreaterThan(OverlayRenderer.ghostTextColor(dark: true).whiteComponent,
                             OverlayRenderer.ghostTextColor(dark: false).whiteComponent)
        XCTAssertEqual(OverlayRenderer.ghostTextColor(dark: true).alphaComponent, 0.6)
        XCTAssertGreaterThan(OverlayRenderer.hintLabelColor(dark: true).whiteComponent,
                             OverlayRenderer.hintLabelColor(dark: false).whiteComponent)
        XCTAssertGreaterThan(OverlayRenderer.hintBorderColor(dark: true).whiteComponent,
                             OverlayRenderer.hintBorderColor(dark: false).whiteComponent)
    }

    // MARK: - #11 TextDirectionDetector

    func testRTLDetection() {
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("שלום"))      // Hebrew
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("مرحبا"))      // Arabic
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("hello"))
        XCTAssertFalse(TextDirectionDetector.isRightToLeft(""))
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("123 !?"))    // neutral → LTR fallback
        // Nearest-the-caret character wins: RTL word then a trailing English word → LTR.
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("שלום hello"))
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("hello שלום"))
    }

    // MARK: - #10 InsertionStrategySelector

    func testStrategyDefaultsToKeystrokeWhenDisabled() {
        XCTAssertEqual(InsertionStrategySelector.strategy(forChunk: String(repeating: "x", count: 500),
                                                          pasteEnabled: false), .keystroke)
        XCTAssertEqual(InsertionStrategySelector.strategy(forChunk: "a\nb", pasteEnabled: false), .keystroke)
    }

    func testStrategyPastesLongOrMultilineWhenEnabled() {
        XCTAssertEqual(InsertionStrategySelector.strategy(forChunk: "short", pasteEnabled: true), .keystroke)
        XCTAssertEqual(InsertionStrategySelector.strategy(forChunk: "a\nb", pasteEnabled: true), .paste)
        XCTAssertEqual(InsertionStrategySelector.strategy(forChunk: String(repeating: "x", count: 80),
                                                          pasteEnabled: true), .paste)
    }

    // MARK: - #1/#6/#11 TextSanitizer (strip junk, keep the rest — never discard the whole suggestion)

    func testSanitizerStripsJunkButKeepsText() {
        XCTAssertEqual(TextSanitizer.removingControlJunk("bad\u{FFFD}token"), "badtoken")   // lossy glyph dropped
        XCTAssertEqual(TextSanitizer.removingControlJunk("a\u{0007}b"), "ab")                // BEL dropped
        XCTAssertEqual(TextSanitizer.removingControlJunk("line\rone"), "lineone")            // CR dropped
        XCTAssertEqual(TextSanitizer.removingControlJunk("x\u{7F}"), "x")                    // DEL dropped
    }

    func testSanitizerPreservesTabAndNewlineAndCleanText() {
        XCTAssertEqual(TextSanitizer.removingControlJunk("\tindented"), "\tindented")        // tab kept (#1)
        XCTAssertEqual(TextSanitizer.removingControlJunk("line one\nline two"), "line one\nline two")
        XCTAssertEqual(TextSanitizer.removingControlJunk(" the rest of it"), " the rest of it") // untouched, no copy
    }

    // MARK: - #7 InferenceEngineRouter scaffold

    func testRouterForwardsToActiveBackend() {
        let fake = FakeEngine()
        let router = InferenceEngineRouter(llama: fake, foundationModels: FakeEngine(), backend: .llama)
        router.maxWords = 7
        XCTAssertEqual(fake.maxWords, 7)            // tunable write forwarded
        XCTAssertFalse(router.isLoaded)
        try? router.load(modelPath: "/tmp/x")
        XCTAssertTrue(fake.loadCalled)
        XCTAssertTrue(router.isLoaded)
    }

    func testFoundationModelsStubIsUnavailable() {
        let fm = FoundationModelsEngine()
        XCTAssertFalse(fm.isLoaded)
        XCTAssertThrowsError(try fm.load(modelPath: "/tmp/x"))
    }

    private final class FakeEngine: InferenceEngineProtocol {
        private(set) var isLoaded = false
        var stopAtFirstSentence = false
        var maxWords = 0
        var stopAtSentenceAfterWords = 0
        var maxContextTokens = 0
        var modelChatTemplate: String? = nil
        var modelArchitecture: String? = nil
        var modelSupportsChat: Bool = false
        var supportsFIM: Bool = false
        var loadCalled = false
        func load(modelPath: String) throws { loadCalled = true; isLoaded = true }
        func unload() { isLoaded = false }
        func requestCancel() {}
        private(set) var releasedSeqs: [Int32] = []
        func releaseSeq(_ seqID: Int32) { releasedSeqs.append(seqID) }
        func generate(prompt: String, maxTokens: Int,
                      seqID: Int32, params: SamplingParams,
                      requiredPrefix: [UInt8]?,
                      onToken: (String) -> Bool,
                      onSample: ((Float, Bool) -> Void)?) throws {}
    }
}
