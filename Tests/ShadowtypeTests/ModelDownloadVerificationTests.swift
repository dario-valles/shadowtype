// ModelManager download integrity: the pure pieces of "was this multi-GB file actually verified?"
// and of the resumable-download bookkeeping. Hermetic — no network, no model, no real download.
//
// Background: the onboarding copy promised every model was "verified by checksum" while 9 of 11
// catalog entries ship `sha256: nil`, so the only real check was the 4-byte GGUF magic. These cover
// the replacement: Hugging Face's `X-Linked-Etag` (the LFS object's SHA-256) and `X-Linked-Size`.
import XCTest
@testable import Shadowtype

final class ModelLinkedHeaderTests: XCTestCase {

    func testParsesQuotedLinkedETag() {
        let sha = "caf1c278f8a8ba1e4605af68b6c17c91a18bf315b38bd52efc542d009d19dd57"
        XCTAssertEqual(ModelManager.parseLinkedSHA256("\"\(sha)\""), sha)
        XCTAssertEqual(ModelManager.parseLinkedSHA256(sha), sha)
        XCTAssertEqual(ModelManager.parseLinkedSHA256("  \"\(sha)\"  "), sha)
        XCTAssertEqual(ModelManager.parseLinkedSHA256("W/\"\(sha.uppercased())\""), sha,
                       "weak validator + uppercase hex must normalize to the lowercase digest")
    }

    func testRejectsNonSHA256ETags() {
        // Non-LFS files get an arbitrary/md5-shaped ETag. Verifying against one can only ever fail,
        // so it must be treated as "no hash available" instead.
        XCTAssertNil(ModelManager.parseLinkedSHA256(nil))
        XCTAssertNil(ModelManager.parseLinkedSHA256(""))
        XCTAssertNil(ModelManager.parseLinkedSHA256("\"\""))
        XCTAssertNil(ModelManager.parseLinkedSHA256("\"9bb1e4605af68b6c17c91a18bf315b38\""), "md5 length")
        XCTAssertNil(ModelManager.parseLinkedSHA256(String(repeating: "z", count: 64)), "not hex")
        XCTAssertNil(ModelManager.parseLinkedSHA256("\"686897696a7c876b7e\"-gzip"))
    }

    func testParsesLinkedSize() {
        XCTAssertEqual(ModelManager.parseLinkedSize("806056864"), 806_056_864)
        XCTAssertEqual(ModelManager.parseLinkedSize(" 806056864 "), 806_056_864)
        XCTAssertNil(ModelManager.parseLinkedSize(nil))
        XCTAssertNil(ModelManager.parseLinkedSize(""))
        XCTAssertNil(ModelManager.parseLinkedSize("1.2e9"))
        XCTAssertNil(ModelManager.parseLinkedSize("0"), "a zero-byte object is not a usable size")
        XCTAssertNil(ModelManager.parseLinkedSize("-5"))
    }
}

final class ModelVerificationPlanTests: XCTestCase {
    private let pinned = "caf1c278f8a8ba1e4605af68b6c17c91a18bf315b38bd52efc542d009d19dd57"
    private let linked = "0000000000000000000000000000000000000000000000000000000000000001"

    func testPinnedHashWinsOverServerReportedOne() {
        // If HF ever serves different bytes under the same URL, that must be a hard failure — not a
        // silent pass because the server's header agrees with the server's bytes.
        let plan = ModelManager.verificationPlan(pinnedSHA256: pinned, linkedSHA256: linked)
        XCTAssertEqual(plan.expected, pinned)
        XCTAssertEqual(plan.outcome, .pinnedSHA256)
    }

    func testLinkedHashUsedWhenNothingIsPinned() {
        let plan = ModelManager.verificationPlan(pinnedSHA256: nil, linkedSHA256: linked)
        XCTAssertEqual(plan.expected, linked)
        XCTAssertEqual(plan.outcome, .linkedSHA256)
        XCTAssertTrue(plan.outcome.isHashVerified,
                      "a header-verified download IS checksum-verified; the UI may say so")
    }

