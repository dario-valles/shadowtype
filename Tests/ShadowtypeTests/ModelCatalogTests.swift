// ModelCatalog — curated GGUF catalog + RAM-fit gating (FR-LM-1, FR-LM-2, FR-LM-3).
// Pure data + logic; fully hermetic (no networking, no disk, synthetic physicalBytes).
import XCTest
@testable import Shadowtype

final class ModelCatalogTests: XCTestCase {
    // Convenience synthetic machine sizes (bytes).
    private let gb: UInt64 = 1_000_000_000
    private func machine(_ gigabytes: UInt64) -> UInt64 { gigabytes * gb }

    // MARK: - Catalog shape (FR-LM-1)

    func testEntriesNonEmptyAndAllHTTPS() {
        XCTAssertFalse(ModelCatalog.entries.isEmpty)
        for entry in ModelCatalog.entries {
            XCTAssertEqual(entry.url.scheme, "https", "non-https url for \(entry.id): \(entry.url)")
            XCTAssertFalse(entry.id.isEmpty)
            XCTAssertFalse(entry.fileName.isEmpty)
            XCTAssertGreaterThan(entry.approxRAMGB, 0)
        }
    }

    func testEntryIdsAreUnique() {
        let ids = ModelCatalog.entries.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate entry ids: \(ids)")
    }

    func testDefaultEntryPresentNotPaidAndMatchesModelManager() {
        // The free default must be present, free, and mirror ModelManager's pinned defaults exactly.
        guard let dflt = ModelCatalog.entries.first(where: {
            $0.fileName == ModelManager.defaultModelFileName
        }) else {
            return XCTFail("default model entry missing from catalog")
        }
        XCTAssertFalse(dflt.paidOnly, "default model must be free")
        XCTAssertEqual(dflt.url, ModelManager.defaultModelDownloadURL)
        XCTAssertEqual(dflt.sha256, ModelManager.defaultModelSHA256)
    }

    func testAllEntriesAreFree() {
        // The catalog is entirely free — no Pro gating on any model (product decision).
        for entry in ModelCatalog.entries {
            XCTAssertFalse(entry.paidOnly, "\(entry.id) is paidOnly; the catalog must be all-free")
        }
    }

    func testFreeUpgradePathBeyondDefault() {
        // Larger free models exist beyond the shipping default, so users have an upgrade path.
        let free = ModelCatalog.entries.filter { !$0.paidOnly }
        XCTAssertGreaterThanOrEqual(free.count, 2, "expected a free upgrade beyond the default")
        XCTAssertTrue(ModelCatalog.entries.contains { $0.approxRAMGB >= 7.0 },
                      "expected at least one large model in the catalog")
    }

    func testScreenshotModelsPresent() {
        // Every model shown in the target picker must be in the catalog.
        let want = [
            "gemma-3-1b-pt-q4_k_m", "qwen3-1.7b-base-q4_k_m", "qwen3-4b-base-q4_k_m",
            "gemma-4-e2b-it-qat-q4_0", "gemma-4-e4b-it-qat-q4_0", "gemma-4-12b-it-qat-q4_0",
            "qwen3-8b-base-q4_k_m", "gemma-4-26b-a4b-it-qat-q4_0", "qwen3-30b-a3b-base-q4_k_m",
        ]
        let ids = Set(ModelCatalog.entries.map { $0.id })
        for id in want { XCTAssertTrue(ids.contains(id), "missing catalog entry \(id)") }
    }

    func testEntriesOrderedSmallToLarge() {
        // Ordering by approxRAMGB is ascending so recommend() and the UI read naturally.
        let rams = ModelCatalog.entries.map { $0.approxRAMGB }
        XCTAssertEqual(rams, rams.sorted(), "entries must be ordered small→large by approxRAMGB")
    }

    func testAllEntriesHaveDownloadSize() {
        for entry in ModelCatalog.entries {
            XCTAssertGreaterThan(entry.downloadGB, 0, "missing downloadGB for \(entry.id)")
        }
    }

    // MARK: - RAM gate (FR-LM-2, PRD §6 ~75% budget)

    func testRamOKTrueForSmallModelOnBigMachine() {
        let small = ModelCatalogEntry(
            id: "tiny", name: "Tiny", fileName: "tiny.gguf",
            url: URL(string: "https://example.com/tiny.gguf")!,
            sha256: nil, approxRAMGB: 1.5, downloadGB: 0.8, paidOnly: false)
        XCTAssertTrue(ModelCatalog.ramOK(for: small, physicalBytes: machine(32)))
    }

