// Pure unit tests for the prompt-token budget (InferenceEngine.generationReserve / promptCap), the
// over-cap prompt trim (InferenceEngine.trimToWindow) and its interaction with the KV-reuse decision
// (InferenceEngine.reuseLength). All static and model-free.
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

    // MARK: - Generation reserve / prompt cap

    // The bug: the reserve was a flat 256 while /v1 admits max_tokens up to 2048, so a prompt trimmed
    // to the cap plus its own generated tokens overran the 4096 KV pool and llama_decode failed
    // mid-stream (HTTP 500). The cap must leave room for the tokens the call will actually produce.
    func testPromptCapLeavesRoomForRequestedGeneration() {
        let nCtx = 4096
        for maxTokens in [1, 16, 24, 256, 512, 1024, 2048] {
            let cap = InferenceEngine.promptCap(nCtx: nCtx, maxTokens: maxTokens, maxContextTokens: 4096)
            XCTAssertLessThanOrEqual(cap + maxTokens, nCtx,
                                     "prompt cap + max_tokens overruns n_ctx at maxTokens=\(maxTokens)")
        }
    }

    func testPromptCapAccountsForResidentGhostSequence() {
        let resident = InferenceEngine.residentTokenCount(
            nPastBySeq: [0: 1024, 1: 128, 2: 0],
            excluding: 1
        )
        let available = 4096 - resident
        let cap = InferenceEngine.promptCap(
            nCtx: available,
            maxTokens: 2048,
            maxContextTokens: 4096
        )

        XCTAssertEqual(resident, 1024)
        XCTAssertLessThanOrEqual(resident + cap + 2048, 4096)
        XCTAssertLessThan(cap, 1984,
                          "the API prompt must be rejected/trimmed before it overcommits unified KV")
    }

    func testResidentAccountingExcludesCurrentSequenceReuse() {
        XCTAssertEqual(
            InferenceEngine.residentTokenCount(
                nPastBySeq: [0: 1024, 1: 1984, 2: 64],
                excluding: 1
            ),
            1088
        )
    }

    func testResidentCapacityCannotUsePromptCapFloorToOvercommit() {
        let resident = 3_900
        let available = 4_096 - resident
        let reserve = InferenceEngine.generationReserve(maxTokens: 24)
        XCTAssertLessThan(available, reserve + 8,
                          "generate must reject before promptCap's arithmetic floor can be used")
    }

    func testGhostBudgetIsUnchangedByTheReserveFix() {
        // Ghost generates ~16-24 tokens, so the 256 floor still binds and the shipping cap stays 3840
        // — the anchored-trim tests above are written against that number.
        XCTAssertEqual(InferenceEngine.generationReserve(maxTokens: 24), 256)
        XCTAssertEqual(InferenceEngine.promptCap(nCtx: 4096, maxTokens: 24, maxContextTokens: 4096), 3840)
    }

    func testUserContextWindowStillBinds() {
        // "Context window size" below the derived cap wins — a deliberate user choice, not a failure.
        XCTAssertEqual(InferenceEngine.promptCap(nCtx: 4096, maxTokens: 16, maxContextTokens: 512), 512)
    }

    func testMaxTokensCeilingStillLeavesAUsableWindow() {
        // The routes clamp max_tokens to 2048. At that ceiling the remaining window must stay above
        // minPromptWindow, or every long-prompt request would be refused outright.
        XCTAssertGreaterThanOrEqual(4096 - InferenceEngine.generationReserve(maxTokens: 2048),
                                    InferenceEngine.minPromptWindow)
        // Past the ceiling the window IS exhausted — that's the case generate() refuses instead of
        // front-trimming the prompt to a stub.
        XCTAssertLessThan(4096 - InferenceEngine.generationReserve(maxTokens: 4000),
                          InferenceEngine.minPromptWindow)
    }

    func testPromptCapNeverGoesNegative() {
        // An absurd max_tokens must not produce a negative cap that the trim would then misuse.
        XCTAssertGreaterThanOrEqual(
            InferenceEngine.promptCap(nCtx: 4096, maxTokens: 100_000, maxContextTokens: 4096), 8)
    }

    func testEmptyPromptTokenizationHasStableNonNilStorage() {
        let input = InferenceEngine.tokenizationInput("")
        XCTAssertEqual(input.byteCount, 0)
        XCTAssertEqual(input.storage, [0],
                       "llama_tokenize must receive stable storage even for a zero-byte prompt")
    }

    func testSamplingFastPathDecision() {
        XCTAssertFalse(InferenceEngine.requiresCandidateSampling(
            hasSampleObserver: false,
            hasRequiredPrefix: false
        ))
        XCTAssertTrue(InferenceEngine.requiresCandidateSampling(
            hasSampleObserver: true,
            hasRequiredPrefix: false
        ))
        XCTAssertTrue(InferenceEngine.requiresCandidateSampling(
            hasSampleObserver: false,
            hasRequiredPrefix: true
        ))
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
