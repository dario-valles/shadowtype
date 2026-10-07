// Snippets — `;name` trigger detection, name matching, placeholder expansion, preview, and the
// replacement lengths accept hands the Injector. Pure logic; the clock/locale/time zone are injected.
import XCTest
@testable import Shadowtype

final class SnippetsTests: XCTestCase {
    private let sig = Snippet(name: "sig", expansion: "Best,\nDarío Vallés\nRental Ninja")
    private let sig2 = Snippet(name: "sig2", expansion: "Cheers,\nD")
    private let addr = Snippet(name: "addr", expansion: "1 Main St")
    private let posix = Locale(identifier: "en_US_POSIX")
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-10-07 14:05:00 UTC
    private let fixedNow = Date(timeIntervalSince1970: 1_791_381_900)

    // MARK: - Trigger detection

    func testCurrentQueryAtStartAndAfterWhitespace() {
        XCTAssertEqual(SnippetTrigger.currentQuery(prefix: ";sig"), "sig")
        XCTAssertEqual(SnippetTrigger.currentQuery(prefix: "Thanks! ;sig"), "sig")
        XCTAssertEqual(SnippetTrigger.currentQuery(prefix: "line one\n;addr"), "addr")
        XCTAssertEqual(SnippetTrigger.currentQuery(prefix: "tab\t;sig-es"), "sig-es")
    }

    // The sigil must start a token: glued semicolons (code, HTML entities, "a;b") never arm.
    func testSemicolonMidTokenDoesNotTrigger() {
        XCTAssertNil(SnippetTrigger.currentQuery(prefix: "let x = 1;sig"))
        XCTAssertNil(SnippetTrigger.currentQuery(prefix: "a&nbsp;sig"))
        XCTAssertNil(SnippetTrigger.currentQuery(prefix: "foo;bar"))
        XCTAssertFalse(SnippetTrigger.isTrigger(prefix: "word;sig"))
    }

    func testQueryNilCases() {
        XCTAssertNil(SnippetTrigger.currentQuery(prefix: ""))
        XCTAssertNil(SnippetTrigger.currentQuery(prefix: "no trigger here"))
        XCTAssertNil(SnippetTrigger.currentQuery(prefix: "ends with ;"))        // empty name
        XCTAssertNil(SnippetTrigger.currentQuery(prefix: ";sig "))              // a space closes the run
        XCTAssertNil(SnippetTrigger.currentQuery(prefix: "this; that"))         // ordinary prose
        XCTAssertNil(SnippetTrigger.currentQuery(prefix: ";si.g"))              // non-name char
        XCTAssertNil(SnippetTrigger.currentQuery(prefix: ";" + String(repeating: "a", count: 33)))
    }

    // `:` is the emoji trigger and must never arm a snippet, and vice versa.
    func testNoCollisionWithEmojiTrigger() {
        let emoji = EmojiCompletion()
        XCTAssertNil(SnippetTrigger.currentQuery(prefix: "hey :smile"))
        XCTAssertFalse(emoji.isTrigger(prefix: "hey ;smile"))
        XCTAssertNil(SnippetTrigger.match(prefix: "hey :sig", snippets: [sig], now: fixedNow))
    }

    func testQueryKeepsTypedCasing() {
        XCTAssertEqual(SnippetTrigger.currentQuery(prefix: ";SIG"), "SIG")
    }

    // MARK: - Name normalization

    func testNormalizedName() {
        XCTAssertEqual(SnippetTrigger.normalizedName("  Sig "), "sig")
        XCTAssertEqual(SnippetTrigger.normalizedName("sig_es-2"), "sig_es-2")
        XCTAssertEqual(SnippetTrigger.normalizedName("año"), "año")
        XCTAssertNil(SnippetTrigger.normalizedName(""))
        XCTAssertNil(SnippetTrigger.normalizedName("my sig"))
        XCTAssertNil(SnippetTrigger.normalizedName(";sig"))
        XCTAssertNil(SnippetTrigger.normalizedName(String(repeating: "a", count: 33)))
    }

    // MARK: - Matching

    func testExactMatchIsCaseInsensitive() {
        XCTAssertEqual(SnippetTrigger.bestMatch(query: "sig", in: [sig, addr]), sig)
        XCTAssertEqual(SnippetTrigger.bestMatch(query: "SiG", in: [sig, addr]), sig)
    }

    func testExactMatchBeatsLongerPrefixSibling() {
        XCTAssertEqual(SnippetTrigger.bestMatch(query: "sig", in: [sig2, sig]), sig)
    }

    func testUniquePrefixMatches() {
        XCTAssertEqual(SnippetTrigger.bestMatch(query: "ad", in: [sig, addr]), addr)
        XCTAssertEqual(SnippetTrigger.bestMatch(query: "s", in: [sig, addr]), sig)
    }