    func testRamOKFalseForHugeModelOnSmallMachine() {
        let huge = ModelCatalogEntry(
            id: "huge", name: "Huge", fileName: "huge.gguf",
            url: URL(string: "https://example.com/huge.gguf")!,
            sha256: nil, approxRAMGB: 7.5, downloadGB: 4.9, paidOnly: true)
        // 8 GB machine -> budget is 6 GB; a 7.5 GB model must be blocked.
        XCTAssertFalse(ModelCatalog.ramOK(for: huge, physicalBytes: machine(8)))
    }

    func testRamOKBoundaryAtSeventyFivePercent() {
        // Exactly at the 75% budget is allowed (<=). 6 GB model on an 8 GB machine: budget == 6 GB.
        let edge = ModelCatalogEntry(
            id: "edge", name: "Edge", fileName: "edge.gguf",
            url: URL(string: "https://example.com/edge.gguf")!,
            sha256: nil, approxRAMGB: 6.0, downloadGB: 3.5, paidOnly: true)
        XCTAssertTrue(ModelCatalog.ramOK(for: edge, physicalBytes: machine(8)))
    }

    // MARK: - Recommendation (FR-LM-3)

    func testRecommendedPicksWithinRAM() {
        // On a generous machine, every entry fits, so the recommendation is the largest entry and it
        // must itself be RAM-OK.
        let rec = ModelCatalog.recommended(physicalBytes: machine(64))
        XCTAssertTrue(ModelCatalog.ramOK(for: rec, physicalBytes: machine(64)))
        let largest = ModelCatalog.entries.max(by: { $0.approxRAMGB < $1.approxRAMGB })
        XCTAssertEqual(rec.id, largest?.id)
    }

    func testRecommendedFitsConstrainedMachine() {
        // On a tight machine, the recommendation must be one that actually fits the 75% budget.
        let rec = ModelCatalog.recommended(physicalBytes: machine(8))
        XCTAssertTrue(ModelCatalog.ramOK(for: rec, physicalBytes: machine(8)))
    }

    func testRecommendedFallsBackToSmallestWhenNothingFits() {
        // A machine too small for any entry still gets the smallest entry (so the app can run).
        let rec = ModelCatalog.recommended(physicalBytes: 1) // 1 byte: nothing fits
        let smallest = ModelCatalog.entries.min(by: { $0.approxRAMGB < $1.approxRAMGB })
        XCTAssertEqual(rec.id, smallest?.id)
    }

    // Bug 3: instruct models silently drop the ghost on dangling/non-English prefixes, so the
    // recommender must prefer base over instruct even when an instruct model is larger and still fits.

    func testRecommendedNeverInstructWhenABaseFits() {
        // Sweep a range of machine sizes; whenever any base model fits, the pick must be a base.
        for gigs: UInt64 in [4, 8, 16, 17, 24, 32, 64, 128] {
            let rec = ModelCatalog.recommended(physicalBytes: machine(gigs))
            let anyBaseFits = ModelCatalog.entries.contains {
                !$0.isInstruct && ModelCatalog.ramOK(for: $0, physicalBytes: machine(gigs))
            }
            if anyBaseFits {
                XCTAssertFalse(rec.isInstruct, "\(gigs)GB: recommended instruct \(rec.id) despite a base fitting")
            }
        }
    }

    func testRecommendedPrefersBaseOverLargerInstruct() {
        // 17 GB (75% ≈ 12.75): Llama-3.1-8B-Instruct (7.5) is the largest-that-fits overall, but the
        // near-identical Qwen3-8B-Base (6.8) must win — the exact case that put this user on a
        // completion-dropping instruct model.
        let rec = ModelCatalog.recommended(physicalBytes: machine(17))
        XCTAssertFalse(rec.isInstruct)
        XCTAssertEqual(rec.id, "qwen3-8b-base-q4_k_m")
    }

    func testRecommendedPickIsStillRamSafe() {
        for gigs: UInt64 in [4, 8, 16, 17, 24, 32, 64] {
            let rec = ModelCatalog.recommended(physicalBytes: machine(gigs))
            XCTAssertTrue(ModelCatalog.ramOK(for: rec, physicalBytes: machine(gigs)),
                          "\(gigs)GB: recommended \(rec.id) exceeds the RAM budget")
        }
    }

    func testInstructFlagTagsExactlyTheInstructEntries() {
        let instruct = Set(ModelCatalog.entries.filter { $0.isInstruct }.map { $0.id })
        XCTAssertEqual(instruct, [
            "gemma-4-e2b-it-qat-q4_0", "gemma-4-e4b-it-qat-q4_0", "gemma-4-12b-it-qat-q4_0",
            "llama-3.1-8b-instruct-q4_k_m", "gemma-4-26b-a4b-it-qat-q4_0",
        ])
    }

    // MARK: - Download URL integrity (guards the hand-entered, irregular Google QAT filenames)

