// TextSanitizer — the single definition of "insertion-unsafe" characters and how to remove them.
//
// Why this exists: small base models occasionally emit detokenizer junk — the U+FFFD replacement glyph
// (bytes the decoder couldn't map) or stray C0 control characters. That junk must never reach the host
// field. The earlier approach DISCARDED the whole suggestion if it contained any such scalar, which
// also threw away legitimate completions that merely carried a tab (code indentation) or a CR. This
// strips the junk instead, keeping the rest of the completion, and is applied both when cleaning the
// streamed text for display and again at the injection boundary so every inject path is safe (#1/#11).
//
// Tab (U+0009) and line feed (U+000A) are legitimate content (indentation, multi-line completions) and
// are preserved; carriage return and every other C0 control, DEL, and U+FFFD are removed.
import Foundation

enum TextSanitizer {
    // True when `scalar` must not be shown or inserted: U+FFFD, or a C0 control / DEL that isn't TAB/LF.
    static func isInsertionJunk(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\u{FFFD}" { return true }
        if scalar.value == 0x09 || scalar.value == 0x0A { return false }   // keep tab + line feed
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    // `text` with every insertion-unsafe scalar removed (tab/LF preserved). Idempotent.
    static func removingControlJunk(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isInsertionJunk) else { return text }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars where !isInsertionJunk(scalar) {
            out.append(scalar)
        }
        return String(out)
    }
}
