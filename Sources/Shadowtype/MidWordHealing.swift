// MidWordHealing — Tier 2a (KeyType ADR-019), pure half. When the caret sits mid-word at end of
// line ("…the weather is gre"), the model otherwise continues from a fragile SUBWORD state where a
// cheaper wrong token ("asy" → greasy) can outrank the right one ("at" → great). The fix: back the
// prompt up to the last clean word boundary, regenerate the whole word with the typed stem as a
// REQUIRED PREFIX (see RequiredPrefix, enforced in the sampler), then strip the re-emitted stem from
// what the ghost shows/inserts. This file is the model-free split/strip logic; it's unit-tested
// without llama. Bonus: the KV anchor (head) stays constant while the user types within a word, so
// the engine re-prefills fewer tokens per keystroke.
enum MidWordHealing {

    struct Split: Equatable { let head: String; let stem: String }

    // A "word" char for healing: anything the model would keep inside one token-word. Letters/digits
    // across scripts plus the underscore. Apostrophes/hyphens are NOT included — "don't"/"well-" are
    // better left to normal continuation than reconstructed.
    static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    // Longest stem healed when the caret sits in a space-less script (CJK / kana / Thai). There the
    // trailing word-char run is not a word but everything since the last full stop — routinely 10-24
    // chars — and every stem-consuming token still counts against the engine's maxTokens (16 at the
    // medium preset), so healing the whole run spends most of the generation budget re-emitting text
    // the user already typed. A few characters are enough to steer the word the caret is inside.
    static let maxSpacelessStem = 4

    // Split `prefix` into (head, stem) when it ends mid-word: `stem` is the trailing run of word
    // chars, `head` is everything before it (ending at the last boundary). nil when the caret is not
    // mid-word (prefix ends in whitespace/punctuation, or there's no word run), or the stem is longer
    // than `maxStem` (a long run is almost certainly a complete word — healing it just burns the
    // constraint for no gain, and risks reconstructing a different long word). A space-less-script run
    // is trimmed to `maxSpacelessStem` instead of rejected: whitespace never breaks it, so the
    // `maxStem` rule would either reject every healed CJK caret or heal a whole clause.
    static func split(prefix: String, maxStem: Int = 24) -> Split? {
        guard let last = prefix.last, isWordChar(last) else { return nil }
        var stem = String(prefix.reversed().prefix(while: isWordChar).reversed())
        guard !stem.isEmpty else { return nil }
        if SentenceBoundary.isSpacelessScript(last) {
            stem = String(stem.suffix(maxSpacelessStem))
        } else if stem.count > maxStem {
            return nil
        }
        return Split(head: String(prefix.dropLast(stem.count)), stem: stem)
    }

    // Strip the regenerated `stem` off the front of the model's `emitted` text so the ghost shows only
    // the NEW characters ("great" with stem "gre" → "at"). nil when `emitted` doesn't begin with the
    // stem — under the required-prefix constraint it always should, but fail safe so a constraint
    // miss never shows a glued fragment ("greatat").
    static func strip(stem: String, from emitted: String) -> String? {
        guard emitted.hasPrefix(stem) else { return nil }
        return String(emitted.dropFirst(stem.count))
    }
}
