// Pure unit tests for HFResolver URL parsing. Network calls (listGGUFs) are not exercised here
// — they hit https://huggingface.co and would be flaky/slow in CI.
import XCTest
@testable import Shadowtype

final class HFResolverTests: XCTestCase {

    func testRepoOnlyURL() {
        let p = HFResolver.parse("https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF")
        guard case let .repoOnly(owner, repo) = p else {
            XCTFail("expected .repoOnly, got \(p)"); return
        }
        XCTAssertEqual(owner, "bartowski")
        XCTAssertEqual(repo, "Llama-3.2-3B-Instruct-GGUF")
    }

    func testRepoTreeURLAlsoTreatedAsRepo() {
        // /tree/main or /blob/... routes also resolve as a repo: we fall back to the API
        // listing rather than rejecting the URL — the user copy-pasted from the browser.
        let p = HFResolver.parse("https://huggingface.co/owner/repo/tree/main")
        guard case let .repoOnly(owner, repo) = p else {
            XCTFail("expected .repoOnly, got \(p)"); return
        }
        XCTAssertEqual(owner, "owner")
        XCTAssertEqual(repo, "repo")
    }

    func testDirectFileURL() {
        let s = "https://huggingface.co/mradermacher/Qwen3-1.7B-Base-GGUF/resolve/main/Qwen3-1.7B-Base.Q4_K_M.gguf"
        let p = HFResolver.parse(s)
        guard case let .directFile(owner, repo, revision, filename, url) = p else {
            XCTFail("expected .directFile, got \(p)"); return
        }
        XCTAssertEqual(owner, "mradermacher")
        XCTAssertEqual(repo, "Qwen3-1.7B-Base-GGUF")
        XCTAssertEqual(revision, "main")
        XCTAssertEqual(filename, "Qwen3-1.7B-Base.Q4_K_M.gguf")
        XCTAssertEqual(url.absoluteString, s)
    }

    func testDirectFileWithSubdir() {
        let s = "https://huggingface.co/owner/repo/resolve/main/subdir/model.gguf"
        let p = HFResolver.parse(s)
        guard case let .directFile(_, _, _, filename, _) = p else {
            XCTFail("expected .directFile, got \(p)"); return
        }
        XCTAssertEqual(filename, "model.gguf",
                       "filename must be the basename even when nested under subdirs")
    }

    func testDirectFileNonGGUFRejected() {
        let p = HFResolver.parse("https://huggingface.co/owner/repo/resolve/main/notes.txt")
        guard case .invalid = p else {
            XCTFail("non-.gguf direct URL must be rejected, got \(p)"); return
        }
    }

    func testNonHFHostRejected() {
        XCTAssertEqual(HFResolver.parse("https://example.com/foo/bar"),
                       .invalid(reason: "URL must point at huggingface.co"))
        XCTAssertEqual(HFResolver.parse("not a url"),
                       .invalid(reason: "URL must point at huggingface.co"))
    }

    func testWhitespaceTrimmed() {
        let p = HFResolver.parse("   https://huggingface.co/o/r   ")
        guard case let .repoOnly(owner, repo) = p else {
            XCTFail("expected .repoOnly, got \(p)"); return
        }
        XCTAssertEqual(owner, "o")
        XCTAssertEqual(repo, "r")
    }

    func testDisplaySize() {
        XCTAssertEqual(HFResolver.displaySize(nil), "")
        XCTAssertEqual(HFResolver.displaySize(0), "0 MB")
        XCTAssertEqual(HFResolver.displaySize(100 * 1024 * 1024), "100 MB")
        XCTAssertEqual(HFResolver.displaySize(2 * 1024 * 1024 * 1024), "2.0 GB")
    }

    func testSiblingDownloadURLEncodesSpacesAndSubdirs() {
        // Plain name → canonical resolve URL.
        XCTAssertEqual(
            HFResolver.siblingDownloadURL(owner: "o", repo: "r", name: "model.Q4_K_M.gguf")?.absoluteString,
            "https://huggingface.co/o/r/resolve/main/model.Q4_K_M.gguf")
        // A subdir path keeps its "/" separators.
        XCTAssertEqual(
            HFResolver.siblingDownloadURL(owner: "o", repo: "r", name: "sub/model.gguf")?.absoluteString,
            "https://huggingface.co/o/r/resolve/main/sub/model.gguf")
        // A space (the rfilename that used to crash URL(string:)!) is percent-encoded, not trapped.
        let spaced = HFResolver.siblingDownloadURL(owner: "o", repo: "r", name: "my model.gguf")
        XCTAssertNotNil(spaced, "a name with a space must build a valid URL, never crash")
        XCTAssertEqual(spaced?.absoluteString, "https://huggingface.co/o/r/resolve/main/my%20model.gguf")
    }
}

