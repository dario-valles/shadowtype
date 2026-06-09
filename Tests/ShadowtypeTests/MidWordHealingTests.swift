import XCTest
@testable import Shadowtype

// Tier 2a pure foundations: mid-word split/strip and byte-level required-prefix admissibility.
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

    func testSplitHandlesNonLatinStem() {
        // CJK has no spaces, but the head/stem split still works on the trailing run.
        let s = MidWordHealing.split(prefix: "資料はもう準")
        XCTAssertEqual(s?.stem, "資料はもう準")  // all word chars, no boundary → whole thing is the stem
    }

    // MARK: strip

    func testStripsRegeneratedStem() {
        XCTAssertEqual(MidWordHealing.strip(stem: "gre", from: "great"), "at")
        XCTAssertEqual(MidWordHealing.strip(stem: "develo", from: "developer"), "per")
        XCTAssertEqual(MidWordHealing.strip(stem: "great", from: "great"), "")  // complete word
    }

    func testStripFailsSafeOnMismatch() {
        XCTAssertNil(MidWordHealing.strip(stem: "gre", from: "asy"))  // constraint miss → don't glue
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
