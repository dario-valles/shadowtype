// Autocorrect — FR-AC-1 (paid): the upgrade to TypoGuard's Free suppress behavior.
// Where TypoGuard (FR-CE-6 Free half) merely answers "does this look like a typo?" and the
// coordinator HOLDS BACK the suggestion, Autocorrect OFFERS a concrete fix for the mistyped
// trailing token (Cotypist's paid autocorrect). This is a PURE engine — no AX, no UI, no LLM —
// so it is fully unit-testable; the coordinator wires it into the existing typo branch (gated on
// `isLicensed` + the autocorrect toggle).
//
// Bias is the same as TypoGuard's, only flipped in cost: a WRONG correction (silently rewriting a
// word the user meant) is far worse than NO correction, so every path here is conservative. We only
// return a fix that is exactly one edit (Damerau-Levenshtein distance 1) from a known lexicon word,
// and only when that fix is unambiguous (a single confident candidate). Anything short, ALL-CAPS,
// proper-noun-like, or containing digits/symbols is left untouched.
import Foundation

struct Autocorrect {
    // Common-word lexicon used as the correction target set. This intentionally mirrors (and lightly
    // extends) TypoGuard's `common` lexicon — that set is `private` to TypoGuard, so we replicate it
    // here. See integrationNotes: ideally TypoGuard's lexicon would be promoted to a single shared
    // source so the Free suppressor and the paid corrector can never drift apart. The list is small on
    // purpose — this is a high-confidence fixer for everyday typos, not a full dictionary speller.
    private static let defaultLexicon: Set<String> = [
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
        // Words whose classic misspellings ("recieve", "seperate", "definately") are common enough
        // that a corrector — unlike a mere typo flag — earns its keep by carrying them.
        "receive", "separate", "definitely", "necessary", "occurred", "tomorrow",
        "until", "friend", "little", "people", "really", "weird", "field", "believe",
        "achieve", "calendar", "across", "actually", "address", "available", "began",
        "business", "course", "during", "enough", "every", "important", "interest",
        "though", "thought", "together", "usually", "writing", "written",
    ]

    private let lexicon: Set<String>

    /// `lexicon` defaults to the built-in common-word set. A caller may inject a larger or
    /// domain-specific set (the coordinator could eventually pass the user's accepted-words list).
    init(lexicon: Set<String>? = nil) {
        self.lexicon = lexicon ?? Autocorrect.defaultLexicon
    }

    /// The best single-word correction for `word`, or nil when no confident fix exists.
    ///
    /// Returns nil — leaving the word untouched — when the token is:
    ///   * already a known/correctly-spelled word,
    ///   * too short to judge (< 4 letters, lots of valid 1–3 letter words/abbrevs),
    ///   * not purely alphabetic (URLs, code, file names, contractions, hyphenates, numbers),
    ///   * an ALL-CAPS acronym or a single-leading-capital proper-noun-like token,
    ///   * or has no single confident lexicon word exactly one Damerau edit away (zero, or ambiguous
    ///     ties between equally-near candidates).
    ///
    /// On success the suggestion preserves the ORIGINAL word's leading capitalization, so "Teh"
    /// corrects to "The" and "teh" to "the". (FR-AC-1)
    func correction(for word: String) -> String? {
        let raw = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // Out of scope: anything with digits/punctuation/symbols (mirror TypoGuard) — never rewrite.
        guard raw.allSatisfy({ $0.isLetter }) else { return nil }

        let chars = Array(raw)
        // Short tokens are too ambiguous to safely rewrite. We allow 3 letters (vs TypoGuard's 4):
        // a corrector has a confident unique TARGET to justify the fix (e.g. the canonical "teh"->"the"),
        // whereas the Free flag had no target and so stayed at 4. 1–2 letter tokens are still skipped —
        // far too many valid short words/abbrevs.
        guard chars.count >= 3 else { return nil }

        // Proper nouns (single leading capital) and ALL-CAPS acronyms are left alone (mirror
        // TypoGuard's exclusion) — these are the most expensive class to get wrong.
        if Autocorrect.isLikelyProperNounOrAcronym(chars) { return nil }

        let lower = raw.lowercased()
        // Already a correct word -> nothing to fix.
        if lexicon.contains(lower) { return nil }

        // Gather every lexicon word exactly one Damerau-Levenshtein edit away. Demand a UNIQUE
        // candidate: if two distinct words are both one edit away we cannot confidently pick, so we
        // decline (a wrong pick is worse than none).
        var match: String?
        for candidate in lexicon where abs(candidate.count - lower.count) <= 1 {
            guard Autocorrect.isDamerauDistanceOne(lower, candidate) else { continue }
            if let existing = match, existing != candidate {
                return nil // ambiguous: 2+ confident candidates -> decline
            }
            match = candidate
        }

        guard let fix = match else { return nil }
        return Autocorrect.applyingLeadingCase(of: raw, to: fix)
    }

    // MARK: - Helpers (pure)

    // Mirrors TypoGuard.isLikelyProperNounOrAcronym: ALL-CAPS => acronym (NASA); single leading
    // capital with the rest lowercase => likely a name (Dario). Both are excluded from correction.
    private static func isLikelyProperNounOrAcronym(_ cs: [Character]) -> Bool {
        guard let first = cs.first else { return false }
        if cs.allSatisfy({ $0.isUppercase }) { return true }
        if first.isUppercase && cs.dropFirst().allSatisfy({ $0.isLowercase }) { return true }
        return false
    }

    // If the original word began with an uppercase letter (and the rest were lowercase we'd have bailed
    // as a proper noun, so this fires only for mixed/odd casing the exclusions let through), uppercase
    // the suggestion's first letter so "Teh" -> "The". Otherwise return the lowercase lexicon form.
    private static func applyingLeadingCase(of original: String, to corrected: String) -> String {
        guard let first = original.first, first.isUppercase else { return corrected }
        return corrected.prefix(1).uppercased() + corrected.dropFirst()
    }

    /// True iff `a` and `b` are exactly one insertion, deletion, substitution, or adjacent
    /// transposition apart (Damerau distance 1). Transpositions ("teh"->"the", "thier"->"their") are
    /// the dominant mid-typing typo class, so they count as a single edit. Identical strings return
    /// false (distance 0 is not a correction). Mirrors TypoGuard.isEditDistanceOne.
    static func isDamerauDistanceOne(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        let (la, lb) = (x.count, y.count)
        if abs(la - lb) > 1 { return false }
        if la == lb {
            // Collect mismatch positions: 1 mismatch => substitution; exactly 2 adjacent mismatches
            // that swap => transposition. 0 mismatches => identical => not a correction.
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
        // Lengths differ by 1: the shorter must embed in the longer with exactly one gap.
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
