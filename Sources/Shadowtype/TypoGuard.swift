// TypoGuard — FR-CE-6 (Free half): fast, offline heuristic that flags the last typed
// token as a likely mid-typing typo so the coordinator can SUPPRESS the suggestion
// (Cotypist's "hold back on typo"). This is NOT autocorrect (paid/deferred) — it only
// answers yes/no. Bias is conservative: false on normal words, proper nouns, short
// words, numbers, code-ish tokens. A false positive merely skips one suggestion; a
// false negative just lets a suggestion fire off a misspelling — so we err toward false.
import Foundation

final class TypoGuard {
    // Tiny built-in lexicon of very common English words. Used only as an edit-distance
    // anchor: a 4+ letter word that is exactly one edit away from a common word is almost
    // certainly that word being mistyped (e.g. "teh"->"the", "becuase"->"because").
    // Kept small on purpose — this is a signal, not a spell-checker.
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

        let lower = raw.lowercased()
        let chars = Array(lower)
        let n = chars.count

        // Short words are too ambiguous to flag (lots of valid 1–3 letter words/abbrevs).
        guard n >= 4 else { return false }

        // Proper nouns: a single leading capital with the rest lowercase is likely a name —
        // never flag (avoids suppressing on legitimate proper nouns). ALL-CAPS acronyms too.
        if isLikelyProperNounOrAcronym(raw) { return false }

        // Signal 1: improbable same-letter run (3+ identical letters in a row).
        // e.g. "helllo", "abbbout". Real English maxes at 2 ("ll", "ss").
        if hasRun(chars, ofAtLeast: 3) { return true }

        // Signal 2: no vowels at all in a 4+ letter word. e.g. "wrk", "thnk", "qwrt".
        // (y counts as a vowel here to spare "rhythm", "myths"... though those are <4 rare).
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        if !chars.contains(where: { vowels.contains($0) }) { return true }

        // Signal 3: long consonant cluster (4+ consonants in a row). e.g. "thgnk", "schrt".
        if longestConsonantRun(chars, vowels: vowels) >= 4 { return true }

        // Signal 4: edit-distance == 1 to a common word -> almost certainly that word
        // being mistyped. The strongest signal; gated to 4+ letters above to avoid noise.
        if isOneEditFromCommon(lower) { return true }

        return false
    }

    // MARK: - Helpers (pure)

    private func isLikelyProperNounOrAcronym(_ s: String) -> Bool {
        let cs = Array(s)
        guard let first = cs.first else { return false }
        if cs.allSatisfy({ $0.isUppercase }) { return true } // acronym e.g. NASA
        if first.isUppercase && cs.dropFirst().allSatisfy({ $0.isLowercase }) { return true } // Name
        return false
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
