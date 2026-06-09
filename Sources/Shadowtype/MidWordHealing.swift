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

    // Split `prefix` into (head, stem) when it ends mid-word: `stem` is the trailing run of word
    // chars, `head` is everything before it (ending at the last boundary). nil when the caret is not
    // mid-word (prefix ends in whitespace/punctuation, or there's no word run), or the stem is longer
    // than `maxStem` (a long run is almost certainly a complete word — healing it just burns the
    // constraint for no gain, and risks reconstructing a different long word).
    static func split(prefix: String, maxStem: Int = 24) -> Split? {
        guard let last = prefix.last, isWordChar(last) else { return nil }
        let stem = String(prefix.reversed().prefix(while: isWordChar).reversed())
        guard !stem.isEmpty, stem.count <= maxStem else { return nil }
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
