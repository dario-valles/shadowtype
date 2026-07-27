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

    /// The model cards used to hardcode "Q4_K_M" for every row, mislabeling the four Google QAT `q4_0`
    /// GGUFs. `quant` is the field the UI must render, so it has to be set and has to agree with the
    /// actual file name — a copy-pasted entry with the wrong quant is exactly the mislabel we just fixed.
    func testEveryEntryDeclaresItsQuantAndItMatchesTheFileName() {
        for entry in ModelCatalog.entries {
            guard let quant = entry.quant else {
                XCTFail("\(entry.id): missing quant — the UI would have to guess")
                continue
            }
            let file = entry.fileName.lowercased()
            let expected: String
            if file.contains("q4_k_m") {
                expected = "Q4_K_M"
            } else if file.contains("q4_0") {
                expected = "Q4_0"
            } else {
                XCTFail("\(entry.id): filename \(entry.fileName) declares no recognizable quant")
                continue
            }
            XCTAssertEqual(quant, expected, "\(entry.id): quant \(quant) contradicts file \(entry.fileName)")
        }
    }

    /// Llama 3.1 8B Instruct was removed: dominated by the ~4B-class 2026 entries at twice their size,
    /// a 2023-12 knowledge cutoff, the only non-permissive license in the catalog, and the only instruct
    /// entry that violated the base-variant-for-raw-continuation rule. Guards against a revert.
    func testLlama31IsNotInTheCatalog() {
        XCTAssertFalse(ModelCatalog.entries.contains { $0.id.contains("llama") },
                       "llama-3.1-8b-instruct was deliberately removed; do not re-add it")
    }

    // MARK: - RAM gate (FR-LM-2, PRD §6)
    // The budget is min(75% of RAM, RAM - 3 GB OS floor) and the model costs weights + 10% KV cache
    // (F16 KV at the engine's n_ctx=4096). The old gate compared 75% of RAM against the WEIGHTS ALONE,
    // which left an 8 GB Mac 6.44 GB for the model and nothing for macOS, the app being typed into, or
    // the KV cache — and on Apple Silicon the GPU shares that same unified pool.

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
        // 8 GB machine -> budget is 5 GB (8 - 3 OS floor); a 7.5 GB model must be blocked.
        XCTAssertFalse(ModelCatalog.ramOK(for: huge, physicalBytes: machine(8)))
    }

    /// WAS `testRamOKBoundaryAtSeventyFivePercent`, which asserted a 6.0 GB model IS RAM-OK on an 8 GB
    /// machine. That assertion LOCKED IN the bug: 6.0 GB of weights + ~0.6 GB of KV on an 8 GB Mac
    /// leaves under 1.4 GB for macOS and the app being typed into, so it swaps. New expectation: with
    /// the 3 GB OS floor the budget is 5 GB and a 6.0 GB model is correctly blocked.
    func testRamOKBlocksSixGBModelOnEightGBMachine() {
        let edge = ModelCatalogEntry(
            id: "edge", name: "Edge", fileName: "edge.gguf",
            url: URL(string: "https://example.com/edge.gguf")!,
            sha256: nil, approxRAMGB: 6.0, downloadGB: 3.5, paidOnly: true)
        XCTAssertFalse(ModelCatalog.ramOK(for: edge, physicalBytes: machine(8)),
                       "6 GB weights + KV cannot coexist with macOS on an 8 GB Mac")
    }

    /// The concrete shipped case: Gemma 4 E4B (6.3 GB) reported RAM-OK on an 8 GB Mac under the old
    /// weights-only 75% rule and so never got the "Tight on RAM" tag in the Models pane.
    func testGemma4E4BIsNotRamOKOnEightGBMachine() {
        let e4b = ModelCatalog.entries.first { $0.id == "gemma-4-e4b-it-qat-q4_0" }!
        XCTAssertFalse(ModelCatalog.ramOK(for: e4b, physicalBytes: machine(8)),
                       "E4B (6.3 GB) must be tagged tight on an 8 GB Mac")
    }

    func testRamOKBudgetBoundaryOnA16GBMachine() {
        // 16 GB -> budget = min(12, 13) = 12 GB, and the model costs weights * 1.1 (KV cache).
        // 10.0 GB of weights costs 11.0 -> fits; 11.0 GB costs 12.1 -> does not.
        func entry(_ ram: Double) -> ModelCatalogEntry {
            ModelCatalogEntry(
                id: "edge-\(ram)", name: "Edge", fileName: "edge.gguf",
                url: URL(string: "https://example.com/edge.gguf")!,
                sha256: nil, approxRAMGB: ram, downloadGB: 1.0, paidOnly: false)
        }
        XCTAssertTrue(ModelCatalog.ramOK(for: entry(10.0), physicalBytes: machine(16)))
        XCTAssertFalse(ModelCatalog.ramOK(for: entry(11.0), physicalBytes: machine(16)),
                       "the KV cache term must push an 11 GB model past the 12 GB budget")
    }

    func testRamOKSeventyFivePercentStillBindsOnLargeMachines() {
        // On a big Mac the OS floor is slack, so the original 75% headroom rule is what binds:
        // 64 GB -> budget = min(48, 61) = 48; 44 GB of weights costs 48.4 and must be blocked.
        let big = ModelCatalogEntry(
            id: "big", name: "Big", fileName: "big.gguf",
            url: URL(string: "https://example.com/big.gguf")!,
            sha256: nil, approxRAMGB: 44.0, downloadGB: 30.0, paidOnly: false)
        XCTAssertFalse(ModelCatalog.ramOK(for: big, physicalBytes: machine(64)))
    }

    // MARK: - Recommendation (FR-LM-3)

    /// WAS `testRecommendedPicksWithinRAM`, which asserted the recommendation on a 64 GB Mac IS the
    /// LARGEST catalog entry. That assertion LOCKED IN the wrong objective: `recommended()` is the
    /// pre-selected FIRST-RUN download, and the largest entry (qwen3-30b-a3b, 18.6 GB down / ~20 GB
    /// resident) cannot produce a first token inside the coordinator's ~400 ms deadline on a ~1500-token
    /// prompt — the ghost is silently dropped and the product reads as broken. New expectation: even a
    /// 64 GB Mac is recommended the 4B class; the big entries stay manually selectable.
    func testRecommendedIsCappedAtTheFourBClassEvenOnHugeMachines() {
        for gigs: UInt64 in [16, 24, 32, 64, 128] {
            let rec = ModelCatalog.recommended(physicalBytes: machine(gigs))
            XCTAssertEqual(rec.id, "qwen3-4b-base-q4_k_m", "\(gigs)GB recommended \(rec.id)")
            XCTAssertTrue(ModelCatalog.ramOK(for: rec, physicalBytes: machine(gigs)))
        }
        let largest = ModelCatalog.entries.max(by: { $0.approxRAMGB < $1.approxRAMGB })!
        XCTAssertNotEqual(ModelCatalog.recommended(physicalBytes: machine(64)).id, largest.id,
                          "the recommendation must not be 'largest that fits'")
    }

    /// The "product reads as broken" regression, pinned STRUCTURALLY so it survives a catalog reshuffle
    /// that renames or replaces `qwen3-4b-base-q4_k_m`: on a 32 GB Mac the first-run pick must stay in
    /// the small class, because anything heavier misses the ~400 ms first-token deadline and the ghost
    /// never appears at all. Bounded by `recommendedCapRAMGB`, not by a hardcoded id.
    func testRecommendedOnAThirtyTwoGBMacStaysInTheFastClass() {
        let rec = ModelCatalog.recommended(physicalBytes: machine(32))
        let cap = ModelCatalog.recommendedCapRAMGB(physicalBytes: machine(32))
        XCTAssertLessThanOrEqual(rec.approxRAMGB, cap,
                                 "32GB pick \(rec.id) (\(rec.approxRAMGB) GB) exceeds the deadline cap")
        XCTAssertLessThanOrEqual(rec.approxRAMGB, 4.0, "32GB pick must stay in the ~4B class")
        // The failure this encodes: an 18.6 GB 30B MoE fits 32 GB of RAM and was picked by the old
        // largest-that-fits rule, then showed no ghost.
        let heaviest = ModelCatalog.entries.max(by: { $0.approxRAMGB < $1.approxRAMGB })!
        XCTAssertTrue(ModelCatalog.ramOK(for: heaviest, physicalBytes: machine(32)),
                      "precondition: the heaviest entry does fit 32 GB — that is why the cap exists")
        XCTAssertNotEqual(rec.id, heaviest.id)
        // A base model, so it continues raw-prefix text instead of emitting end-of-turn (bug 3).
        XCTAssertFalse(rec.isInstruct)
    }

    func testRecommendedOnEightGBIsTheSmallGemma() {
        // 8 GB Macs share unified memory with the browser/editor being typed into, so the first-run
        // pick stays at the ~1.5 GB class rather than the 4B that would technically fit the budget.
        let rec = ModelCatalog.recommended(physicalBytes: machine(8))
        XCTAssertEqual(rec.id, "gemma-3-1b-pt-q4_k_m")
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
        // WAS: 17 GB expected qwen3-8b-base (6.8), beating the now-removed Llama-3.1-8B-Instruct (7.5).
        // With the first-token-deadline cap the pick is the 4B base instead — still a BASE model, which
        // is what this test is about: instruct models emit end-of-turn on dangling prefixes and drop
        // the ghost, so the recommender must never hand a first-run user one.
        let rec = ModelCatalog.recommended(physicalBytes: machine(17))
        XCTAssertFalse(rec.isInstruct)
        XCTAssertEqual(rec.id, "qwen3-4b-base-q4_k_m")
    }

    func testRecommendedPickIsStillRamSafe() {
        // 4 GB is below the OS floor + the smallest model, so nothing clears the budget there and the
        // documented fallback (smallest entry, knowingly over budget) applies — the app must still have
        // something to load. Everywhere else the pick must be genuinely RAM-safe.
        let smallest = ModelCatalog.entries.min(by: { $0.approxRAMGB < $1.approxRAMGB })!
        for gigs: UInt64 in [4, 8, 16, 17, 24, 32, 64] {
            let rec = ModelCatalog.recommended(physicalBytes: machine(gigs))
            let nothingFits = !ModelCatalog.entries.contains {
                ModelCatalog.ramOK(for: $0, physicalBytes: machine(gigs))
            }
            if nothingFits {
                XCTAssertEqual(rec.id, smallest.id, "\(gigs)GB: fallback must be the smallest entry")
            } else {
                XCTAssertTrue(ModelCatalog.ramOK(for: rec, physicalBytes: machine(gigs)),
                              "\(gigs)GB: recommended \(rec.id) exceeds the RAM budget")
            }
        }
    }

    func testInstructFlagTagsExactlyTheInstructEntries() {
        let instruct = Set(ModelCatalog.entries.filter { $0.isInstruct }.map { $0.id })
        // Only the Gemma 4 family, which ships instruct-only (no base GGUF exists for it).
        XCTAssertEqual(instruct, [
            "gemma-4-e2b-it-qat-q4_0", "gemma-4-e4b-it-qat-q4_0", "gemma-4-12b-it-qat-q4_0",
            "gemma-4-26b-a4b-it-qat-q4_0",
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
