// TypoGuard — FR-CE-6 (Free half): fast, offline heuristic that flags the last typed
// token as a likely mid-typing typo so the coordinator can SUPPRESS the suggestion
// (Cotypist's "hold back on typo"). This is NOT autocorrect (paid/deferred) — it only
// answers yes/no. Bias is conservative: false on normal words, proper nouns, short
// words, numbers, code-ish tokens. A false positive merely skips one suggestion; a
// false negative just lets a suggestion fire off a misspelling — so we err toward false.
//
// The authority on "is this a real word" is the on-device system dictionary (NSSpellChecker,
// offline, already linked via AppKit). Everything below only judges words the dictionary REJECTS.
import AppKit

final class TypoGuard {
    // Tiny built-in lexicon of very common English words. Used only as an edit-distance
    // anchor for words the system dictionary already rejected: a 4+ letter misspelling that is
    // exactly one edit away from a common word is almost certainly that word being mistyped
    // ("becuase"->"because", "thier"->"their"). Kept small on purpose — it is a nearness anchor,
    // NOT a word list: treating "not in this set" as "misspelled" is exactly the bug that made the
    // guard suppress the ghost on 38/38 ordinary English words (weeks, must, form, hers, ...).
    //
    // Note the canonical "teh"->"the" case never reaches here: "teh" is 3 letters and the n >= 4
    // gate in looksLikeTypo() drops it first. That is deliberate — lowering the gate to 3 floods
    // false positives across the huge space of valid 3-letter words/abbrevs, and the cost of a
    // missed flag is only one un-suppressed suggestion. Autocorrect's own floor is 3 (it has a
    // concrete target to justify the fix), but the coordinator only consults it AFTER looksLikeTypo
    // has already said yes — so the 3-letter case is reachable in Autocorrect's unit tests, not in
    // the product.
    private static let common: Set<String> = [
        "the", "and", "that", "have", "for", "not", "with", "you", "this", "but",
        "his", "from", "they", "she", "her", "will", "would", "there", "their",
        "what", "about", "which", "when", "make", "like", "time", "just", "him",
        "know", "take", "into", "your", "some", "could", "them", "than", "then",
        "look", "only", "come", "over", "think", "also", "back", "after", "use",
        "two", "how", "our", "work", "first", "well", "way", "even", "want",
        "because", "any", "these", "give", "most", "thing", "where", "much",
        "should", "very", "people", "through", "before", "here", "still", "such",
        "being", "while", "going", "good", "great", "right", "place", "again",
        "world", "really", "something", "another", "between", "without", "always",
        "different", "thanks", "please", "hello", "today", "tomorrow", "yesterday",
        "email", "message", "meeting", "project", "team", "year", "day", "week",
    ]

    /// True if `lastWord` looks like a typo currently being typed. Conservative.
    func looksLikeTypo(lastWord: String) -> Bool {
        let raw = lastWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }

        // Only judge plain alphabetic words. Anything with digits/punctuation/symbols
        // (URLs, code, file names, hyphenates, contractions) is out of scope -> not a typo.
        guard raw.allSatisfy({ $0.isLetter }) else { return false }
        // Every remaining signal is specific to English spelling (ASCII vowel inventory, consonant
        // clusters, and the English common-word anchors). Do not apply it to another script merely
        // because that script's letters are absent from the English vowel set.
        guard isLatinScriptToken(raw) else { return false }

        let lower = raw.lowercased()
        let chars = Array(lower)
        let n = chars.count

        // Short words are too ambiguous to flag (lots of valid 1–3 letter words/abbrevs).
        guard n >= 4 else { return false }

        // Proper nouns: a single leading capital with the rest lowercase is likely a name —
        // never flag (avoids suppressing on legitimate proper nouns). ALL-CAPS acronyms too.
        if isLikelyProperNounOrAcronym(raw) { return false }