    func testNoHashAnywhereIsReportedAsUnverified() {
        let plan = ModelManager.verificationPlan(pinnedSHA256: nil, linkedSHA256: nil)
        XCTAssertNil(plan.expected)
        XCTAssertEqual(plan.outcome, .unverified)
        XCTAssertFalse(plan.outcome.isHashVerified,
                       "GGUF-magic-only must NOT be presented to the user as 'verified by checksum'")
        // An empty string is a missing hash, not a hash to compare against.
        XCTAssertEqual(ModelManager.verificationPlan(pinnedSHA256: "", linkedSHA256: "").outcome,
                       .unverified)
    }
}

final class ModelDownloadSizeCheckTests: XCTestCase {

    func testMatchingSizePasses() {
        XCTAssertNoThrow(try ModelManager.checkDownloadedSize(expected: 806_056_864,
                                                              actual: 806_056_864))
    }

    func testTruncatedDownloadIsRejected() {
        // The common real-world failure: the first 4 bytes are a valid GGUF magic, so nothing but the
        // byte count catches it.
        XCTAssertThrowsError(try ModelManager.checkDownloadedSize(expected: 806_056_864,
                                                                  actual: 12_345)) { error in
            guard case let ModelManagerError.sizeMismatch(expected, actual) = error else {
                XCTFail("expected .sizeMismatch, got \(error)"); return
            }
            XCTAssertEqual(expected, 806_056_864)
            XCTAssertEqual(actual, 12_345)
            let msg = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(msg.contains("incomplete"), msg)
        }
    }
}

final class ModelResumeDataTests: XCTestCase {

    private func makeResumeBlob() -> Data {
        let plist: [String: Any] = [
            "NSURLSessionResumeInfoVersion": 2,
            "NSURLSessionDownloadURL": "https://huggingface.co/o/r/resolve/main/m.gguf",
        ]
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    func testResumeBlobLivesNextToTheDownload() {
        let dest = URL(fileURLWithPath: "/tmp/models/gemma-3-1b-pt-Q4_K_M.gguf")
        XCTAssertEqual(ModelManager.resumeDataURL(for: dest).lastPathComponent,
                       "gemma-3-1b-pt-Q4_K_M.gguf.resume")
    }

    func testPlausibleResumeDataAcceptsRealBlobShape() {
        XCTAssertTrue(ModelManager.isPlausibleResumeData(makeResumeBlob()))
    }

    func testPlausibleResumeDataRejectsGarbage() {
        // Handing URLSession a non-plist blob has historically raised an uncatchable ObjC exception,
        // so the shape check has to happen before downloadTask(withResumeData:).
        XCTAssertFalse(ModelManager.isPlausibleResumeData(Data()))
        XCTAssertFalse(ModelManager.isPlausibleResumeData(Data([0x00, 0xFF, 0x10, 0x42])))
        XCTAssertFalse(ModelManager.isPlausibleResumeData(Data("not a plist at all".utf8)))
        let arrayPlist = try! PropertyListSerialization.data(fromPropertyList: ["a", "b"],
                                                            format: .binary, options: 0)
        XCTAssertFalse(ModelManager.isPlausibleResumeData(arrayPlist))
        let wrongKeys = try! PropertyListSerialization.data(fromPropertyList: ["unrelated": 1],
                                                           format: .binary, options: 0)
        XCTAssertFalse(ModelManager.isPlausibleResumeData(wrongKeys))
    }

    func testReadResumeDataReturnsBlobAndDropsCorruptOne() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shadowtype-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("absent.gguf.resume")
        XCTAssertNil(ModelManager.readResumeData(at: missing))

        let good = dir.appendingPathComponent("good.gguf.resume")
        let blob = makeResumeBlob()
        try blob.write(to: good)
        XCTAssertEqual(ModelManager.readResumeData(at: good), blob)
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.path),
                      "a usable blob must survive the read")

        // A truncated/corrupt blob (crash mid-write) must be discarded, otherwise every future attempt
        // would try to resume from it and fail forever.
        let bad = dir.appendingPathComponent("bad.gguf.resume")
        try Data([0x01, 0x02, 0x03]).write(to: bad)
        XCTAssertNil(ModelManager.readResumeData(at: bad))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path),
                       "an unusable blob must be deleted so the next attempt restarts clean")
    }
}

