// TextDirectionDetector — detects whether the text near the caret is Right-to-Left, so the ghost can
// be anchored on the correct side of the caret. Pure (no AppKit), testable in isolation.
//
// Walks the string backwards because the characters closest to the caret are the strongest signal for
// which direction the continuation will render. Returns at the first strong directional character;
// falls back to LTR when none is found (digits, punctuation, whitespace are neutral).
import Foundation

enum TextDirectionDetector {
    // True when the dominant script near the end of `text` is Right-to-Left (Arabic, Hebrew, etc.).
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars.reversed() {
            if isStrongRTL(scalar) { return true }
            if isStrongLTR(scalar) { return false }
        }
        return false
    }

    private static func isStrongRTL(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // Hebrew, Arabic, Syriac, Thaana, NKo, Arabic Extended-A — one contiguous block (0590–08FF).
        if v >= 0x0590 && v <= 0x08FF { return true }
        // Hebrew/Arabic presentation forms (FB1D–FDFF) and Arabic Presentation Forms-B (FE70–FEFF).
        if v >= 0xFB1D && v <= 0xFDFF { return true }
        if v >= 0xFE70 && v <= 0xFEFF { return true }
        // Explicit RTL marks.
        if v == 0x200F || v == 0x061C { return true }
        return false
    }

    private static func isStrongLTR(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v >= 0x0041 && v <= 0x005A { return true }   // Latin A–Z
        if v >= 0x0061 && v <= 0x007A { return true }   // Latin a–z
        if v >= 0x00C0 && v <= 0x024F { return true }   // Latin-1 Supplement + Extended-A/B
        if v >= 0x0370 && v <= 0x03FF { return true }   // Greek
        if v >= 0x0400 && v <= 0x04FF { return true }   // Cyrillic
        // CJK / Hangul / Kana are left-to-right for our anchoring purposes.
        if v >= 0x3040 && v <= 0x9FFF { return true }
        if v >= 0xAC00 && v <= 0xD7AF { return true }
        return false
    }
}
