// SentenceBoundary — Tier 1 (KeyType ADR-013/014): a pure, multilingual, context-aware judge for
// where a ghost completion may end on a sentence. Replaces the old "stop on any . ! ?" which
// truncated on decimals (3.14), version strings (v1.2), URLs (google.com), numbered/abbreviated
// runs (Mr., e.g.), and single initials (J. Smith) — and was blind to non-Latin terminators
// (CJK 。！？, Arabic ۔ ؟, Devanagari danda ।॥, Ethiopic ።). No model/format dependency, so the
// whole policy is unit-tested without loading a model. Consulted by InferenceEngine's ghost decode
// loop via firstStopIndex(in:before:).
enum SentenceBoundary {

    // Terminators that ALWAYS end a sentence — no Latin-period ambiguity. Clause separators
    // (, 、 ، ， ; ；) are deliberately excluded: they punctuate within a sentence, not end it.
    static let hardTerminators: Set<Character> = [
        "!", "?",                  // ASCII
        "。", "！", "？",            // CJK ideographic full stop + fullwidth ! ?
        "।", "॥",                  // Devanagari danda / double danda
        "۔", "؟",                  // Arabic full stop / question mark
        "።", "፧", "፨",             // Ethiopic full stop / question / paragraph separator
        "។",                       // Khmer khan
        "‼", "⁇", "⁈", "⁉", "‽",   // double-bang / question combos / interrobang
    ]

    // Lowercased words (sans trailing period) after which a period does NOT end the sentence. Small,
    // high-frequency, multilingual (en/de/es/ca/fr) set — kept short on purpose; the cost of missing
    // one is a slightly-early stop, not a run-on.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "sra", "srta", "jr", "st", "vs", "etc", "cf", "al",
        "fig", "no", "núm", "vol", "pp", "pàg", "dept", "gen", "sen", "gov", "rev",
        "e.g", "i.e", "a.m", "p.m", "u.s", "u.k", "p.ex", "p.e",
        "z.b", "d.h", "u.a", "bzw", "ggf", "usw", "ca", "approx", "inc", "ltd", "co",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sept", "sep", "oct", "nov", "dec",
    ]

    // Does the terminator `c` genuinely end a sentence, given the text immediately before it
    // (`before`, excluding the terminator) and the character right after (nil when not yet decoded —
    // the streaming tail)? Pure + the unit-tested core of the policy.
    static func isStop(terminator c: Character, before: Substring, after: Character?) -> Bool {
        if c == "." { return periodEndsSentence(before: before, after: after) }
        return hardTerminators.contains(c)
    }

    private static func periodEndsSentence(before: Substring, after: Character?) -> Bool {
        // Immediately followed by a letter or digit → inside a token, not a sentence end:
        // 3.14, v1.2, google.com, the first dot of "e.g".
        if let a = after, a.isLetter || a.isNumber { return false }
        // Trailing run of letters/dots = the current word ("Mr", "agree", "e.g").
        let word = String(before.reversed().prefix(while: { $0.isLetter || $0 == "." }).reversed())
        let bare = word.hasSuffix(".") ? String(word.dropLast()) : word
        if abbreviations.contains(bare.lowercased()) { return false }
        // Single uppercase initial "J." — one letter, preceded by a non-letter (start/space) → not a
        // stop ("J. Smith"). A multi-letter trailing word ("agree.", "NJ.") falls through to a stop.
        let letterRun = before.reversed().prefix(while: { $0.isLetter })
        if letterRun.count == 1, let only = letterRun.first, only.isUppercase {
            let beforeInitial = before.dropLast(letterRun.count).last
            if beforeInitial == nil || !beforeInitial!.isLetter { return false }
        }
        // Streaming tail: a digit right before the period with nothing decoded after it may be a
        // decimal split across tokens ("3","." ,"14") — defer rather than truncate "3." → "3".
        if after == nil, before.last?.isNumber == true { return false }
        return true
    }

    // First index in `piece` of a terminator that genuinely ends a sentence, given `before` (the text
    // already accumulated up to this piece, for boundary context that began before the token). nil =
    // no sentence-ending boundary in this piece.
    static func firstStopIndex(in piece: String, before: String) -> String.Index? {
        var i = piece.startIndex
        while i < piece.endIndex {
            let next = piece.index(after: i)
            let after: Character? = next < piece.endIndex ? piece[next] : nil
            if isStop(terminator: piece[i], before: before + piece[piece.startIndex..<i], after: after) {
                return i
            }
            i = next
        }
        return nil
    }
}