    func testAmbiguousOrMissingPrefixMatchesNothing() {
        XCTAssertNil(SnippetTrigger.bestMatch(query: "si", in: [sig, sig2]))
        XCTAssertNil(SnippetTrigger.bestMatch(query: "zzz", in: [sig, addr]))
        XCTAssertNil(SnippetTrigger.bestMatch(query: "", in: [sig]))
    }

    func testMatchEndToEnd() {
        let match = SnippetTrigger.match(prefix: "Thanks a lot ;Sig", snippets: [sig, addr], now: fixedNow)
        XCTAssertEqual(match?.name, "sig")
        XCTAssertEqual(match?.expansion, "Best,\nDarío Vallés\nRental Ninja")
        XCTAssertEqual(match?.typedRun, ";Sig")
        XCTAssertNil(SnippetTrigger.match(prefix: ";sig", snippets: [], now: fixedNow))
    }

    // MARK: - Replacement length (what accept deletes before the caret)

    func testReplacementLengthsCoverSigilAndTypedName() {
        let match = SnippetTrigger.match(prefix: "x ;ad", snippets: [addr], now: fixedNow)
        XCTAssertEqual(match?.replaceUTF16Length, 3)          // ";ad" — the typed prefix, not "addr"
        XCTAssertEqual(match?.replaceKeystrokeCount, 3)
    }

    func testReplacementLengthsForNonASCIIName() {
        let snippet = Snippet(name: "año", expansion: "Feliz año")
        let precomposed = SnippetTrigger.match(prefix: ";año", snippets: [snippet], now: fixedNow)
        XCTAssertEqual(precomposed?.replaceUTF16Length, 4)
        XCTAssertEqual(precomposed?.replaceKeystrokeCount, 4)
        // Decomposed "ñ" (n + combining tilde) still matches (canonical equivalence), but the lengths
        // come from what was TYPED: 1 grapheme, 2 UTF-16 units for that letter.
        let decomposed = SnippetTrigger.match(prefix: ";an\u{0303}o", snippets: [snippet], now: fixedNow)
        XCTAssertEqual(decomposed?.replaceUTF16Length, 5)
        XCTAssertEqual(decomposed?.replaceKeystrokeCount, 4)
        let upper = SnippetTrigger.match(prefix: ";AÑO", snippets: [snippet], now: fixedNow)
        XCTAssertEqual(upper?.typedRun, ";AÑO")
    }

    // MARK: - Placeholders

    func testDateAndTimePlaceholders() {
        let out = SnippetPlaceholders.expand("Sent {date} at {time}", now: fixedNow,
                                             locale: posix, timeZone: utc)
        XCTAssertEqual(plainSpaces(out), "Sent Oct 7, 2026 at 2:05 PM")
    }

    func testPlaceholdersFollowTimeZone() {
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        XCTAssertEqual(plainSpaces(SnippetPlaceholders.expand("{time}", now: fixedNow,
                                                              locale: posix, timeZone: madrid)),
                       "4:05 PM")
    }

    func testRepeatedAndUnknownPlaceholders() {
        let out = SnippetPlaceholders.expand("{date}/{date} {clipboard} {name}", now: fixedNow,
                                             locale: posix, timeZone: utc)
        XCTAssertEqual(out, "Oct 7, 2026/Oct 7, 2026 {clipboard} {name}")
    }

    func testLineEndingsNormalizedAndJunkStripped() {
        XCTAssertEqual(SnippetPlaceholders.expand("a\r\nb\rc\u{0007}\td", now: fixedNow), "a\nb\nc\td")
    }

    func testMatchRendersPlaceholdersAtNow() {
        let dated = Snippet(name: "today", expansion: "Today is {date}")
        let match = SnippetTrigger.match(prefix: ";today", snippets: [dated], now: fixedNow,
                                         locale: posix, timeZone: utc)
        XCTAssertEqual(match?.expansion, "Today is Oct 7, 2026")
    }

    // ICU puts a narrow no-break space before AM/PM on recent macOS; compare on plain spaces.
    private func plainSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: - Ghost preview

    func testPreviewFlattensLineBreaks() {
        XCTAssertEqual(SnippetPreview.ghostText(for: "Best,\nDarío"), "Best, ↵ Darío")
        XCTAssertEqual(SnippetPreview.ghostText(for: "one line"), "one line")
    }

    func testPreviewTruncatesWithEllipsis() {
        let long = String(repeating: "x", count: 100)
        let preview = SnippetPreview.ghostText(for: long, maxCharacters: 10)
        XCTAssertEqual(preview, String(repeating: "x", count: 9) + "…")
        XCTAssertLessThanOrEqual(SnippetPreview.ghostText(for: long).count,
                                 OverlayRenderer.maxRenderedPayloadCharacters)
    }
}
