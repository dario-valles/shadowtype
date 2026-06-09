// StyleProfile — on-device, encrypted, user-wipeable writing-style personalization (PRD FR-CTX-3).
// Hermetic: every test uses its own temp store file + a known secret via the injectable
// init(storeURL:secret:), so we never touch the real Keychain or Application Support.
import XCTest
import CryptoKit
@testable import Shadowtype

final class StyleProfileTests: XCTestCase {
    private static let testSecret = Data(repeating: 0x5A, count: 32)
    private static let otherSecret = Data(repeating: 0x17, count: 32)

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-style-\(UUID().uuidString).bin")
    }

    private func profile(_ url: URL, secret: Data = testSecret) -> StyleProfile {
        StyleProfile(storeURL: url, secret: secret)
    }

    // MARK: - Empty profile

    func testEmptyProfileHintIsNil() {
        let p = profile(tempURL())
        XCTAssertNil(p.styleHint(maxChars: 200))
    }

    func testMissingFileLoadsEmpty() {
        let p = profile(tempURL()) // never written
        XCTAssertNil(p.styleHint(maxChars: 200))
    }

    // MARK: - Learning -> non-nil hint

    func testRecordingThenHintIsNonNil() {
        let p = profile(tempURL())
        p.recordAccepted("Thanks so much for reaching out")
        p.recordAccepted("Happy to help with that")
        let hint = p.styleHint(maxChars: 300)
        XCTAssertNotNil(hint)
        // The hint surfaces the user's own phrasing.
        XCTAssertTrue(hint?.contains("thanks") == true || hint?.contains("happy") == true)
    }

    func testEmptyAndWhitespaceInputAreIgnored() {
        let p = profile(tempURL())
        p.recordAccepted("")
        p.recordAccepted("   \n  ")
        XCTAssertNil(p.styleHint(maxChars: 200))
    }

    // MARK: - Vocabulary-only: no verbatim content / digit bleed (FR-CTX-3 anti-regurgitation)

    func testHintDoesNotSurfaceVerbatimPhrase() {
        // The hint must carry register/vocabulary (short n-grams), NOT the verbatim multi-word phrase —
        // otherwise the base model parrots it across unrelated apps (Notes story -> Slack message).
        let p = profile(tempURL())
        let phrase = "una princesa vive en castillo"     // 5 words, learned, but never emitted whole
        for _ in 0..<3 { p.recordAccepted(phrase) }
        let hint = p.styleHint(maxChars: 400)
        XCTAssertNotNil(hint)
        XCTAssertFalse(hint!.contains(phrase), "verbatim phrase leaked into the style hint")
        XCTAssertTrue(hint!.contains("una princesa"), "short n-gram vocabulary should still surface")
    }

    func testHintExcludesDigitNGrams() {
        // Stray numerals (the old "2 …" garbage) are noise, not style — never surface them.
        let p = profile(tempURL())
        for _ in 0..<3 { p.recordAccepted("2 y el baile feliz") }
        let hint = p.styleHint(maxChars: 400)
        XCTAssertNotNil(hint)
        XCTAssertFalse(hint!.contains("2"), "digit n-gram leaked into the style hint")
    }

    func testLongPhrasingNotLearned() {
        // Above maxPhraseWords the input is content, not voice — ignored entirely.
        let p = profile(tempURL())
        p.recordAccepted("this is a long sentence with definitely more than six words total")
        XCTAssertNil(p.styleHint(maxChars: 300))
    }

    // MARK: - maxChars respected

    func testHintRespectsMaxChars() {
        let p = profile(tempURL())
        for i in 0..<20 {
            p.recordAccepted("distinctive phrasing number \(i) here")   // <= maxPhraseWords
        }
        for cap in [40, 80, 160] {
            let hint = p.styleHint(maxChars: cap)
            XCTAssertNotNil(hint, "expected a hint at cap=\(cap)")
            XCTAssertLessThanOrEqual(hint!.count, cap, "hint exceeded maxChars=\(cap)")
        }
    }

    func testHintNilWhenMaxCharsTooSmallForPrefix() {
        let p = profile(tempURL())
        p.recordAccepted("hello there friend")
        XCTAssertNil(p.styleHint(maxChars: 5)) // smaller than the leading label
        XCTAssertNil(p.styleHint(maxChars: 0))
    }

    // MARK: - Persistence round-trip across instances

    func testPersistsAcrossInstances() {
        let url = tempURL()
        do {
            let p = profile(url)
            p.recordAccepted("kindly let me know if you have questions")
            p.recordAccepted("looking forward to hearing back")
            XCTAssertNotNil(p.styleHint(maxChars: 300))
            p.flushPendingWrites()   // writes are async; flush before reopening from disk
        }
        let reopened = profile(url) // same storeURL + secret
        let hint = reopened.styleHint(maxChars: 300)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("kindly") == true
                      || hint?.contains("looking forward") == true
                      || hint?.contains("forward") == true)
    }

    // MARK: - On-disk bytes are encrypted (not plaintext)

    func testOnDiskBytesAreEncrypted() throws {
        let url = tempURL()
        let secretPhrase = "supercalifragilistic phrasing token"
        let p = profile(url)
        p.recordAccepted(secretPhrase)
        p.flushPendingWrites()   // ensure the async encrypted write landed before reading the file

        let raw = try Data(contentsOf: url)
        XCTAssertFalse(raw.isEmpty)
        // The recorded phrase must NOT appear verbatim in the on-disk bytes -> it's encrypted.
        XCTAssertNil(raw.range(of: Data(secretPhrase.utf8)),
                     "recorded phrase found in plaintext on disk — store is not encrypted")
        XCTAssertNil(raw.range(of: Data("supercalifragilistic".utf8)),
                     "recorded token found in plaintext on disk — store is not encrypted")
    }

    // MARK: - Wipe

    func testWipeEmptiesAndRemovesFile() throws {
        let url = tempURL()
        let p = profile(url)
        p.recordAccepted("some learned phrasing here")
        p.flushPendingWrites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(p.styleHint(maxChars: 200))

        p.wipe()
        p.flushPendingWrites()   // the delete is enqueued on the persist queue
        XCTAssertNil(p.styleHint(maxChars: 200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // A reopened instance also sees the wiped (empty) state.
        XCTAssertNil(profile(url).styleHint(maxChars: 200))
    }

    func testWipeIsIdempotentWithNoFile() {
        let p = profile(tempURL()) // nothing written
        p.wipe() // must not throw/crash
        XCTAssertNil(p.styleHint(maxChars: 200))
    }

    // MARK: - Per-app buckets (counts, merge, delete)

    func testPerAppInputCounts() {
        let p = profile(tempURL())
        p.recordAccepted("thanks so much", bundleId: "com.apple.mail")
        p.recordAccepted("happy to help", bundleId: "com.apple.mail")
        p.recordAccepted("yo dude", bundleId: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(p.inputCount(forBundleId: "com.apple.mail"), 2)
        XCTAssertEqual(p.inputCount(forBundleId: "com.tinyspeck.slackmacgap"), 1)
        XCTAssertEqual(p.inputCount(forBundleId: "com.unknown.app"), 0)
    }

    func testHintMergesAcrossApps() {
        let p = profile(tempURL())
        p.recordAccepted("kindly regards", bundleId: "com.apple.mail")
        p.recordAccepted("lol yeah", bundleId: "com.tinyspeck.slackmacgap")
        let hint = p.styleHint(maxChars: 400)
        XCTAssertNotNil(hint)
        // Both apps' vocabulary contributes to the single merged hint.
        XCTAssertTrue(hint!.contains("kindly"))
        XCTAssertTrue(hint!.contains("yeah") || hint!.contains("lol"))
    }

    func testDeleteAppRemovesOnlyThatApp() {
        let p = profile(tempURL())
        p.recordAccepted("kindly regards always", bundleId: "com.apple.mail")
        p.recordAccepted("lmao yeah totally", bundleId: "com.tinyspeck.slackmacgap")
        p.deleteApp(bundleId: "com.apple.mail")
        XCTAssertEqual(p.inputCount(forBundleId: "com.apple.mail"), 0)
        XCTAssertEqual(p.inputCount(forBundleId: "com.tinyspeck.slackmacgap"), 1)
        let hint = p.styleHint(maxChars: 400)
        XCTAssertNotNil(hint)
        XCTAssertFalse(hint!.contains("kindly"), "deleted app's vocabulary must not survive")
        XCTAssertTrue(hint!.contains("yeah") || hint!.contains("totally"))
    }

    func testPerAppPersistsAcrossInstances() {
        let url = tempURL()
        do {
            let p = profile(url)
            p.recordAccepted("kindly let me know", bundleId: "com.apple.mail")
            p.flushPendingWrites()
        }
        let reopened = profile(url)
        XCTAssertEqual(reopened.inputCount(forBundleId: "com.apple.mail"), 1)
        XCTAssertTrue(reopened.styleHint(maxChars: 300)?.contains("kindly") == true)
    }

    // MARK: - Migration of a pre-bucket (old global) file into `legacy`

    func testMigratesOldGlobalProfile() throws {
        let url = tempURL()
        // Write an OLD-shape record (top-level nGramCounts/recentPhrases, no perApp), sealed with the
        // test secret exactly as the previous build would have.
        let oldJSON = #"{"nGramCounts":{"kindly":3,"kindly regards":2},"recentPhrases":["kindly regards"]}"#
        let sealed = try AES.GCM.seal(Data(oldJSON.utf8),
                                      using: SymmetricKey(data: Self.testSecret)).combined!
        try sealed.write(to: url)

        let p = profile(url)   // first load migrates the old shape into `legacy`
        let hint = p.styleHint(maxChars: 300)
        XCTAssertNotNil(hint, "migrated old profile should still produce a hint")
        XCTAssertTrue(hint!.contains("kindly"))
        // New per-app learning coexists with the migrated legacy data.
        p.recordAccepted("cheers mate", bundleId: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(p.inputCount(forBundleId: "com.tinyspeck.slackmacgap"), 1)
        XCTAssertTrue(p.styleHint(maxChars: 400)!.contains("kindly"))   // legacy survives the new write
    }

    // MARK: - Wrong secret fails closed

    func testWrongSecretLoadsEmptyNoCrash() {
        let url = tempURL()
        do {
            let p = profile(url, secret: Self.testSecret)
            p.recordAccepted("unreadable phrasing under this key")
            XCTAssertNotNil(p.styleHint(maxChars: 200))
            p.flushPendingWrites()
        }
        // Re-open the SAME file with a DIFFERENT secret -> decryption fails -> empty profile, no crash.
        let mismatched = profile(url, secret: Self.otherSecret)
        XCTAssertNil(mismatched.styleHint(maxChars: 200))

        // And it can still learn + persist under its own key afterward (overwrites the file).
        mismatched.recordAccepted("fresh start under the new key")
        XCTAssertNotNil(mismatched.styleHint(maxChars: 200))
        mismatched.flushPendingWrites()
        XCTAssertNotNil(profile(url, secret: Self.otherSecret).styleHint(maxChars: 200))
    }
}
