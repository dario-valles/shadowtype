// M2 (live completion loop + accept) unit tests. These need NO TCC grants and NO GGUF model:
// they exercise pure logic — WordMeter counting + local-midnight rollover (FR-ST-1/FR-IN-5),
// the prefix-extension / KV-reuse decision (FR-CE-5), and the coordinator's guard/cancel
// behavior (FR-CE-4) when the engine is unloaded (the off-thread inference path is never
// reached, so no model is required).
import XCTest
import AppKit
@testable import Shadowtype

final class M2LoopTests: XCTestCase {

    // MARK: - WordMeter.wordCount (FR-IN-5: a word = maximal run of non-whitespace)

    func testWordCountBasic() {
        XCTAssertEqual(WordMeter.wordCount(in: "hello world"), 2)
        XCTAssertEqual(WordMeter.wordCount(in: " world"), 1)        // leading space ignored
        XCTAssertEqual(WordMeter.wordCount(in: "one  two   three"), 3) // collapsed runs
        XCTAssertEqual(WordMeter.wordCount(in: ""), 0)
        XCTAssertEqual(WordMeter.wordCount(in: "   \n\t "), 0)       // pure whitespace
        XCTAssertEqual(WordMeter.wordCount(in: "trailing "), 1)
        XCTAssertEqual(WordMeter.wordCount(in: "a\nb\tc"), 3)        // newline/tab are separators
    }

    func testWordCountCountsPunctuationGluedToWordAsOne() {
        // "quick," is a single non-whitespace run -> 1 word (matches the accept-injection unit).
        XCTAssertEqual(WordMeter.wordCount(in: "quick,"), 1)
        XCTAssertEqual(WordMeter.wordCount(in: "the quick, brown"), 3)
    }

    // MARK: - WordMeter local-midnight rollover + HMAC anti-tamper (FR-ST-1, PRD §4.1)

    // Hermetic: each test uses its own temp meter file and a known secret via the injectable
    // init(storeURL:secret:), so we never touch the real Keychain or Application Support. We seed
    // controlled state with WordMeter.makeSignedRecordData (the same HMAC the engine uses).
    private static let testSecret = Data(repeating: 0x5A, count: 32)
    private static let otherSecret = Data(repeating: 0x17, count: 32)

