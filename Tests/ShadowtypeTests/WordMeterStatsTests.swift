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
}
