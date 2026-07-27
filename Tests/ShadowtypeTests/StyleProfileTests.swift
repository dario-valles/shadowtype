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

    // styleHint() stays silent below `minInputsForHint` accepts (a profile built from two sentences is
    // noise), so every test that asserts on hint CONTENT has to train past that floor first.
    private func train(_ p: StyleProfile, _ phrases: [String], bundleId: String? = nil,
                       rounds: Int = StyleProfile.minInputsForHint) {
        for _ in 0..<rounds {
            for phrase in phrases { p.recordAccepted(phrase, bundleId: bundleId) }
        }
    }

    private static let hintPrefix = "User writing style — favors: "

    // The hint's items, so tests can assert on what was emitted rather than on substrings of the line.
    private func hintItems(_ hint: String) -> [String] {
        guard hint.hasPrefix(Self.hintPrefix) else { return [] }
        return String(hint.dropFirst(Self.hintPrefix.count)).components(separatedBy: "; ")
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
        train(p, ["Thanks so much for reaching out", "Happy to help with that"])
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

    // MARK: - Evidence floor: a tiny profile describes nobody

    func testTinyCorpusYieldsNoHint() {
        // Three sentences is not a writing style, and the hint it would produce costs prompt budget that
        // the real context needs — stay silent until there is enough material.
        let p = profile(tempURL())
        p.recordAccepted("kindly regards always")
        p.recordAccepted("looking forward to hearing back")
        p.recordAccepted("happy to help with that")
        XCTAssertNil(p.styleHint(maxChars: 400), "3 inputs must not produce a style hint")
    }

    func testHintAppearsExactlyAtTheEvidenceFloor() {
        let p = profile(tempURL())
        for _ in 0..<(StyleProfile.minInputsForHint - 1) { p.recordAccepted("kindly regards always") }
        XCTAssertNil(p.styleHint(maxChars: 400), "below the floor the hint must stay nil")
        p.recordAccepted("kindly regards always")
        XCTAssertNotNil(p.styleHint(maxChars: 400), "at the floor the hint must appear")
    }

    // MARK: - Vocabulary-only: no verbatim content / digit bleed (FR-CTX-3 anti-regurgitation)

    func testHintDoesNotSurfaceVerbatimPhrase() {
        // The hint must carry register/vocabulary (short n-grams), NOT the verbatim multi-word phrase —
        // otherwise the base model parrots it across unrelated apps (Notes story -> Slack message).
        let p = profile(tempURL())
        let phrase = "una princesa vive en castillo"     // 5 words, learned, but never emitted whole
        train(p, [phrase])
        let hint = p.styleHint(maxChars: 400)
        XCTAssertNotNil(hint)
        XCTAssertFalse(hint!.contains(phrase), "verbatim phrase leaked into the style hint")
        XCTAssertTrue(hint!.contains("una princesa"), "short n-gram vocabulary should still surface")
    }

    func testHintExcludesDigitNGrams() {
        // Stray numerals (the old "2 …" garbage) are noise, not style — never surface them.
        let p = profile(tempURL())
        train(p, ["2 y el baile feliz"])
        let hint = p.styleHint(maxChars: 400)
        XCTAssertNotNil(hint)
        XCTAssertFalse(hint!.contains("2"), "digit n-gram leaked into the style hint")
    }

    func testLongPhrasingNotLearned() {
        // Above maxPhraseWords the input is content, not voice — ignored entirely. Fed well past the
        // evidence floor so a nil hint can only mean "never learned", not "not enough inputs yet".
        let p = profile(tempURL())
        train(p, ["this is a long sentence with definitely more than six words total"])
        XCTAssertNil(p.styleHint(maxChars: 300))
    }

    // MARK: - Distinctiveness: function words are not a writing style

    func testOrdinaryEnglishDoesNotProduceAStopwordHint() {
        // Ranked by raw frequency this corpus yields exactly "of the; the; and ..." — a line of English
        // glue that says nothing about the user, outranks the real screen context in the prompt budget,
        // and reads to a base model as document content to imitate. Every emitted item must carry at
        // least one content word.
        let p = profile(tempURL())
        train(p, [
            "the state of the art",
            "one of the best",
            "part of the team",
            "most of the time",
            "the end of the day",
            "the rest of the file",
        ])
        let hint = p.styleHint(maxChars: 400)
        XCTAssertNotNil(hint)
        let items = hintItems(hint!)
        XCTAssertFalse(items.isEmpty, "could not parse hint items from: \(hint!)")
        for item in items {
            XCTAssertGreaterThan(StyleProfile.contentTokenCount(item), 0,
                                 "pure-stopword item '\(item)' leaked into the style hint")
        }
        for junk in ["of the", "the", "and", "that", "in the", "to the"] {
            XCTAssertFalse(items.contains(junk), "'\(junk)' leaked into the style hint")
        }
    }

    func testDistinctiveVocabularyOutranksMoreFrequentGlue() {
        // The filler is fed MORE often than the distinctive phrasing on purpose: raw frequency would put
        // "is one" first, distinctiveness puts the two-content-word bigram first.
        let p = profile(tempURL())
        train(p, ["it is one of the"], rounds: StyleProfile.minInputsForHint * 2)
        train(p, ["kubernetes operator reconciled the pods"])
        let hint = p.styleHint(maxChars: 400)
        XCTAssertNotNil(hint)
        let items = hintItems(hint!)
        XCTAssertEqual(items.first, "kubernetes operator",
                       "distinctive vocabulary should lead the hint, got: \(items)")
        XCTAssertTrue(items.contains("kubernetes"), "distinctive words must still surface: \(items)")
    }

    func testContentTokenCountIgnoresFunctionWords() {
        XCTAssertEqual(StyleProfile.contentTokenCount("the"), 0)
        XCTAssertEqual(StyleProfile.contentTokenCount("of the"), 0)
        XCTAssertEqual(StyleProfile.contentTokenCount("de la"), 0)      // same trap in Spanish
        XCTAssertEqual(StyleProfile.contentTokenCount("the meeting"), 1)
        XCTAssertEqual(StyleProfile.contentTokenCount("una princesa"), 1)
        XCTAssertEqual(StyleProfile.contentTokenCount("baile feliz"), 2)
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
        train(p, ["hello there friend"])   // past the evidence floor: nil must be the cap's doing
        XCTAssertNil(p.styleHint(maxChars: 5)) // smaller than the leading label
        XCTAssertNil(p.styleHint(maxChars: 0))
    }

    // MARK: - Persistence round-trip across instances

    func testPersistsAcrossInstances() {
        let url = tempURL()
        do {
            let p = profile(url)
            // Both phrasings are <= maxPhraseWords so they are actually learned (the longer variant of
            // the first one used to be silently dropped, making this test assert on one phrase only).
            train(p, ["kindly let me know", "looking forward to hearing back"])
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
        train(p, ["some learned phrasing here"])
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
        // The evidence floor is on the MERGED total, so neither app alone has to clear it.
        train(p, ["kindly regards"], bundleId: "com.apple.mail", rounds: 4)
        train(p, ["lol yeah"], bundleId: "com.tinyspeck.slackmacgap", rounds: 4)
        let hint = p.styleHint(maxChars: 400)
        XCTAssertNotNil(hint)
        // Both apps' vocabulary contributes to the single merged hint.
        XCTAssertTrue(hint!.contains("kindly"))
        XCTAssertTrue(hint!.contains("yeah") || hint!.contains("lol"))
    }

    func testDeleteAppRemovesOnlyThatApp() {
        let p = profile(tempURL())
        train(p, ["kindly regards always"], bundleId: "com.apple.mail")
        train(p, ["lmao yeah totally"], bundleId: "com.tinyspeck.slackmacgap")
        p.deleteApp(bundleId: "com.apple.mail")
        XCTAssertEqual(p.inputCount(forBundleId: "com.apple.mail"), 0)
        XCTAssertEqual(p.inputCount(forBundleId: "com.tinyspeck.slackmacgap"),
                       StyleProfile.minInputsForHint)
        let hint = p.styleHint(maxChars: 400)
        XCTAssertNotNil(hint)
        XCTAssertFalse(hint!.contains("kindly"), "deleted app's vocabulary must not survive")
        XCTAssertTrue(hint!.contains("yeah") || hint!.contains("totally"))
    }

    func testPerAppPersistsAcrossInstances() {
        let url = tempURL()
        do {
            let p = profile(url)
            train(p, ["kindly let me know"], bundleId: "com.apple.mail")
            p.flushPendingWrites()
        }
        let reopened = profile(url)
        XCTAssertEqual(reopened.inputCount(forBundleId: "com.apple.mail"), StyleProfile.minInputsForHint)
        XCTAssertTrue(reopened.styleHint(maxChars: 300)?.contains("kindly") == true)
    }

    // MARK: - Migration of a pre-bucket (old global) file into `legacy`

    func testMigratesOldGlobalProfile() throws {
        let url = tempURL()
        // Write an OLD-shape record (top-level nGramCounts/recentPhrases, no perApp AND no inputCount),
        // sealed with the test secret exactly as the previous build would have.
        let learned = StyleProfile.minInputsForHint + 1
        let old: [String: Any] = [
            "nGramCounts": ["kindly": learned, "regards": learned, "kindly regards": learned],
            "recentPhrases": (0..<learned).map { "kindly regards \($0)" },
        ]
        let sealed = try AES.GCM.seal(JSONSerialization.data(withJSONObject: old),
                                      using: SymmetricKey(data: Self.testSecret)).combined!
        try sealed.write(to: url)

        let p = profile(url)   // first load migrates the old shape into `legacy`
        let hint = p.styleHint(maxChars: 300)
        // The old shape has no inputCount; it is backfilled from recentPhrases so a long-trained profile
        // isn't muted by the evidence floor on upgrade.
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
            train(p, ["unreadable phrasing under this key"])
            XCTAssertNotNil(p.styleHint(maxChars: 200))
            p.flushPendingWrites()
        }
        // Re-open the SAME file with a DIFFERENT secret -> decryption fails -> empty profile, no crash.
        let mismatched = profile(url, secret: Self.otherSecret)
        XCTAssertNil(mismatched.styleHint(maxChars: 200))

        // And it can still learn + persist under its own key afterward (overwrites the file).
        train(mismatched, ["fresh start under the new key"])
        XCTAssertNotNil(mismatched.styleHint(maxChars: 200))
        mismatched.flushPendingWrites()
        XCTAssertNotNil(profile(url, secret: Self.otherSecret).styleHint(maxChars: 200))
    }
}
