// OverlayEmitDedupTests — pure coverage for the second overlay-emit gate (sibling of
// OverlayStabilityGate). Documents the rules that kill the "shows twice / show then show same"
// pattern when a context re-fire or any post-clear path regenerates the same text on the same
// focus session within a short window. No AX/model/overlay runtime — runs under `swift test`.
import XCTest
@testable import Shadowtype

final class OverlayEmitDedupTests: XCTestCase {

    func testNoLastStateNeverDrops() {
        XCTAssertFalse(OverlayEmitDedup.shouldDrop(last: nil, text: "hello", focusSeq: 1, now: 100,
                                                   presented: true))
    }

    func testIdenticalTextSameFocusWithinWindowDrops() {
        let last = OverlayEmitDedup.State(text: "hello world", focusSeq: 7, emittedAt: 100)
        XCTAssertTrue(OverlayEmitDedup.shouldDrop(
            last: last, text: "hello world", focusSeq: 7, now: 100.1, presented: true))
    }

    func testDifferentTextNeverDrops() {
        let last = OverlayEmitDedup.State(text: "hello world", focusSeq: 7, emittedAt: 100)
        XCTAssertFalse(OverlayEmitDedup.shouldDrop(
            last: last, text: "hello there", focusSeq: 7, now: 100.1, presented: true))
    }

    func testDifferentFocusSessionNeverDrops() {
        // A new focus session means a new field/app: the same text in a new context is a fresh
        // suggestion, not a duplicate emission.
        let last = OverlayEmitDedup.State(text: "hello world", focusSeq: 7, emittedAt: 100)
        XCTAssertFalse(OverlayEmitDedup.shouldDrop(
            last: last, text: "hello world", focusSeq: 8, now: 100.1, presented: true))
    }

    func testWindowExpiredAllowsRe_emit() {
        // After the TTL elapses the user is genuinely waiting for a fresh suggestion to surface;
        // suppressing it would feel like the app is silently ignoring them.
        let last = OverlayEmitDedup.State(text: "hello world", focusSeq: 7, emittedAt: 100)
        XCTAssertFalse(OverlayEmitDedup.shouldDrop(
            last: last, text: "hello world", focusSeq: 7,
            now: 100 + OverlayEmitDedup.windowSeconds + 0.001, presented: true))
    }

    func testJustInsideWindowStillDrops() {
        let last = OverlayEmitDedup.State(text: "hello world", focusSeq: 7, emittedAt: 100)
        XCTAssertTrue(OverlayEmitDedup.shouldDrop(
            last: last, text: "hello world", focusSeq: 7,
            now: 100 + OverlayEmitDedup.windowSeconds - 0.001, presented: true))
    }

    func testEmptyTextDedupsLikeAnyOtherString() {
        // The gate is text-equality based; not a special-case for emptiness. The caller is
        // responsible for not emitting empty text in the first place.
        let last = OverlayEmitDedup.State(text: "", focusSeq: 7, emittedAt: 100)
        XCTAssertTrue(OverlayEmitDedup.shouldDrop(last: last, text: "", focusSeq: 7, now: 100.1,
                                                  presented: true))
    }

    // --- presence gate (phantom-accept guard) ---------------------------------------------------

    func testNotPresentedNeverDrops() {
        // The dedup record can outlive the on-screen ghost — it is intentionally kept across a context
        // re-fire's clearSuggestion(), which already called overlay.hide(). When nothing is presented a
        // "re-show" is actually the FIRST show; suppressing it would leave suggestionVisible=true over an
        // empty field, so Tab/→ would insert a suggestion the user never saw (phantom accept). Must NOT drop.
        let last = OverlayEmitDedup.State(text: "hello world", focusSeq: 7, emittedAt: 100)
        XCTAssertFalse(OverlayEmitDedup.shouldDrop(
            last: last, text: "hello world", focusSeq: 7, now: 100.1, presented: false))
    }

    func testPresentedDuplicateStillDrops() {
        // The flicker-kill still holds: an identical re-emit WHILE the ghost is on screen is a redundant
        // repaint and is dropped. (This is the testIdenticalText… case, asserted here against the
        // presence gate to lock the pairing: presented ⇒ drop, not-presented ⇒ show.)
        let last = OverlayEmitDedup.State(text: "hello world", focusSeq: 7, emittedAt: 100)
        XCTAssertTrue(OverlayEmitDedup.shouldDrop(
            last: last, text: "hello world", focusSeq: 7, now: 100.1, presented: true))
    }

    func testWindowConstantIsActionable() {
        // Guard against a future bump-down that would re-introduce the cancel→regenerate flicker on
        // M-series hardware (the round-trip typically lands in the 100–300 ms range).
        XCTAssertGreaterThanOrEqual(OverlayEmitDedup.windowSeconds, 0.4)
        XCTAssertLessThanOrEqual(OverlayEmitDedup.windowSeconds, 1.5)
    }
}
