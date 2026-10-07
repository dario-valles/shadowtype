// WordMeter all-time stats — the local-only acceptance-rate / all-time counters behind the
// Statistics dashboard (PRD §4.1). Hermetic via the injectable init(storeURL:secret:); never
// touches the real Keychain or Application Support (mirrors M2LoopTests).
import XCTest
@testable import Shadowtype

final class WordMeterStatsTests: XCTestCase {
    private static let testSecret = Data(repeating: 0x5A, count: 32)

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-meterstats-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("meter.json")
    }

    // MARK: - Acceptance rate = accepted / shown

    func testAcceptanceRateIsNilUntilSomethingShown() {
        let meter = WordMeter(storeURL: tempURL(), secret: Self.testSecret)
        XCTAssertNil(meter.acceptanceRate(), "no shown suggestions yet -> undefined rate, not 0")
    }

    func testAcceptanceRateCountsAcceptedOverShown() {
        let meter = WordMeter(storeURL: tempURL(), secret: Self.testSecret)
        for _ in 0..<4 { meter.recordSuggestionShown() }
        meter.recordSuggestionAccepted()
        XCTAssertEqual(meter.acceptanceRate() ?? -1, 0.25, accuracy: 1e-9)
    }

    // MARK: - All-time words accumulate independently of the daily cap counter

    func testIncrementBumpsBothTodayAndAllTime() {
        let meter = WordMeter(storeURL: tempURL(), secret: Self.testSecret)
        meter.increment(by: 3)
        meter.increment(by: 2)
        XCTAssertEqual(meter.todayCount(), 5)
        XCTAssertEqual(meter.allTimeWordCount(), 5)
    }

    // MARK: - Persistence across instances (the new counters are HMAC-signed + round-trip)

    func testStatsPersistAcrossInstances() {
        let url = tempURL()
        do {
            let meter = WordMeter(storeURL: url, secret: Self.testSecret)
            meter.increment(by: 7)
            meter.recordSuggestionShown()
            meter.recordSuggestionShown()
            meter.recordSuggestionAccepted()
            meter.flush()   // stat writes are coalesced/async; force them to disk before reopening
        }
        let reopened = WordMeter(storeURL: url, secret: Self.testSecret)
        XCTAssertEqual(reopened.allTimeWordCount(), 7)
        XCTAssertEqual(reopened.acceptanceRate() ?? -1, 0.5, accuracy: 1e-9)
    }

    // A forged file (wrong secret) fails the integrity check and resets — all-time stats included.
    func testTamperedFileResetsStats() {
        let url = tempURL()
        do {
            let meter = WordMeter(storeURL: url, secret: Self.testSecret)
            meter.increment(by: 9)
            meter.recordSuggestionShown()
        }
        let wrongSecret = WordMeter(storeURL: url, secret: Data(repeating: 0x11, count: 32))
        XCTAssertEqual(wrongSecret.allTimeWordCount(), 0)
        XCTAssertNil(wrongSecret.acceptanceRate())
    }

    // MARK: - Keystrokes saved (Statistics "Keystrokes saved" card)

    func testKeystrokesSavedIsCharactersMinusTheAcceptKey() {
        XCTAssertEqual(WordMeter.keystrokesSaved(accepting: " hello"), 5)        // 6 chars, 1 Tab
        XCTAssertEqual(WordMeter.keystrokesSaved(accepting: "see you tomorrow"), 15)
        XCTAssertEqual(WordMeter.keystrokesSaved(accepting: "café"), 3)         // characters, not bytes
        XCTAssertEqual(WordMeter.keystrokesSaved(accepting: "👋🏽 hi"), 3)         // one grapheme per emoji
    }

    func testKeystrokesSavedNeverNegative() {
        XCTAssertEqual(WordMeter.keystrokesSaved(accepting: ""), 0)
        XCTAssertEqual(WordMeter.keystrokesSaved(accepting: "a"), 0)   // typing it costs the same key press
    }

    func testKeystrokesSavedAccumulateAndPersist() {
        let url = tempURL()
        do {
            let meter = WordMeter(storeURL: url, secret: Self.testSecret)
            XCTAssertEqual(meter.allTimeKeystrokesSaved(), 0)
            meter.recordKeystrokesSaved(5)
            meter.recordKeystrokesSaved(0)
            meter.recordKeystrokesSaved(-3)   // ignored, never subtracts
            meter.recordKeystrokesSaved(15)
            XCTAssertEqual(meter.allTimeKeystrokesSaved(), 20)
            meter.flush()
        }
        XCTAssertEqual(WordMeter(storeURL: url, secret: Self.testSecret).allTimeKeystrokesSaved(), 20)
    }

    // A meter.json written before the keystroke counter existed must still verify on upgrade: losing the
    // user's all-time stats to a format change would be a silent reset of their data.
    func testRecordWithoutKeystrokeFieldStillVerifies() throws {
        let url = tempURL()
        let today = WordMeter(storeURL: tempURL(), secret: Self.testSecret).effectiveTodayLocalString()
        let legacy = WordMeter.makeSignedRecordData(date: today, count: 4, lastSeenMaxDate: today,
                                                    secret: Self.testSecret)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("keystrokesSavedAllTime"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try legacy.write(to: url)

        let meter = WordMeter(storeURL: url, secret: Self.testSecret)
        XCTAssertEqual(meter.todayCount(), 4, "legacy record must pass the HMAC check, not reset")
        XCTAssertEqual(meter.allTimeKeystrokesSaved(), 0)
    }

    // The new counter is covered by the HMAC like the others: a forged value fails the integrity check.
    func testEditedKeystrokeCountFailsIntegrityCheck() throws {
        let url = tempURL()
        do {
            let meter = WordMeter(storeURL: url, secret: Self.testSecret)
            meter.increment(by: 2)
            meter.recordKeystrokesSaved(10)
            meter.flush()
        }
        let edited = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"keystrokesSavedAllTime\":10", with: "\"keystrokesSavedAllTime\":9999")
        XCTAssertTrue(edited.contains("9999"))
        try edited.write(to: url, atomically: true, encoding: .utf8)
        let reopened = WordMeter(storeURL: url, secret: Self.testSecret)
        XCTAssertEqual(reopened.allTimeKeystrokesSaved(), 0)
        XCTAssertEqual(reopened.allTimeWordCount(), 0)
    }
}
