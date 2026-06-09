// OverlayRefireDecisionTests — pure coverage for the third overlay-emit gate. Documents the
// monotonic re-fire rule (hold or extend, never replace) that kills the mid-pause "ghost A →
// ghost B" flicker the user reported. No AX/model/overlay runtime — runs under `swift test`.
import XCTest
@testable import Shadowtype

final class OverlayRefireDecisionTests: XCTestCase {

    func testEmptyVisibleDiscardsSoNormalPathRuns() {
        // No ghost on screen yet → the per-token branch should fall through to its normal render
        // (the re-fire hold flag is irrelevant when there is nothing to hold).
        XCTAssertEqual(OverlayRefireDecision.decide(visible: "", snapshot: "hello"), .discard)
    }

    func testIdenticalTextHolds() {
        // Model is regenerating the exact same text — silent hold; no repaint.
        XCTAssertEqual(OverlayRefireDecision.decide(visible: "hello world", snapshot: "hello world"), .hold)
    }

    func testSnapshotIsPrefixOfVisibleHolds() {
        // Mid-stream the new generation has produced "L", "Lo", "Lor" toward the held "Lorem ipsum"
        // — these are all prefixes of the visible text, so hold without flicker.
        XCTAssertEqual(OverlayRefireDecision.decide(visible: "Lorem ipsum", snapshot: "L"), .hold)
        XCTAssertEqual(OverlayRefireDecision.decide(visible: "Lorem ipsum", snapshot: "Lorem"), .hold)
    }

    func testVisibleIsPrefixOfSnapshotExtends() {
        // Model is extending the visible ghost: "hello" → "hello world". Commit the longer text.
        XCTAssertEqual(OverlayRefireDecision.decide(visible: "hello", snapshot: "hello world"), .renderExtension)
    }

    func testDivergentDiscards() {
        // Neither is a prefix of the other — replacing would be the dominant mid-pause flicker
        // ("ghost A → ghost B"). Silently discard; keep the visible ghost.
        XCTAssertEqual(OverlayRefireDecision.decide(visible: "hello world", snapshot: "hi there"), .discard)
        XCTAssertEqual(OverlayRefireDecision.decide(visible: "hello world", snapshot: "hello there"), .discard)
    }

    func testEmptySnapshotHoldsVisible() {
        // No tokens yet on the new stream → there is nothing to render; hold the existing ghost.
        XCTAssertEqual(OverlayRefireDecision.decide(visible: "hello world", snapshot: ""), .hold)
    }

    func testCaseSensitiveDivergenceDiscards() {
        // Casing differences are real divergence (the model wrote different text) — discard.
        XCTAssertEqual(OverlayRefireDecision.decide(visible: "Hello", snapshot: "hello world"), .discard)
    }

    func testUnicodeExtensionWorks() {
        // The decision is on String prefix semantics; multi-byte content must extend correctly.
        XCTAssertEqual(OverlayRefireDecision.decide(visible: "café", snapshot: "café au lait"), .renderExtension)
        XCTAssertEqual(OverlayRefireDecision.decide(visible: "café", snapshot: "café"), .hold)
    }
}
