// Pure unit tests for the over-cap prompt trim (InferenceEngine.trimToWindow) and its interaction
// with the KV-reuse decision (InferenceEngine.reuseLength). Both are static and model-free.
//
// The two bugs these pin down:
//  1. the old `tokens.suffix(cap)` dropped the BOS that tokenize(addSpecial: true) prepends —
//     Gemma-3, the shipping default model, is trained with a mandatory BOS;
//  2. that same suffix slid the window one token per keystroke, so the prompt head changed on every
//     fire, reuseLength() returned 0 and every keystroke in a long document paid a cold prefill.
import XCTest
@testable import Shadowtype

final class EngineTrimTests: XCTestCase {

    // A synthetic prompt: BOS at slot 0, then `body` distinct tokens (1, 2, 3, ...).
    private func prompt(bodyCount: Int, bos: Int32 = 2) -> [Int32] {
        [bos] + (1...bodyCount).map { Int32($0) }
    }

    // MARK: - Under the cap: untouched

    func testNoTrimWhenWithinCap() {
        let toks = prompt(bodyCount: 99)   // 100 tokens
        XCTAssertEqual(InferenceEngine.trimToWindow(toks, cap: 100, keepFirst: true), toks)
        XCTAssertEqual(InferenceEngine.trimToWindow(toks, cap: 4096, keepFirst: true), toks)
    }

    // MARK: - BOS preservation (FIX 3)

    func testTrimKeepsBOSAtSlotZero() {
        let toks = prompt(bodyCount: 4999)   // 5000 tokens, BOS = 2
        let out = InferenceEngine.trimToWindow(toks, cap: 3840, keepFirst: true)
        XCTAssertEqual(out.first, 2, "BOS must survive the front-trim")
        // Slot 1 onwards is a contiguous tail of the original body — the trim only drops from the
        // front, it never reorders or gaps the kept context.
        let tail = Array(out.dropFirst())
        XCTAssertEqual(tail, Array(toks.suffix(tail.count)))
    }

    func testTrimWithoutBOSIsAPlainTail() {
        // A vocab that prepends no BOS gets the pre-fix behaviour: a pure suffix (still anchored).
        let toks = (1...5000).map { Int32($0) }
        let out = InferenceEngine.trimToWindow(toks, cap: 3840, keepFirst: false)
        XCTAssertEqual(out, Array(toks.suffix(out.count)))
        XCTAssertLessThanOrEqual(out.count, 3840)
    }

    // MARK: - Cap is never exceeded (the anchor rounds the DROP up, not down)

    func testResultNeverExceedsCap() {
        // Sweep the boundary region: the anchor must never keep MORE than `cap` tokens, or the
        // n_ctx head-room the cap protects (genReserve) is gone and llama_decode fails mid-stream.
        for count in 3800...4200 {
            let toks = prompt(bodyCount: count - 1)
            let out = InferenceEngine.trimToWindow(toks, cap: 3840, keepFirst: true)
            XCTAssertLessThanOrEqual(out.count, 3840, "cap blown at count=\(count)")
        }
    }

    func testTinyCapStillProducesAValidWindow() {
        // Degenerate cap (nCtx - genReserve floor). The anchor scales down instead of eating the
        // whole window, and the result still fits and still starts with BOS.
        let toks = prompt(bodyCount: 199)
        let out = InferenceEngine.trimToWindow(toks, cap: 8, keepFirst: true)
        XCTAssertLessThanOrEqual(out.count, 8)
        XCTAssertGreaterThan(out.count, 1)
        XCTAssertEqual(out.first, 2)
    }

    // MARK: - Anchoring (FIX 4): the head is byte-stable between re-anchors

    func testHeadIsStableAcrossKeystrokes() {
        // Simulate typing: the prompt grows one token at a time past the cap. Within one anchor
        // step the trimmed head must be IDENTICAL, otherwise reuseLength collapses.
        let cap = 3840
        let anchor = InferenceEngine.trimAnchor
        let startCount = 4001                                   // prompt(bodyCount: 4000).count
        // Tokens that can still be typed before the drop count crosses the next multiple of `anchor`.
        let room = anchor - ((startCount - cap) % anchor)
        let base = InferenceEngine.trimToWindow(prompt(bodyCount: 4000), cap: cap, keepFirst: true)
        for extra in 1...room {
            let out = InferenceEngine.trimToWindow(prompt(bodyCount: 4000 + extra), cap: cap, keepFirst: true)
            XCTAssertEqual(Array(out.prefix(8)), Array(base.prefix(8)),
                           "head moved after \(extra) more tokens — the window is sliding again")
        }
    }

    func testReuseSurvivesTypingAndOnlyResetsAtTheReAnchor() {
        // The real regression: cached vs. next-keystroke prompt. With a sliding window reuse was 0 on
        // every fire (cold prefill per keystroke); anchored, the whole cached prefix is reused until
        // the window re-anchors.
        let cap = 3840
        let cached = InferenceEngine.trimToWindow(prompt(bodyCount: 4000), cap: cap, keepFirst: true)
        let next = InferenceEngine.trimToWindow(prompt(bodyCount: 4001), cap: cap, keepFirst: true)
        XCTAssertEqual(InferenceEngine.reuseLength(cached: cached, new: next), cached.count,
                       "one more typed token must reuse the entire cached prefix")

        // Walk a full anchor step forward: exactly ONE fire loses the cached prefix in that whole
        // span, instead of one per keystroke. (At the re-anchor reuse drops to 1, not 0 — the BOS
        // still matches — which is a seq_rm above slot 0, i.e. a cold prefill in all but name.)
        var reAnchors = 0
        var prev = cached
        for extra in 1...(InferenceEngine.trimAnchor + 1) {
            let cur = InferenceEngine.trimToWindow(prompt(bodyCount: 4000 + extra), cap: cap, keepFirst: true)
            if InferenceEngine.reuseLength(cached: prev, new: cur) < prev.count { reAnchors += 1 }
            prev = cur
        }
        XCTAssertEqual(reAnchors, 1,
                       "expected exactly one re-anchor per \(InferenceEngine.trimAnchor) tokens typed")
    }

    func testUnanchoredSuffixWouldHaveResetEveryKeystroke() {
        // Control case documenting the bug: the old `suffix(cap)` shifts the head every keystroke,
        // so reuseLength is 0 every time. This is what the anchor buys us over.
        let cap = 3840
        let a = Array(prompt(bodyCount: 4000).suffix(cap))
        let b = Array(prompt(bodyCount: 4001).suffix(cap))
        XCTAssertEqual(InferenceEngine.reuseLength(cached: a, new: b), 0)
        XCTAssertNotEqual(a.first, 2, "and the old path dropped BOS too")
    }
}