        // Real-word gate: if the system dictionary spells this word correctly, it is not a typo —
        // full stop. This MUST run before every signal below, not just before the edit-distance one:
        // signal 3 flags real words with long consonant runs ("lengths", "strengths" — 5 consonants)
        // and signal 2 flags vowel-less real tokens ("brrr", "psst"). We check the word as typed
        // rather than the lowercased form so correctly-cased tokens the exclusions let through
        // ("iPhone") are judged as the user wrote them.
        if TypoGuard.isRealWord(raw) { return false }

        // Signal 1: improbable same-letter run (3+ identical letters in a row).
        // e.g. "helllo", "abbbout". Real English maxes at 2 ("ll", "ss").
        if hasRun(chars, ofAtLeast: 3) { return true }

        // Signal 2: no vowels at all in a 4+ letter word. e.g. "wrk", "thnk", "qwrt".
        // (y counts as a vowel here to spare "rhythm", "myths"... though those are <4 rare).
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        if !chars.contains(where: { vowels.contains($0) }) { return true }

        // Signal 3: long consonant cluster (4+ consonants in a row). e.g. "thgnk", "schrt".
        if longestConsonantRun(chars, vowels: vowels) >= 4 { return true }

        // Signal 4: the word is misspelled (the dictionary said so above) AND is exactly one edit
        // from a common word -> almost certainly that word being mistyped. The nearness requirement
        // is what keeps us off the names, jargon and foreign words the dictionary simply doesn't
        // carry: suppressing the ghost on every unknown token would be far too aggressive.
        if isOneEditFromCommon(lower) { return true }