final class DiagRedactionTests: XCTestCase {

    func testAuthorizationHeaderRedacted() {
        let s = "downloading with Authorization: Bearer abc.def.GHI-123"
        let r = Diag.redactSecrets(s)
        XCTAssertFalse(r.contains("abc.def.GHI-123"), "raw token must not survive: \(r)")
        XCTAssertTrue(r.contains("Authorization: Bearer <redacted>"))
    }

    func testHFUserTokenRedacted() {
        let s = "token=hf_aBcDeFgHiJkLmNoPqRsT was used"
        let r = Diag.redactSecrets(s)
        XCTAssertFalse(r.contains("aBcDeFgHiJkLmNoPqRsT"),
                       "hf_… token body must not survive: \(r)")
        XCTAssertTrue(r.contains("hf_<redacted>"))
    }

    func testTokenQueryParamRedacted() {
        let s = "GET /repo?revision=main&token=abc123xyz789 HTTP/1.1"
        let r = Diag.redactSecrets(s)
        XCTAssertFalse(r.contains("abc123xyz789"))
        XCTAssertTrue(r.contains("token=<redacted>"))
    }

    func testNonSecretStringsUntouched() {
        let s = "model swap to byom-abc123 failed: invalid format"
        XCTAssertEqual(Diag.redactSecrets(s), s,
                       "non-secret strings must round-trip unchanged")
    }
}

// MARK: - Import-picker helpers (sort + default selection)

extension HFResolverTests {
    private func sib(_ name: String, _ size: Int64?) -> HFResolver.Sibling {
        HFResolver.Sibling(filename: name, sizeBytes: size,
                           downloadURL: URL(string: "https://huggingface.co/o/r/resolve/main/\(name)")!)
    }

    func testSortedBySizeAscending() {
        let sorted = HFResolver.sortedBySizeAscending([
            sib("big.Q8_0.gguf", 8_000), sib("small.Q2_K.gguf", 2_000), sib("mid.Q4_K_M.gguf", 4_000),
        ])
        XCTAssertEqual(sorted.map(\.filename),
                       ["small.Q2_K.gguf", "mid.Q4_K_M.gguf", "big.Q8_0.gguf"])
    }

    func testSortedBySizeUnknownSizesSinkToBottomAndOrderByName() {
        let sorted = HFResolver.sortedBySizeAscending([
            sib("z-unknown.gguf", nil), sib("a-unknown.gguf", nil), sib("known.gguf", 1_000),
        ])
        XCTAssertEqual(sorted.map(\.filename),
                       ["known.gguf", "a-unknown.gguf", "z-unknown.gguf"])
    }

    func testSortedBySizeTiesBreakByFilename() {
        let sorted = HFResolver.sortedBySizeAscending([sib("b.gguf", 100), sib("a.gguf", 100)])
        XCTAssertEqual(sorted.map(\.filename), ["a.gguf", "b.gguf"])
    }

    func testPreferredImportFilePicksQ4KMCaseInsensitive() {
        let list = [sib("model.Q2_K.gguf", 1), sib("model.q4_k_m.gguf", 2), sib("model.Q8_0.gguf", 3)]
        XCTAssertEqual(HFResolver.preferredImportFile(in: list)?.filename, "model.q4_k_m.gguf")
        let upper = [sib("model.Q2_K.gguf", 1), sib("Model.Q4_K_M.gguf", 2)]
        XCTAssertEqual(HFResolver.preferredImportFile(in: upper)?.filename, "Model.Q4_K_M.gguf")
    }

    func testPreferredImportFileFallsBackToFirstWhenNoQ4KM() {
        let list = [sib("model.Q2_K.gguf", 1), sib("model.Q8_0.gguf", 3)]
        XCTAssertEqual(HFResolver.preferredImportFile(in: list)?.filename, "model.Q2_K.gguf")
        XCTAssertNil(HFResolver.preferredImportFile(in: []))
    }

    func testPreferredImportFilePrefersIMatrixQ4KM() {
        // Same size and speed as the plain quant, lower perplexity on rare/non-English tokens — so
        // when a repo ships both, the imatrix build is the better default.
        let list = [sib("model.Q4_K_M.gguf", 2), sib("model.i1-Q4_K_M.gguf", 2)]
        XCTAssertEqual(HFResolver.preferredImportFile(in: list)?.filename, "model.i1-Q4_K_M.gguf")
        // Reverse order must give the same answer (it's a preference, not "first wins").
        let reversed = [sib("model.i1-Q4_K_M.gguf", 2), sib("model.Q4_K_M.gguf", 2)]
        XCTAssertEqual(HFResolver.preferredImportFile(in: reversed)?.filename, "model.i1-Q4_K_M.gguf")
    }