    /// Every resolve URL must point at a `.gguf` LFS object. (Note: the URL's last component need NOT
    /// equal `fileName` — ModelManager always saves under `entry.fileName` regardless, e.g. the default
    /// downloads `...pt.Q4_K_M.gguf` but saves it as `...pt-Q4_K_M.gguf`. Filename-on-server correctness
    /// is enforced by the opt-in network HEAD test below.)
    func testEveryURLIsAGGUF() {
        for entry in ModelCatalog.entries {
            XCTAssertTrue(entry.url.lastPathComponent.hasSuffix(".gguf"),
                          "\(entry.id): url does not end in .gguf: \(entry.url.lastPathComponent)")
        }
    }

    // MARK: - Gemma 4 QAT entries (2026-06-06 swap to official Google QAT Q4_0)

    private var gemma4QATIDs: Set<String> {
        ["gemma-4-e2b-it-qat-q4_0", "gemma-4-e4b-it-qat-q4_0",
         "gemma-4-12b-it-qat-q4_0", "gemma-4-26b-a4b-it-qat-q4_0"]
    }

    /// Every Gemma 4 entry must come from Google's OFFICIAL QAT Q4_0 repos — not a community re-quant.
    /// Guards against accidentally reverting a URL to bartowski or pointing at a non-QAT format.
    func testGemma4EntriesUseOfficialGoogleQATQ4_0() {
        let gemma4 = ModelCatalog.entries.filter { gemma4QATIDs.contains($0.id) }
        XCTAssertEqual(gemma4.count, gemma4QATIDs.count, "missing a Gemma 4 QAT entry")
        for entry in gemma4 {
            XCTAssertEqual(entry.url.host, "huggingface.co", "\(entry.id): not on huggingface.co")
            XCTAssertTrue(entry.url.path.hasPrefix("/google/"),
                          "\(entry.id): not under the official google/ org: \(entry.url.path)")
            XCTAssertTrue(entry.url.path.contains("qat-q4_0"),
                          "\(entry.id): repo is not the QAT Q4_0 variant: \(entry.url.path)")
            XCTAssertTrue(entry.isInstruct,
                          "\(entry.id): Gemma 4 ships instruct-only (no QAT base variant) — must be isInstruct")
        }
    }

    /// The new 12B exists to bridge the E4B→26B-A4B gap, so its RAM footprint must sit strictly between
    /// them. If a future edit reorders or resizes, this catches the gap closing or the 12B drifting out.
    func testGemma4_12BBridgesTheE4BTo26BGap() {
        func ram(_ id: String) -> Double {
            ModelCatalog.entries.first { $0.id == id }!.approxRAMGB
        }
        let e4b = ram("gemma-4-e4b-it-qat-q4_0")
        let twelveB = ram("gemma-4-12b-it-qat-q4_0")
        let twentySixB = ram("gemma-4-26b-a4b-it-qat-q4_0")
        XCTAssertGreaterThan(twelveB, e4b, "12B must be larger than E4B")
        XCTAssertLessThan(twelveB, twentySixB, "12B must be smaller than 26B-A4B")
    }

    // MARK: - Network smoke test (OPT-IN: set SHADOWTYPE_NET_TESTS=1)

    /// Verifies each Gemma 4 QAT resolve URL actually exists and its Content-Length matches the pinned
    /// `downloadGB` (within 5%). This is the last guard before pinning sha256 hashes at release — a
    /// typo in Google's irregular filenames (`gemma-4-E2B_q4_0-it.gguf` vs `...-12b-it-qat-q4_0.gguf`)
    /// surfaces here instead of as a broken in-app download. Skipped by default to keep `swift test`
    /// hermetic; run with `SHADOWTYPE_NET_TESTS=1 swift test --filter testGemma4QATURLsResolve`.
    func testGemma4QATURLsResolve() throws {
        guard ProcessInfo.processInfo.environment["SHADOWTYPE_NET_TESTS"] == "1" else {
            throw XCTSkip("network test — set SHADOWTYPE_NET_TESTS=1 to run")
        }
        for entry in ModelCatalog.entries where gemma4QATIDs.contains(entry.id) {
            var req = URLRequest(url: entry.url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 30
            let exp = expectation(description: "HEAD \(entry.id)")
            var status = -1
            var contentLength: Int64 = -1
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                if let http = resp as? HTTPURLResponse {
                    status = http.statusCode
                    contentLength = http.expectedContentLength
                }
                exp.fulfill()
            }.resume()
            wait(for: [exp], timeout: 35)
            XCTAssertEqual(status, 200, "\(entry.id): HEAD \(entry.url) returned \(status)")
            let expected = entry.downloadGB * 1e9
            let tolerance = expected * 0.05
            XCTAssertEqual(Double(contentLength), expected, accuracy: tolerance,
                           "\(entry.id): Content-Length \(contentLength) != ~\(expected) (downloadGB \(entry.downloadGB))")
        }
    }
}