        return false
    }

    // MARK: - System dictionary

    /// True when the on-device system dictionary spells `word` correctly in ANY of the languages we
    /// consult. Shared with Autocorrect so the Free suppressor and the paid corrector apply the exact
    /// same "is this a real word" test and can never drift apart.
    ///
    /// Threading: NSSpellChecker is AppKit and main-thread-affine. Every caller reaches here from
    /// CompletionCoordinator.fire(), which only ever runs on main — the debounce posts it via
    /// DispatchQueue.main.asyncAfter, forceActivate() comes off the hotkey/menu handlers, and the
    /// context re-fire runs inside MainActor.run — so we call the shared checker directly, with no
    /// hop and no cache. Cost is one word per typing pause: ~0.2ms when a dictionary accepts it (we
    /// stop at the first hit), ~1.3ms worst case walking the whole list for a genuine typo.
    static func isRealWord(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        return spellLanguages.contains { language in
            // checkSpelling returns the range of the first MISSPELLING; a correctly-spelled word
            // yields "none found".
            let miss = NSSpellChecker.shared.checkSpelling(
                of: word, startingAt: 0, language: language, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil)
            return miss.location == NSNotFound || miss.length == 0
        }
    }

    // The dictionaries isRealWord consults, resolved once on first use (~17ms, on the first typing
    // pause). We pass EXPLICIT languages instead of letting the checker auto-identify: language ID on
    // a single word is a coin flip, and falling back to the UI locale would flag every Spanish or
    // Catalan word as an English typo and kill the ghost for non-English users. Three rules, all
    // measured on a real machine:
    //   * English first — the lexicon and the edit-distance signal are English-only, and it is the
    //     language most tokens are in, so the any-dictionary check usually stops on the first call.
    //   * Then the user's OWN spelling languages (System Settings > Keyboard > Text Input > Spelling,
    //     which is what userPreferredLanguages reports), so a Spanish writer's words are real words.
    //   * DROP any language whose dictionary isn't actually installed. macOS lists those in
    //     availableLanguages anyway (ca, uk, ko, hi, ar, he, te on the dev box) and they answer "no
    //     misspelling" for EVERY input — including "thgnk" — so a single one of them in this list
    //     would silently disable the whole guard. We probe each with a garbage sentinel and keep only
    //     the dictionaries that reject it.
    // Catalan ships no macOS dictionary at all, so Catalan words rest on the remaining defences (the
    // Spanish dictionary accepts many of them, and signal 4 needs nearness to an English word).
    private static let spellLanguages: [String] = {
        let checker = NSSpellChecker.shared
        let available = checker.availableLanguages
        var candidates = available.filter { $0 == "en" }
        candidates += checker.userPreferredLanguages.filter {
            available.contains($0) && !candidates.contains($0)
        }
        return candidates.filter { language in
            checker.checkSpelling(of: "zzqxjvw", startingAt: 0, language: language, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).length > 0
        }
    }()

    // MARK: - Helpers (pure)

    private func isLikelyProperNounOrAcronym(_ s: String) -> Bool {
        let cs = Array(s)
        guard let first = cs.first else { return false }
        if cs.allSatisfy({ $0.isUppercase }) { return true } // acronym e.g. NASA
        if first.isUppercase && cs.dropFirst().allSatisfy({ $0.isLowercase }) { return true } // Name
        return false
    }

    private func isLatinScriptToken(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            // Latin, Latin-1 Supplement, Extended-A/B, and the later Latin extensions. This keeps
            // accented English and other Latin-script spelling languages eligible for the dictionary
            // gate while excluding Arabic, Hebrew, Cyrillic, and every other non-Latin script.
            case 0x0041...0x005A, 0x0061...0x007A,
                 0x00C0...0x024F, 0x1E00...0x1EFF,
                 0x2C60...0x2C7F, 0xA720...0xA7FF,
                 0xAB30...0xAB6F, 0xFB00...0xFB06:
                return true
            default:
                return false
            }
        }
    }

    private func hasRun(_ chars: [Character], ofAtLeast k: Int) -> Bool {
        guard chars.count >= k else { return false }
        var run = 1
        for i in 1..<chars.count {
            run = chars[i] == chars[i - 1] ? run + 1 : 1
            if run >= k { return true }
        }
        return false
    }

    private func longestConsonantRun(_ chars: [Character], vowels: Set<Character>) -> Int {
        var best = 0, run = 0
        for c in chars {
            if vowels.contains(c) { run = 0 } else { run += 1; best = max(best, run) }
        }
        return best
    }

    private func isOneEditFromCommon(_ word: String) -> Bool {
        // Exact match is a correct word, not a typo.
        if TypoGuard.common.contains(word) { return false }
        for candidate in TypoGuard.common where abs(candidate.count - word.count) <= 1 {
            if isEditDistanceOne(word, candidate) { return true }
        }
        return false
    }

    /// True iff `a` and `b` are exactly one insertion, deletion, substitution, or adjacent
    /// transposition apart (Damerau). Transpositions ("teh"->"the", "thier"->"their") are the
    /// dominant mid-typing typo class, so we count them as a single edit.
    private func isEditDistanceOne(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        let (la, lb) = (x.count, y.count)
        if abs(la - lb) > 1 { return false }
        if la == lb {
            // Collect mismatch positions: 1 mismatch => substitution; exactly 2 adjacent
            // mismatches that swap => transposition.
            var mism: [Int] = []
            for i in 0..<la where x[i] != y[i] {
                mism.append(i)
                if mism.count > 2 { return false }
            }
            if mism.count == 1 { return true }
            if mism.count == 2, mism[1] == mism[0] + 1,
               x[mism[0]] == y[mism[1]], x[mism[1]] == y[mism[0]] { return true }
            return false
        }
        // Lengths differ by 1: check that the shorter embeds in the longer with one gap.
        let (shorter, longer) = la < lb ? (x, y) : (y, x)
        var i = 0, j = 0, skipped = false
        while i < shorter.count && j < longer.count {
            if shorter[i] == longer[j] {
                i += 1; j += 1
            } else {
                if skipped { return false }
                skipped = true
                j += 1
            }
        }
        return true
    }
}