// A resume blob must be keyed by SOURCE as well as destination. `downloadTask(withResumeData:)` ignores
// the request it is handed and continues the URL archived inside the blob, and Hugging Face filenames are
// not unique across repos — `model.Q4_K_M.gguf` from mradermacher, bartowski and unsloth all land on the
// same imported path. Keyed by destination alone, a cancelled import of repo A leaves a blob that a later
// import of repo B's identically-named file picks up, and B silently receives A's bytes.
final class ResumeDataKeyingTests: XCTestCase {
    private let dest = URL(fileURLWithPath: "/tmp/imported/model.Q4_K_M.gguf")

    func testSameFilenameFromDifferentReposDoesNotShareAResumeBlob() {
        let a = ModelManager.resumeDataURL(
            for: dest, source: URL(string: "https://huggingface.co/repoA/resolve/main/model.Q4_K_M.gguf")!)
        let b = ModelManager.resumeDataURL(
            for: dest, source: URL(string: "https://huggingface.co/repoB/resolve/main/model.Q4_K_M.gguf")!)
        XCTAssertNotEqual(a, b, "identically-named files from different repos collided on one resume blob")
    }

    func testSameSourceIsStableSoAResumeCanActuallyBeFound() {
        let url = URL(string: "https://huggingface.co/repoA/resolve/main/model.Q4_K_M.gguf")!
        XCTAssertEqual(ModelManager.resumeDataURL(for: dest, source: url),
                       ModelManager.resumeDataURL(for: dest, source: url))
    }

    func testResumeBlobStaysBesideItsDownload() {
        let url = URL(string: "https://example.com/m.gguf")!
        let resume = ModelManager.resumeDataURL(for: dest, source: url)
        XCTAssertEqual(resume.deletingLastPathComponent(), dest.deletingLastPathComponent())
        XCTAssertEqual(resume.pathExtension, "resume")
    }
}

// The `X-Linked-*` headers ride on Hugging Face's `resolve` 302. A resumed task continues the CDN URL
// archived in the blob and never replays that hop, so without carrying them forward a resumed download
// silently degrades to the GGUF-magic check — in exactly the flow resume exists for.
final class LinkedMetadataCarryTests: XCTestCase {
    private func tempResumeURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("st-meta-\(UUID().uuidString).resume")
    }

    func testMetadataRoundTripsAcrossAResume() {
        let resume = tempResumeURL()
        defer { try? FileManager.default.removeItem(at: ModelManager.linkedMetadataURL(for: resume)) }
        let sha = String(repeating: "a", count: 64)
        ModelManager.writeLinkedMetadata(.init(sha256: sha, size: 1234), besideResumeAt: resume)
        let read = ModelManager.readLinkedMetadata(besideResumeAt: resume)
        XCTAssertEqual(read?.sha256, sha)
        XCTAssertEqual(read?.size, 1234)
    }

    func testEmptyMetadataIsNotWritten() {
        let resume = tempResumeURL()
        ModelManager.writeLinkedMetadata(.init(sha256: nil, size: nil), besideResumeAt: resume)
        XCTAssertNil(ModelManager.readLinkedMetadata(besideResumeAt: resume),
                     "an empty sidecar would masquerade as carried verification data")
    }

    func testMissingSidecarReadsAsNil() {
        XCTAssertNil(ModelManager.readLinkedMetadata(besideResumeAt: tempResumeURL()))
    }
}
