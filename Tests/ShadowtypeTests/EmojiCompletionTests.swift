// EmojiCompletion — built-in :shortcode: -> emoji lookup (FR-EM-1). Pure logic.
import XCTest
@testable import Shadowtype

final class EmojiCompletionTests: XCTestCase {
    private let emoji = EmojiCompletion()

    // MARK: - currentQuery

    func testCurrentQueryAfterColon() {
        XCTAssertEqual(emoji.currentQuery(prefix: "I am :smi"), "smi")
        XCTAssertEqual(emoji.currentQuery(prefix: ":fire"), "fire")
        XCTAssertEqual(emoji.currentQuery(prefix: "lol :+1"), "+1")
    }

    func testCurrentQueryLowercases() {
        XCTAssertEqual(emoji.currentQuery(prefix: "great :FIRE"), "fire")
    }

    func testCurrentQueryNilCases() {
        XCTAssertNil(emoji.currentQuery(prefix: "no colon here"))
        XCTAssertNil(emoji.currentQuery(prefix: "trailing colon:"))   // empty query
        XCTAssertNil(emoji.currentQuery(prefix: ":smile: done"))      // space breaks the run
        XCTAssertNil(emoji.currentQuery(prefix: "url http://x"))      // '/' is not a shortcode char
        XCTAssertNil(emoji.currentQuery(prefix: ""))
    }

    func testCurrentQueryUsesLastColon() {
        XCTAssertEqual(emoji.currentQuery(prefix: ":smile: then :joy"), "joy")
    }

    // MARK: - isTrigger

    func testIsTrigger() {
        XCTAssertTrue(emoji.isTrigger(prefix: "hey :sm"))
        XCTAssertFalse(emoji.isTrigger(prefix: "hey there"))
        XCTAssertFalse(emoji.isTrigger(prefix: "closed :smile:"))
    }

    // MARK: - matches

    func testMatchesExactFirst() {
        let m = emoji.matches(prefix: ":fire", limit: 5)
        XCTAssertFalse(m.isEmpty)
        XCTAssertEqual(m.first?.shortcode, "fire")
        XCTAssertEqual(m.first?.emoji, "🔥")
    }

    func testMatchesPrefixBeatsSubstring() {
        // "smi" prefixes smile/smiley/smirk before substring-only hits.
        let m = emoji.matches(prefix: ":smi", limit: 10)
        XCTAssertTrue(m.contains { $0.shortcode == "smile" })
        let codes = m.map { $0.shortcode }
        if let smile = codes.firstIndex(of: "smile"),
           let firstNonPrefix = codes.firstIndex(where: { !$0.hasPrefix("smi") }) {
            XCTAssertLessThan(smile, firstNonPrefix)
        }
    }

    func testMatchesRespectsLimit() {
        XCTAssertLessThanOrEqual(emoji.matches(prefix: ":s", limit: 3).count, 3)
        XCTAssertTrue(emoji.matches(prefix: ":s", limit: 0).isEmpty)
    }

    func testMatchesEmptyForNonTrigger() {
        XCTAssertTrue(emoji.matches(prefix: "no trigger", limit: 5).isEmpty)
        XCTAssertTrue(emoji.matches(prefix: ":zzzzznotacode", limit: 5).isEmpty)
    }

    func testMatchesNoDuplicates() {
        let m = emoji.matches(prefix: ":heart", limit: 20)
        XCTAssertEqual(Set(m.map { $0.shortcode }).count, m.count)
    }
}
