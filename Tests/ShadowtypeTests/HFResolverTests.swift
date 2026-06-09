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
