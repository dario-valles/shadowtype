// Pure unit tests for InferenceEngine.firstStopMatch (the M0 stop-string scan used by the
// API decode loop). No model required — the scan is a pure static helper.
import XCTest
@testable import Shadowtype

final class StopStringScanTests: XCTestCase {

    func testFindsSingleStop() {
        let s = "Hello world\nUser:"
        let idx = InferenceEngine.firstStopMatch(in: s, stops: ["\nUser:"])
        XCTAssertEqual(idx.map { s.distance(from: s.startIndex, to: $0) }, 11)
    }

    func testReturnsEarliestAcrossMultipleStops() {
        // The scanner must pick the earliest match across the stop list, not the first stop that
        // happens to appear in iteration order. Otherwise a "Z" stop later in the array would
        // hide an "A" stop earlier in the text.
        let s = "foo BAR baz QUX done"
        let idx = InferenceEngine.firstStopMatch(in: s, stops: ["QUX", "BAR"])
        XCTAssertEqual(idx.map { s.distance(from: s.startIndex, to: $0) }, 4,
                       "BAR appears earlier than QUX and must win")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(InferenceEngine.firstStopMatch(in: "hello world", stops: ["xyz", "abc"]))
    }

    func testEmptyStopsReturnsNil() {
        XCTAssertNil(InferenceEngine.firstStopMatch(in: "hello", stops: []))
    }

    func testEmptyStopStringIsIgnored() {
        // An empty stop would match at position 0 of every string and short-circuit every API
        // request to zero output. Defensive skip is critical.
        XCTAssertNil(InferenceEngine.firstStopMatch(in: "hello", stops: [""]))
    }

    // Chat-turn delimiters leak as plain text on GGUFs that don't flag them as EOG (gemma's
    // `<end_of_turn>` token 106). The chat route prepends LocalAPIRoutes.chatEndSentinels as stop
    // strings; verify each truncates before the sentinel so it never rides out in `content`.
    func testChatEndSentinelsTruncateLeakedDelimiter() {
        let s = "Sure, here you go.\n<end_of_turn>"
        let idx = InferenceEngine.firstStopMatch(in: s, stops: LocalAPIRoutes.chatEndSentinels)
        XCTAssertEqual(idx.map { s.distance(from: s.startIndex, to: $0) }, 19,
                       "must cut at the leaked <end_of_turn>, dropping it from the emitted content")
    }

    func testEveryChatEndSentinelIsMatchable() {
        for sentinel in LocalAPIRoutes.chatEndSentinels {
            let s = "reply text \(sentinel) trailing"
            XCTAssertNotNil(InferenceEngine.firstStopMatch(in: s, stops: LocalAPIRoutes.chatEndSentinels),
                            "sentinel \(sentinel) must be detected")
        }
    }

    // StreamStopFilter — the holdback that fixes the multi-token leak (gemma emits "<end_of_turn>"
    // across pieces, so a naive emit-on-arrival leaks "<end_of_turn" before the closing ">" matches).
    private func runFilter(_ pieces: [String], stops: [String]) -> String {
        var f = InferenceEngine.StreamStopFilter(stops: stops)
        var out = ""
        for p in pieces {
            let (chunk, stopped) = f.push(p)
            out += chunk
            if stopped { return out }   // finish() not called after a stop — the tail IS the stop
        }
        return out + f.finish()
    }

    func testStreamFilterDropsMultiTokenStopSplitAcrossPieces() {
        // The exact gemma leak: the sentinel arrives as separate tokens after real content.
        let out = runFilter(["Hi there!\n", "<", "end_of_turn", ">"], stops: ["<end_of_turn>"])
        XCTAssertEqual(out, "Hi there!\n", "no partial '<end_of_turn' may leak")
    }

    func testStreamFilterEmitsCleanTextWhenNoStop() {
        let out = runFilter(["Hello", " ", "world", "!"], stops: ["<end_of_turn>"])
        XCTAssertEqual(out, "Hello world!", "held tail must be flushed by finish()")
    }

    func testStreamFilterDropsStopThatLandsInsideOnePiece() {
        let out = runFilter(["done<|im_end|>extra"], stops: ["<|im_end|>"])
        XCTAssertEqual(out, "done")
    }

    func testStreamFilterNoStopsPassesEverythingThrough() {
        let out = runFilter(["a", "b", "c"], stops: [])
        XCTAssertEqual(out, "abc")
    }
}