    func testPreferredImportFileNeverPreSelectsAShard() {
        // The 70B case: the only Q4_K_M in the repo is split, so it must not be the default pick.
        let list = [sib("model-Q4_K_M-00001-of-00002.gguf", 9),
                    sib("model-Q4_K_M-00002-of-00002.gguf", 9),
                    sib("model.Q2_K.gguf", 1)]
        XCTAssertEqual(HFResolver.preferredImportFile(in: list)?.filename, "model.Q2_K.gguf")
        // All-shards list: nothing is safely importable.
        XCTAssertNil(HFResolver.preferredImportFile(in: [sib("m-00001-of-00003.gguf", 1)]))
    }

    func testIsIMatrixBuildMatchesWholeTokensOnly() {
        XCTAssertTrue(HFResolver.isIMatrixBuild("Qwen3-8B.i1-Q4_K_M.gguf"))
        XCTAssertTrue(HFResolver.isIMatrixBuild("model-Q4_K_M-imat.gguf"))
        XCTAssertTrue(HFResolver.isIMatrixBuild("model.imatrix.Q4_K_M.gguf"))
        XCTAssertFalse(HFResolver.isIMatrixBuild("model.Q4_K_M.gguf"))
        // "gemini1-" contains the substring "i1-" but is not an imatrix build.
        XCTAssertFalse(HFResolver.isIMatrixBuild("gemini1-Q4_K_M.gguf"))
    }
}

// MARK: - Sharded (split) GGUF rejection

extension HFResolverTests {

    func testShardInfoDetectsSplitFiles() {
        XCTAssertEqual(HFResolver.shardInfo("model-Q4_K_M-00001-of-00002.gguf")?.index, 1)
        XCTAssertEqual(HFResolver.shardInfo("model-Q4_K_M-00001-of-00002.gguf")?.total, 2)
        XCTAssertEqual(HFResolver.shardInfo("Big-Model-00003-of-00017.GGUF")?.index, 3)
        XCTAssertEqual(HFResolver.shardInfo("sub/dir/m-00002-of-00002.gguf")?.index, 2)
    }

    func testShardInfoIgnoresWholeFiles() {
        XCTAssertNil(HFResolver.shardInfo("model.Q4_K_M.gguf"))
        XCTAssertNil(HFResolver.shardInfo("model-00001-of-00001.gguf"),
                     "-00001-of-00001 IS the whole model; rejecting it would block a valid import")
        XCTAssertNil(HFResolver.shardInfo("model-1-of-2.gguf"), "only the 5-digit convention counts")
        XCTAssertNil(HFResolver.shardInfo("model-00003-of-00002.gguf"), "index past total is not a shard")
        XCTAssertNil(HFResolver.shardInfo("model-00001-of-00002.bin"))
    }

    func testPartitionShardsSplitsTheList() {
        let list = [sib("whole.Q4_K_M.gguf", 1),
                    sib("big-00001-of-00002.gguf", 9), sib("big-00002-of-00002.gguf", 9)]
        let p = HFResolver.partitionShards(list)
        XCTAssertEqual(p.whole.map(\.filename), ["whole.Q4_K_M.gguf"])
        XCTAssertEqual(p.shards.count, 2)
    }

    func testShardRejectionMessageNamesTheOffendingFile() {
        let msg = HFResolver.shardRejectionMessage([sib("big-00001-of-00002.gguf", 9)])
        XCTAssertTrue(msg.contains("big-00001-of-00002.gguf"), msg)
        XCTAssertTrue(msg.lowercased().contains("split"), "must say WHY it was rejected: \(msg)")
    }

    func testDirectShardURLRejectedWithReason() {
        // Every shard carries the GGUF magic, so this used to download + register fine and then die at
        // load with the generic "may be corrupt or unsupported".
        let p = HFResolver.parse(
            "https://huggingface.co/o/r/resolve/main/Model-Q4_K_M-00001-of-00002.gguf")
        guard case let .invalid(reason) = p else {
            XCTFail("a shard URL must be rejected, got \(p)"); return
        }
        XCTAssertTrue(reason.contains("split"), "reason must explain the shard problem: \(reason)")
    }

    func testDirectWholeFileURLStillAccepted() {
        let p = HFResolver.parse("https://huggingface.co/o/r/resolve/main/Model-00001-of-00001.gguf")
        guard case let .directFile(_, _, _, filename, _) = p else {
            XCTFail("a single-part file must still import, got \(p)"); return
        }
        XCTAssertEqual(filename, "Model-00001-of-00001.gguf")
    }
}
