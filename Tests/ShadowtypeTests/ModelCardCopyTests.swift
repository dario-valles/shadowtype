// Onboarding model-card copy: the two strings that used to be constants asserting things that were
// not true of the file in front of the user.
//
// Bug 1: the spec line hardcoded "Q4_K_M" for every catalog row, so the four Google QAT entries —
// which are q4_0 — were mislabelled in the UI.
// Bug 2: the status line read "Verified · GGUF ✓" after every download, while most catalog entries
// ship `sha256: nil`; for those the only check was the 4-byte GGUF magic, which a truncated or
// tampered multi-GB file passes trivially.
//
// Pure string logic, so this is hermetic — no window, no download, no model file.
import XCTest
@testable import Shadowtype

final class ModelCardCopyTests: XCTestCase {

    // MARK: spec line

    func testSpecRendersTheEntrysOwnQuantization() {
        XCTAssertEqual(ModelCardCopy.spec(quant: "Q4_K_M", approxRAMGB: 1.5),
                       "Q4_K_M · on-device · ~1.5 GB RAM")
        XCTAssertEqual(ModelCardCopy.spec(quant: "Q4_0", approxRAMGB: 3.4),
                       "Q4_0 · on-device · ~3.4 GB RAM",
                       "a q4_0 QAT build must not be advertised as Q4_K_M")
    }

    func testSpecFallsBackToNeutralGGUFWhenQuantIsUnknown() {
        // Only BYOM/imported entries carry nil — their filename is the user's, so we cannot know the
        // format. Naming a specific one would be a guess presented as fact.
        XCTAssertEqual(ModelCardCopy.spec(quant: nil, approxRAMGB: 7.2),
                       "GGUF · on-device · ~7.2 GB RAM")
    }

    /// The regression that motivated the field: drive the real catalog through the real copy function
    /// and assert no entry is described with a format that isn't its own.
    func testNoCatalogEntryIsMislabelled() {
        for entry in ModelCatalog.entries {
            let line = ModelCardCopy.spec(quant: entry.quant, approxRAMGB: entry.approxRAMGB)
            guard let quant = entry.quant else {
                XCTFail("catalog entry \(entry.id) has no quant — every shipped entry must record one")
                continue
            }
            XCTAssertTrue(line.hasPrefix(quant + " · "),
                          "\(entry.id) renders as \"\(line)\" but its file is \(quant)")
            if quant != "Q4_K_M" {
                XCTAssertFalse(line.contains("Q4_K_M"),
                               "\(entry.id) is \(quant); the card must not claim Q4_K_M")
            }
        }
    }

    // MARK: installed status

    func testHashVerifiedDownloadsMayClaimVerification() {
        XCTAssertEqual(ModelCardCopy.installedStatus(.pinnedSHA256), "Verified · SHA-256 ✓")
        XCTAssertEqual(ModelCardCopy.installedStatus(.linkedSHA256), "Verified · SHA-256 ✓")
        XCTAssertNil(ModelCardCopy.installedNote(.pinnedSHA256))
        XCTAssertNil(ModelCardCopy.installedNote(.linkedSHA256))
    }

    func testMagicBytesOnlyDownloadNeverClaimsVerification() {
        let status = ModelCardCopy.installedStatus(.unverified)
        XCTAssertFalse(status.lowercased().contains("verified"),
                       "GGUF magic alone is not verification — \"\(status)\" must not say so")
        XCTAssertEqual(status, "Installed · not checksummed")
        // And the plain-language disclosure must actually appear, so the badge isn't the only signal.
        let note = ModelCardCopy.installedNote(.unverified)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("couldn't hash-verify") == true)
    }

    func testNothingDownloadedReportsNoVerdictEitherWay() {
        // nil = the file was already on disk, so no verification ran this launch. That is NOT the same
        // as "unverified", and the UI must neither claim a checksum nor warn about a missing one.
        let status = ModelCardCopy.installedStatus(nil)
        XCTAssertEqual(status, "Installed ✓")
        XCTAssertFalse(status.lowercased().contains("verified"))
        XCTAssertNil(ModelCardCopy.installedNote(nil))
    }

    /// Seam pin: the card's claim must be driven by the SAME verdict the downloader actually produces,
    /// end to end. Walks ModelManager.verificationPlan (the real decision) into ModelCardCopy (the real
    /// copy) and asserts the card says "SHA-256" exactly when a hash was genuinely compared. A future
    /// `ModelVerification` case that skips a hash but is rendered as verified fails here.
    func testCardClaimsAChecksumExactlyWhenTheDownloaderComparedOne() {
        let hash = String(repeating: "a", count: 64)
        let cases: [(pinned: String?, linked: String?)] = [
            (hash, nil),            // catalog pin
            (nil, hash),            // Hugging Face X-Linked-Etag
            (hash, hash),           // both: the pin wins, still hashed
            (nil, nil),             // neither: GGUF magic only
            ("", ""),               // empty headers are not hashes
        ]
        for c in cases {
            let plan = ModelManager.verificationPlan(pinnedSHA256: c.pinned, linkedSHA256: c.linked)
            let status = ModelCardCopy.installedStatus(plan.outcome)
            let hashed = plan.expected != nil
            XCTAssertEqual(plan.outcome.isHashVerified, hashed,
                           "verdict \(plan.outcome) disagrees with whether a hash was compared")
            XCTAssertEqual(status.contains("SHA-256"), hashed,
                           "pinned=\(String(describing: c.pinned)) linked=\(String(describing: c.linked)) "
                           + "→ \"\(status)\"")
            XCTAssertEqual(ModelCardCopy.installedNote(plan.outcome) == nil, hashed)
        }
    }
}
