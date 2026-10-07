// Snippets — user-defined text expansions (`;sig` -> "Best,\nDarío"). Pure logic only: trigger
// detection, name matching, placeholder expansion and the ghost preview. Persistence lives in
// SnippetStore; the coordinator shows a match as a ghost and Tab replaces the typed `;name` run with
// the expansion via Injector.replaceBeforeCaret — the same path as the `:shortcode` emoji ghost, and
// like emoji a snippet accept counts 0 words (never touches the WordMeter or the style profile).
//
// Design decisions:
// - Trigger is `;` + name. `;` never collides with the emoji `:` trigger, and prose almost never has a
//   `;` glued to the FRONT of a word ("this; that" puts the space after it). Like emoji, the sigil must
//   start a token (start of the prefix or after whitespace), so `x;y`, `a;sig` and `&nbsp;` never arm.
// - Names are 1–32 letters/digits/`_`/`-`, matched case-insensitively (stored lowercased). An exact
//   name wins; otherwise a typed prefix that matches exactly ONE name shows that snippet (`;si` ->
//   `sig` when nothing else starts with "si"). Ambiguous prefixes show nothing.
// - Placeholders are deliberately minimal: `{date}` and `{time}`, formatted in the user's locale and
//   time zone at the moment the ghost is shown. No clipboard placeholder — a snippet must never be a
//   way to splat the pasteboard into an arbitrary field.
import Foundation

struct Snippet: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var expansion: String

    init(id: UUID = UUID(), name: String, expansion: String) {
        self.id = id
        self.name = name
        self.expansion = expansion
    }

    // A hand-edited file may omit the id; mint one rather than dropping the snippet.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        expansion = try c.decode(String.self, forKey: .expansion)
    }
}

// A snippet ready to show: the rendered expansion plus the exact typed run (`;` + name as typed) the
// accept must delete. `typedRun` keeps the user's original casing so its lengths match the field.
struct SnippetMatch: Equatable {
    let name: String
    let expansion: String
    let typedRun: String

    // AX range unit for the atomic before-caret replace.
    var replaceUTF16Length: Int { typedRun.utf16.count }
    // Delete-press count for the ordered CGEvent fallback (one per grapheme).
    var replaceKeystrokeCount: Int { typedRun.count }
}

enum SnippetTrigger {
    static let sigil: Character = ";"
    static let maxNameLength = 32

    // The partial name typed after the last token-starting `;`, as typed (not lowercased), or nil.
    // nil for an empty query (`... ;`), a `;` glued to a preceding character, or a run containing
    // anything other than name characters (a space ends the run, so `;sig ` no longer triggers).
    static func currentQuery(prefix: String) -> String? {
        guard let sigil = prefix.lastIndex(of: sigil) else { return nil }
        if sigil != prefix.startIndex {
            guard prefix[prefix.index(before: sigil)].isWhitespace else { return nil }
        }
        let after = prefix[prefix.index(after: sigil)...]
        guard !after.isEmpty, after.count <= maxNameLength else { return nil }
        for ch in after where !isNameChar(ch) { return nil }
        return String(after)
    }

    static func isTrigger(prefix: String) -> Bool {
        currentQuery(prefix: prefix) != nil
    }

    // Canonical stored form of a user-entered name: trimmed + lowercased, or nil when it is empty, too
    // long, or contains a non-name character (spaces included — a name is one token).
    static func normalizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name.count <= maxNameLength, name.allSatisfy(isNameChar) else { return nil }
        return name
    }

    // The snippet the typed query selects: exact (case-insensitive) name first, else the single name
    // the query is a prefix of. nil when nothing — or more than one name — matches.
    static func bestMatch(query: String, in snippets: [Snippet]) -> Snippet? {
        let q = query.lowercased()
        guard !q.isEmpty else { return nil }
        if let exact = snippets.first(where: { $0.name.lowercased() == q }) { return exact }
        let candidates = snippets.filter { $0.name.lowercased().hasPrefix(q) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    // Everything the coordinator needs in one pure call: detect the trigger in `prefix`, pick the
    // snippet, render its placeholders at `now`. nil when there's nothing to offer.
    static func match(prefix: String, snippets: [Snippet], now: Date,
                      locale: Locale = .current, timeZone: TimeZone = .current) -> SnippetMatch? {
        guard !snippets.isEmpty,
              let query = currentQuery(prefix: prefix),
              let snippet = bestMatch(query: query, in: snippets) else { return nil }
        let expansion = SnippetPlaceholders.expand(snippet.expansion, now: now,
                                                   locale: locale, timeZone: timeZone)
        guard !expansion.isEmpty else { return nil }
        return SnippetMatch(name: snippet.name, expansion: expansion,
                            typedRun: String(sigil) + query)
    }

    private static func isNameChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_" || ch == "-"
    }
}

enum SnippetPlaceholders {
    static let date = "{date}"
    static let time = "{time}"

    // `template` with `{date}` / `{time}` rendered at `now` (medium date, short time, in `locale` and
    // `timeZone`). Line endings are normalized to LF and insertion junk is stripped so the result is
    // safe to hand straight to the Injector. Any other `{...}` text is left verbatim.
    static func expand(_ template: String, now: Date,
                       locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var text = template
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.contains(date) {
            text = text.replacingOccurrences(of: date, with: format(now, date: .medium, time: .none,
                                                                    locale: locale, timeZone: timeZone))
        }
        if text.contains(time) {
            text = text.replacingOccurrences(of: time, with: format(now, date: .none, time: .short,
                                                                    locale: locale, timeZone: timeZone))
        }
        return TextSanitizer.removingControlJunk(text)
    }

    private static func format(_ now: Date, date: DateFormatter.Style, time: DateFormatter.Style,
                               locale: Locale, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = date
        f.timeStyle = time
        return f.string(from: now)
    }
}

enum SnippetPreview {
    // The overlay draws ONE line, so a multi-line expansion is previewed with `↵` marking each line
    // break and an ellipsis once it outgrows the overlay's payload cap. Display only — accept always
    // inserts the full expansion.
    static func ghostText(for expansion: String,
                          maxCharacters: Int = OverlayRenderer.maxRenderedPayloadCharacters) -> String {
        let flat = expansion
            .split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: " ↵ ")
        guard maxCharacters > 1, flat.count > maxCharacters else { return flat }
        return String(flat.prefix(maxCharacters - 1)) + "…"
    }
}
