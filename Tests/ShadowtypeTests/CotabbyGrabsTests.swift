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
        XCTAssertEqual(p, "Context:\nbe terse\n\nText:\nthe quick brown")
    }

    func testAssemblePromptBudgetProtectsPrefix() {
        let bigOCR = String(repeating: "z ", count: 4000)   // ~8000 chars of screen noise
        let p = CompletionCoordinator.assemblePrompt(
            prefix: "my real sentence so far", isLicensed: false,
            instruction: nil, styleHint: nil, styleEnabled: false,
            clipboard: nil, clipboardEnabled: false, ocr: bigOCR, ocrEnabled: true,
            totalChars: 200)
        XCTAssertTrue(p.hasSuffix("Text:\nmy real sentence so far"))   // caret text never starved
        XCTAssertLessThanOrEqual(p.count, 260)                         // budget + framing overhead
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
        func generate(prompt: String, maxTokens: Int,
                      seqID: Int32, params: SamplingParams,
                      requiredPrefix: [UInt8]?,
                      onToken: (String) -> Bool,
                      onSample: ((Float, Bool) -> Void)?) throws {}
    }
}
