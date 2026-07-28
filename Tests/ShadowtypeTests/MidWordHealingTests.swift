import XCTest
@testable import Shadowtype

// Tier 2a pure foundations: mid-word splitting and byte-level required-prefix admissibility.
final class MidWordHealingTests: XCTestCase {

    // MARK: split

    func testSplitsMidWord() {
        XCTAssertEqual(MidWordHealing.split(prefix: "the weather is gre"),
                       .init(head: "the weather is ", stem: "gre"))
        XCTAssertEqual(MidWordHealing.split(prefix: "develo"),
                       .init(head: "", stem: "develo"))
    }

    func testNoSplitAtWordBoundaryOrPunct() {
        XCTAssertNil(MidWordHealing.split(prefix: "the weather is "))   // trailing space
        XCTAssertNil(MidWordHealing.split(prefix: "done."))            // ends in punctuation
        XCTAssertNil(MidWordHealing.split(prefix: ""))
        XCTAssertNil(MidWordHealing.split(prefix: "don'"))            // apostrophe boundary
    }

    func testSplitRejectsOverlongStem() {
        XCTAssertNil(MidWordHealing.split(prefix: String(repeating: "a", count: 25), maxStem: 24))
    }

    func testSplitCapsSpacelessScriptStem() {
        // CJK has no spaces, so the trailing word-char run is the whole clause since the last full
        // stop — healing all of it makes the model re-emit text the user already typed, and every
        // stem-consuming token counts against maxTokens (16 at the medium preset), so a 15-char stem
        // ate most of the generation budget. Only the last few characters are healed.
        // WAS: stem == "資料はもう準" (the entire run).
        let s = MidWordHealing.split(prefix: "資料はもう準")
        XCTAssertEqual(s?.stem, "はもう準")
        XCTAssertEqual(s?.head, "資料")
        XCTAssertEqual(s?.stem.count, MidWordHealing.maxSpacelessStem)
        // …and head + stem still reconstructs the prefix exactly (the engine strips the stem back out).
        XCTAssertEqual((s?.head ?? "") + (s?.stem ?? ""), "資料はもう準")
    }

    func testSplitCapsThaiStemAndNeverRejectsIt() {
        // A long Thai run must be capped, not rejected by the maxStem rule — whitespace never breaks
        // it, so `maxStem` would refuse to heal every Thai caret past 24 chars.
        let prefix = "สวัสดีครับผมชื่อ"
        let s = MidWordHealing.split(prefix: prefix)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.stem.count, MidWordHealing.maxSpacelessStem)
        XCTAssertEqual((s?.head ?? "") + (s?.stem ?? ""), prefix)
    }

    func testSplitShorterThanTheSpacelessCapIsUnchanged() {
        let s = MidWordHealing.split(prefix: "これは準")
        XCTAssertEqual(s?.stem, "これは準")   // 4 chars — already at the cap, nothing trimmed
        XCTAssertEqual(s?.head, "")
    }

    func testLatinStemStillRejectedWhenOverlong() {
        // The spaceless cap must not leak into Latin: a 25-char Latin run is still a complete word,
        // and healing it burns the constraint for no gain.
        XCTAssertNil(MidWordHealing.split(prefix: "the " + String(repeating: "a", count: 25)))
    }

    // MARK: required-prefix admissibility (byte level)

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testAdmissibleWhenNoRemaining() {
        XCTAssertTrue(RequiredPrefix.isAdmissible(tokenBytes: bytes("anything")[...], remaining: [][...]))
    }

    func testAdmissibleTokenCompletesStemAndContinues() {
        // remaining "gre", token "great" starts with the whole stem → admissible.
        XCTAssertTrue(RequiredPrefix.isAdmissible(tokenBytes: bytes("great")[...], remaining: bytes("gre")[...]))
    }

    func testAdmissibleTokenIsProperPrefixOfStem() {
        // remaining "gre", token "gr" is a prefix of the stem → admissible (more stem to come).
        XCTAssertTrue(RequiredPrefix.isAdmissible(tokenBytes: bytes("gr")[...], remaining: bytes("gre")[...]))
    }

    func testInadmissibleDivergentToken() {
        XCTAssertFalse(RequiredPrefix.isAdmissible(tokenBytes: bytes("asy")[...], remaining: bytes("gre")[...]))
    }

    func testEmptyTokenInadmissibleWhileStemPending() {
        // EOG / pure-control token (no bytes) must not be sampled before the stem is reproduced.
        XCTAssertFalse(RequiredPrefix.isAdmissible(tokenBytes: [][...], remaining: bytes("gre")[...]))
        // …but once the stem is satisfied it's fine (it can end generation).
        XCTAssertTrue(RequiredPrefix.isAdmissible(tokenBytes: [][...], remaining: [][...]))
    }

    func testAdmissiblePartialUTF8Byte() {
        // A token carrying only the FIRST byte of a 3-byte CJK char must be admitted (byte-level).
        let stem = bytes("資")            // 3 bytes: E8 B3 87
        let firstByte = ArraySlice(stem.prefix(1))
        XCTAssertTrue(RequiredPrefix.isAdmissible(tokenBytes: firstByte, remaining: stem[...]))
        // A String compare would have rejected this — the assertion guards the byte-level contract.
    }

    func testAdvanceConsumesAndSatisfies() {
        XCTAssertEqual(RequiredPrefix.advanced(remaining: bytes("gre"), byEmitting: bytes("gr")[...]), bytes("e"))
        XCTAssertEqual(RequiredPrefix.advanced(remaining: bytes("gre"), byEmitting: bytes("great")[...]), [])
        XCTAssertEqual(RequiredPrefix.advanced(remaining: bytes("gre"), byEmitting: bytes("gre")[...]), [])
    }
}