    private func tempMeterURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-meter-\(UUID().uuidString).json")
    }

    private func localDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // Seed a signed record at `url`; returns the url. `lastSeen` defaults to `date`.
    @discardableResult
    private func seed(_ url: URL, date: String, count: Int, lastSeen: String? = nil,
                      secret: Data = testSecret) -> URL {
        let data = WordMeter.makeSignedRecordData(date: date, count: count,
                                                  lastSeenMaxDate: lastSeen ?? date, secret: secret)
        try? data.write(to: url, options: .atomic)
        return url
    }

    func testRolloverResetsOnStaleDate() {
        let url = tempMeterURL(); defer { try? FileManager.default.removeItem(at: url) }
        let yesterday = localDateString(Date().addingTimeInterval(-86_400))
        seed(url, date: yesterday, count: 42)
        let meter = WordMeter(storeURL: url, secret: Self.testSecret)
        XCTAssertEqual(meter.todayCount(), 0, "stale-date store must reset at local midnight")
    }

    func testSameDayCountPersists() {
        let url = tempMeterURL(); defer { try? FileManager.default.removeItem(at: url) }
        seed(url, date: localDateString(Date()), count: 17)
        let meter = WordMeter(storeURL: url, secret: Self.testSecret)
        XCTAssertEqual(meter.todayCount(), 17, "same-day store must NOT reset")
    }

    func testIncrementAccumulatesAndIgnoresZero() {
        let url = tempMeterURL(); defer { try? FileManager.default.removeItem(at: url) }
        seed(url, date: localDateString(Date()), count: 0)
        let meter = WordMeter(storeURL: url, secret: Self.testSecret)
        meter.increment(by: 0)       // no-op (emoji/empty accepts)
        XCTAssertEqual(meter.todayCount(), 0)
        meter.increment(by: 3)
        meter.increment(by: 2)
        XCTAssertEqual(meter.todayCount(), 5)
    }

    func testIncrementPersistsAcrossInstances() {
        let url = tempMeterURL(); defer { try? FileManager.default.removeItem(at: url) }
        seed(url, date: localDateString(Date()), count: 0)
        WordMeter(storeURL: url, secret: Self.testSecret).increment(by: 4)   // write + re-sign
        XCTAssertEqual(WordMeter(storeURL: url, secret: Self.testSecret).todayCount(), 4,
                       "count must survive a reload (FR-ST-1)")
    }

    // MARK: - HMAC integrity (PRD §4.1 anti-tamper)

    func testForgedCountIsRejectedAndResets() {
        // A file signed with a DIFFERENT secret (or hand-edited) fails the HMAC check on load and
        // the counter resets — a free user can't lower `count` by editing the file.
        let url = tempMeterURL(); defer { try? FileManager.default.removeItem(at: url) }
        seed(url, date: localDateString(Date()), count: 5, secret: Self.otherSecret)  // wrong key
        let meter = WordMeter(storeURL: url, secret: Self.testSecret)
        XCTAssertEqual(meter.todayCount(), 0, "tampered/forged record must fail HMAC and reset")
    }

    func testValidlySignedRecordPassesIntegrity() {
        let url = tempMeterURL(); defer { try? FileManager.default.removeItem(at: url) }
        seed(url, date: localDateString(Date()), count: 9, secret: Self.testSecret)   // correct key
        let meter = WordMeter(storeURL: url, secret: Self.testSecret)
        XCTAssertEqual(meter.todayCount(), 9, "correctly-signed record must be trusted")
    }

    // MARK: - Clock-rollback guard (PRD §4.1)

    func testClockRollbackGrantsNoFreeReset() {
        // Seed a high-water date in the FUTURE relative to the real clock: this models having
        // previously observed a later day, then the system clock being rolled back to "today".
        // effectiveToday = max(today, lastSeen) stays pinned to the high-water, so record.date is
        // unchanged and the count is NOT reset — rolling the clock back buys nothing.
        let url = tempMeterURL(); defer { try? FileManager.default.removeItem(at: url) }
        let future = "2999-01-01"
        seed(url, date: future, count: 50, lastSeen: future)
        let meter = WordMeter(storeURL: url, secret: Self.testSecret)
        XCTAssertEqual(meter.todayCount(), 50, "clock rolled back below high-water -> no free reset")
    }

    func testGenuineNewDayStillResets() {
        // A real forward day change (today > both stored date and high-water) DOES reset to 0.
        let url = tempMeterURL(); defer { try? FileManager.default.removeItem(at: url) }
        let past = "2000-01-01"
        seed(url, date: past, count: 70, lastSeen: past)
        let meter = WordMeter(storeURL: url, secret: Self.testSecret)
        XCTAssertEqual(meter.todayCount(), 0, "advancing to a genuinely later day resets the count")
    }

    // MARK: - Prefix-extension / KV-reuse decision (FR-CE-5)

    // The warm path reuses the KV cache up to the longest common prefix of the old and new token
    // streams, then prefills only the diverging suffix (forward-from-caret, FINDINGS Spike 1/2).
    // This is the decision the engine's prefix-reuse prefill will make; lock the math here so the
    // contract holds when InferenceEngine grows a real reuse entry point.
    private func commonPrefixLen<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return i
    }

    func testStrictExtensionReusesEntirePreviousPrefix() {
        let old = Array("The quick brown".utf8)
        let new = Array("The quick brownf".utf8)   // strict extension: append only
        let reuse = commonPrefixLen(old, new)
        XCTAssertEqual(reuse, old.count, "extending keeps the whole previous prefix warm")
        XCTAssertEqual(new.count - reuse, 1, "only the appended byte needs prefilling")
    }

    func testDivergenceTrimsBackToBranchPoint() {
        let old = Array("The quick brown".utf8)
        let new = Array("The quack".utf8)           // diverges after "The qu"
        let reuse = commonPrefixLen(old, new)
        XCTAssertEqual(reuse, "The qu".utf8.count)
        XCTAssertLessThan(reuse, old.count, "divergence must trim the cache below the old length")
    }

    func testBackspaceShrinkIsNotAStrictExtension() {
        // Deleting a char yields a prefix that is shorter than the cached one: common == new.count,
        // so the cache is trimmed to the new length (no cold reprefill of the surviving prefix).
        let old = Array("The quick brown".utf8)
        let new = Array("The quick brow".utf8)
        let reuse = commonPrefixLen(old, new)
        XCTAssertEqual(reuse, new.count)
        XCTAssertEqual(new.count - reuse, 0, "a shrink reuses everything still present")
    }

    // MARK: - InferenceEngine.reuseLength contract (FR-CE-5) — the engine's real reuse decision

    // Mirrors commonPrefixLen but with the engine's two extra invariants: (1) never reuse the whole
    // `new` stream — keep at most new.count-1 so the last token is re-evaluated for fresh logits;
    // (2) clamp to what is actually cached. Pure Int32 math, no model needed.
    func testReuseLengthStrictExtensionKeepsAllCached() {
        // cached is a strict prefix of new -> keep every cached token, prefill only the appended tail.
        XCTAssertEqual(InferenceEngine.reuseLength(cached: [1, 2, 3], new: [1, 2, 3, 4, 5]), 3)
    }

    func testReuseLengthIdenticalPromptStillReEvalsLastToken() {
        // Same tokens both sides: reuse caps at count-1 so the final token is reprefilled (logits).
        XCTAssertEqual(InferenceEngine.reuseLength(cached: [1, 2, 3], new: [1, 2, 3]), 2)
    }

    func testReuseLengthDivergenceTrimsToBranchPoint() {
        XCTAssertEqual(InferenceEngine.reuseLength(cached: [1, 2, 3, 4, 5], new: [1, 2, 9, 9]), 2)
    }

    func testReuseLengthBackspaceShrinkReusesSurvivingPrefix() {
        // new is shorter; cap at new.count-1 -> reuse everything still present minus the last token.
        XCTAssertEqual(InferenceEngine.reuseLength(cached: [1, 2, 3, 4, 5], new: [1, 2, 3]), 2)
    }

    func testReuseLengthEmptyNewIsZero() {
        XCTAssertEqual(InferenceEngine.reuseLength(cached: [1, 2, 3], new: []), 0)
    }

    func testReuseLengthColdCacheIsZero() {
        XCTAssertEqual(InferenceEngine.reuseLength(cached: [], new: [1, 2, 3]), 0)
    }

    // MARK: - InferenceEngine.splitTrailingPartial (Option 2 — clean word boundary, FR-CE-3)

    func testSplitTrailingPartialKeepsCompleteWordsDropsFragment() {
        let (complete, partial) = InferenceEngine.splitTrailingPartial("the quick brown fo")
        XCTAssertEqual(complete, "the quick brown ")
        XCTAssertEqual(partial, "fo")
    }

    func testSplitTrailingPartialNoInteriorSpaceIsAllPartial() {
        let (complete, partial) = InferenceEngine.splitTrailingPartial("incomplete")
        XCTAssertEqual(complete, "")
        XCTAssertEqual(partial, "incomplete")
    }

    func testSplitTrailingPartialTrailingSpaceMeansNoFragment() {
        let (complete, partial) = InferenceEngine.splitTrailingPartial("done word ")
        XCTAssertEqual(complete, "done word ")
        XCTAssertEqual(partial, "")
    }

    // MARK: - No word cap (free + unlimited)

    func testWordCapAlwaysFullOpacity() {
        // Shadowtype is free and unlimited: suggestions never fade or suppress for a word cap.
        XCTAssertEqual(WordCap.opacity(), 1)
    }

    @MainActor
    func testCoordinatorHasNoCap() {
        let url = tempMeterURL(); defer { try? FileManager.default.removeItem(at: url) }
        seed(url, date: localDateString(Date()), count: 99_999)   // huge count: still no cap
        let meter = WordMeter(storeURL: url, secret: Self.testSecret)
        let c = CompletionCoordinator(engine: InferenceEngine(),
                                      overlay: OverlayRenderer(),
                                      context: EditContextTracker())
        c.wordMeter = meter

        // Never suppressed, no daily cap, always licensed.
        XCTAssertFalse(c.isSuppressedByCap)
        XCTAssertNil(c.dailyCap)
        XCTAssertTrue(c.isLicensed)
    }

    // MARK: - Base-model output sanitizer (strip web-corpus markup the PT model leaks)

    func testSanitizerStripsHTMLTags() {
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("<strong>Paris</strong>, the capital"),
                       "Paris, the capital")
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("use the <code>get_data</code> function"),
                       "use the get_data function")
    }

    func testSanitizerDropsTrailingIncompleteTagWhileStreaming() {
        // Mid-stream a tag arrives before its '>' — drop it so it never flashes; it returns stripped
        // once the closing '>' streams in.
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("Paris <stro"), "Paris ")
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("Paris <strong>"), "Paris ")
    }

    func testSanitizerKeepsLiteralLessThan() {
        // A '<' not followed by a letter/'/' is real text, not a tag.
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("if a < b then"), "if a < b then")
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("score <3 you"), "score <3 you")
    }

    func testSanitizerRemovesMarkdownEmphasis() {
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("**bold** and `code`"), "bold and code")
    }

    func testSanitizerIsIdempotent() {
        // The post-accept remainder re-render runs the sanitizer again; it must be a no-op.
        let once = CompletionCoordinator.sanitizedSuggestion("<strong>Paris</strong> **is** nice")
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion(once), once)
    }

    func testSanitizerLeavesPlainProseUntouched() {
        let plain = "you taking the time to read my message."
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion(plain), plain)
    }

    // MARK: - Instruct-template placeholder + rule-run strip (scenario eval: gemma-instruct
    // emits "[Insert ...]" / "---" scaffolding on complete-looking or instruction-like prefixes)

    func testSanitizerStripsBracketPlaceholders() {
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("[insert what you are apologizing for]."), ".")
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("Sincerely,\n[Your Name]"), "Sincerely,\n")
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("[Insertar la información aquí] gracias"), " gracias")
    }

    func testSanitizerKeepsNumericCitations() {
        // "[1]" / "[42]" hold no letter — a real citation, not a placeholder — and must survive.
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("see ref [1] below"), "see ref [1] below")
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("note [42]"), "note [42]")
    }

    func testSanitizerStripsUnclosedTrailingPlaceholder() {
        // Streaming may cut mid-placeholder; drop the dangling "[Insert..." remainder.
        XCTAssertEqual(CompletionCoordinator.sanitizedSuggestion("Best, [Your Na"), "Best, ")
    }

    func testStrippingRuleRunsRemovesHorizontalRules() {
        XCTAssertEqual(CompletionCoordinator.strippingRuleRuns("done\n---\nmore"), "done\n\nmore")
        XCTAssertEqual(CompletionCoordinator.strippingRuleRuns("===="), "")
        XCTAssertEqual(CompletionCoordinator.strippingRuleRuns("a___b"), "ab")
    }

    func testStrippingRuleRunsKeepsShortRuns() {
        // Prose double-dash and two-char runs are not rules.
        for s in ["wait -- really?", "a == b", "x__y"] {
            XCTAssertEqual(CompletionCoordinator.strippingRuleRuns(s), s, "must not strip \(s)")
        }
    }

    func testSignoffScaffoldingCollapsesToLowValue() {
        // The full pipeline on the observed "Best regards,\n" continuation: "[Your Name]\n\n---\n**[Your Name]**".
        let cleaned = CompletionCoordinator.sanitizedSuggestion("[Your Name]\n\n---\n**[Your Name]**")
        XCTAssertFalse(cleaned.contains("["))
        XCTAssertFalse(cleaned.contains("---"))
        XCTAssertFalse(cleaned.contains("*"))
    }

    // MARK: - List-marker strip + low-value guard (kills "but " -> "1. 1." in Slack)

    func testStrippingLeadingListMarkerRemovesOneMarker() {
        XCTAssertEqual(CompletionCoordinator.strippingLeadingListMarker("1. hello"), "hello")
        XCTAssertEqual(CompletionCoordinator.strippingLeadingListMarker("  10) text"), "text")
        XCTAssertEqual(CompletionCoordinator.strippingLeadingListMarker("- item"), "item")
        XCTAssertEqual(CompletionCoordinator.strippingLeadingListMarker("* item"), "item")
        XCTAssertEqual(CompletionCoordinator.strippingLeadingListMarker("• note"), "note")
        // At most one marker — a nested "1. 2. x" keeps the inner marker as content.
        XCTAssertEqual(CompletionCoordinator.strippingLeadingListMarker("1. 2. x"), "2. x")
    }

    func testStrippingLeadingListMarkerLeavesProseUntouched() {
        for s in ["3 PM works", "2 days ago", "4.5 stars", "3.14 is pi", "$5 off", "but then"] {
            XCTAssertEqual(CompletionCoordinator.strippingLeadingListMarker(s), s, "must not strip \(s)")
        }
    }

    func testIsLowValueSuggestionTrueForMarkerNoise() {
        for s in ["1. 1.", "1.", "- -", "•", "1) 2)", "   ", ""] {
            XCTAssertTrue(CompletionCoordinator.isLowValueSuggestion(s), "should be low value: \(s)")
        }
    }

    func testIsLowValueSuggestionFalseForRealProse() {
        for s in ["but then", "3 days left", "hello world"] {
            XCTAssertFalse(CompletionCoordinator.isLowValueSuggestion(s), "should keep: \(s)")
        }
    }

    func testIsLowValueSuggestionKeepsMeaningfulNumbers() {
        // Finding #6: the letterless gate must NOT eat useful numeric/time/price completions.
        for s in ["10:00?", "200.00", "3.14", "1,500", "$5", "42"] {
            XCTAssertFalse(CompletionCoordinator.isLowValueSuggestion(s), "should keep numeric: \(s)")
        }
    }

    func testIsLowValueSuggestionStillKillsSingleDigitMarkers() {
        // Single-digit list-marker noise stays low-value (no 2+ digit run / decimal / time / currency).
        for s in ["1.", "1) 2)", "1. 1.", "9)"] {
            XCTAssertTrue(CompletionCoordinator.isLowValueSuggestion(s), "should kill marker: \(s)")
        }
    }

    func testListMarkerPipelineHidesRepeatedMarker() {
        // The Slack bug: raw "1. 1." -> sanitize -> strip one marker -> "1." -> low value -> hidden.
        let stripped = CompletionCoordinator.strippingLeadingListMarker(
            CompletionCoordinator.sanitizedSuggestion("1. 1."))
        XCTAssertTrue(CompletionCoordinator.isLowValueSuggestion(stripped))
    }

    // MARK: - Prefix-duplicate guard (kill the loop-back stutter)

    func testPrefixDuplicateCatchesSingleAndMultiWordOverlap() {
        XCTAssertTrue(CompletionCoordinator.isPrefixDuplicate(suggestion: "for reading", prefix: "thanks for "))
        XCTAssertTrue(CompletionCoordinator.isPrefixDuplicate(suggestion: "thanks for reading", prefix: "thanks for "))
        XCTAssertTrue(CompletionCoordinator.isPrefixDuplicate(suggestion: "think again", prefix: "I think"))
        // case-insensitive
        XCTAssertTrue(CompletionCoordinator.isPrefixDuplicate(suggestion: "The best", prefix: "the "))
    }

    func testPrefixDuplicateLeavesGenuineContinuation() {
        XCTAssertFalse(CompletionCoordinator.isPrefixDuplicate(suggestion: "we should ship", prefix: "I think "))
        XCTAssertFalse(CompletionCoordinator.isPrefixDuplicate(suggestion: "is great", prefix: "New York "))
        XCTAssertFalse(CompletionCoordinator.isPrefixDuplicate(suggestion: "world", prefix: ""))
    }

    // MARK: - Paragraph-break stop sequence

    func testTruncatedAtParagraphBreakCutsAfterContent() {
        XCTAssertEqual(CompletionCoordinator.truncatedAtParagraphBreak("first line\n\n1. a\n2. b"), "first line")
        // single newline is preserved (acceptLine still works)
        XCTAssertEqual(CompletionCoordinator.truncatedAtParagraphBreak("line one\nline two"), "line one\nline two")
        // leading blank lines (no content yet) are left intact for the caller's leading-newline drop
        XCTAssertEqual(CompletionCoordinator.truncatedAtParagraphBreak("\n\nHello"), "\n\nHello")
        XCTAssertEqual(CompletionCoordinator.truncatedAtParagraphBreak("plain text"), "plain text")
    }

    // MARK: - Complete-statement no-show

    func testEndsCompleteStatement() {
        for s in ["Thanks. ", "Done! ", "Right? ", "Okay.  "] {
            XCTAssertTrue(CompletionCoordinator.endsCompleteStatement(s), "should skip: \(s)")
        }
        for s in ["3.14 ", "I think ", "Hello.", "thanks for ", ""] {
            XCTAssertFalse(CompletionCoordinator.endsCompleteStatement(s), "should fire: \(s)")
        }
    }

    // MARK: - Coordinator guard / cancel behavior (FR-CE-4) — no model, no TCC

    @MainActor
    private func makeCoordinator() -> CompletionCoordinator {
        // engine is unloaded (no model), so onKeystroke()/fire() short-circuit on `engine.isLoaded`
        // and never touch the inference queue — exercising the guard logic without a GGUF.
        let c = CompletionCoordinator(engine: InferenceEngine(),
                                      overlay: OverlayRenderer(),
                                      context: EditContextTracker())
        c.injector = Injector()
        c.wordMeter = WordMeter(storeURL: tempMeterURL(), secret: Self.testSecret)  // hermetic
        return c
    }

    @MainActor
    func testOnKeystrokeIsInertWhenEngineUnloaded() {
        let c = makeCoordinator()
        XCTAssertFalse(c.isEnabled == false)   // default enabled
        // Should not crash, schedule no work that fires (engine not loaded), and emit no suggestion.
        c.onKeystroke()
        XCTAssertEqual(c.acceptWord(), 0, "no suggestion visible -> nothing to accept")
        XCTAssertEqual(c.acceptLine(), 0)
    }

    @MainActor
    func testAcceptIsNoOpWithoutVisibleSuggestion() {
        let c = makeCoordinator()
        XCTAssertEqual(c.acceptWord(), 0)
        XCTAssertEqual(c.acceptLine(), 0)
    }

    @MainActor
    func testDisabledCoordinatorDoesNotFire() {
        let c = makeCoordinator()
        c.isEnabled = false
        c.onKeystroke()                         // guarded out before scheduling debounce work
        XCTAssertEqual(c.acceptWord(), 0)
    }

    @MainActor
    func testForceActivateIsInertWhenEngineUnloaded() {
        // forceActivate() guards on engine.isLoaded just like onKeystroke(); with no model it must be a
        // safe no-op (no crash, no suggestion). The idle-bypass behavior itself is exercised by
        // ActivationPolicyTests (pure) — here we only pin the guard + that it leaves nothing to accept.
        let c = makeCoordinator()
        c.forceActivate()
        XCTAssertEqual(c.acceptWord(), 0)
        XCTAssertEqual(c.acceptLine(), 0)
    }

    @MainActor
    func testCancelClearsToIdleQuickly() {
        // FR-CE-4 / task: cancel-to-idle must be fast (<16ms). cancel() only flips flags + hides
        // the overlay; here we assert it is well under one frame even with no suggestion present.
        let c = makeCoordinator()
        let start = Date()
        c.cancel()
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        XCTAssertLessThan(elapsedMs, 16.0, "cancel-to-idle should be sub-frame (<16ms)")
        XCTAssertEqual(c.acceptWord(), 0, "cancel leaves no visible suggestion")
    }

    // MARK: - CompletionCoordinator.lastWord (FR-CE-6: TypoGuard input)

    func testLastWordExtractsTrailingToken() {
        // The last whitespace-delimited token of the prefix is what TypoGuard judges.
        XCTAssertEqual(CompletionCoordinator.lastWord(of: "hello world"), "world")
        XCTAssertEqual(CompletionCoordinator.lastWord(of: "single"), "single")
        XCTAssertEqual(CompletionCoordinator.lastWord(of: "the becuase"), "becuase")
        // A trailing space means the user just finished a word -> no current token to judge.
        XCTAssertEqual(CompletionCoordinator.lastWord(of: "done "), "")
        XCTAssertEqual(CompletionCoordinator.lastWord(of: ""), "")
        // Newlines/tabs are separators too.
        XCTAssertEqual(CompletionCoordinator.lastWord(of: "line one\nteh"), "teh")
        XCTAssertEqual(CompletionCoordinator.lastWord(of: "a\tb"), "b")
    }
}
