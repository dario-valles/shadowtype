// PromptSectionBudget — pure character-budget allocator for the base-model prompt.
//
// Why this exists: the prompt carries optional leading context (instruction, style hint, clipboard,
// screen OCR) ahead of the caret text the model must continue. An unbounded concatenation can crowd
// out that caret text or blow the context window — the documented word-salad failure mode. This
// allocator lets each section declare a priority and a min/max char budget; allocate() fills sections
// highest-priority-first within a total budget and truncates each to fit, so the caret text (given the
// top priority and a guaranteed minimum) is never starved by a noisy screen capture.
//
// Cost is measured in UTF-8 BYTES, not Swift Characters: a byte count is a closer proxy for tokens
// than a grapheme count (an emoji or CJK glyph is one Character but several bytes / often several
// tokens), so a byte budget can't be silently blown by multi-byte context the way a Character budget
// could. Truncation still happens on grapheme boundaries so a multi-scalar character is never split.
// Pure and deterministic (no tokenizer dependency); swappable for a real token count later.
struct PromptSection: Equatable {
    // Which end to keep when the content must be shortened. `preserveEnd` keeps the tail (the text
    // nearest the caret — right for the prefix and for screen context that trails the conversation);
    // `preserveStart` keeps the head.
    enum Truncation: Equatable { case preserveStart, preserveEnd }

    let name: String
    var content: String
    // Higher priority is filled (and kept) first when the budget is tight.
    let priority: Int
    // If the remaining budget can't fit at least this many bytes, the section is dropped rather than
    // included as a uselessly-tiny fragment. 0 means "include whatever fits".
    let minChars: Int
    let maxChars: Int
    let truncation: Truncation
}

enum PromptSectionBudget {
    // Fills sections by priority (descending; ties broken by original order for determinism) within
    // `totalChars`. Each section is capped at min(maxChars, contentLength, remainingBudget), dropped if
    // that is below its minChars, and dropped if it trims to empty. Surviving sections are returned in
    // their ORIGINAL order so the caller keeps control of render order independently of fill priority.
    static func allocate(_ sections: [PromptSection], totalChars: Int) -> [PromptSection] {
        var remaining = max(0, totalChars)

        let fillOrder = sections.enumerated().sorted { lhs, rhs in
            if lhs.element.priority != rhs.element.priority {
                return lhs.element.priority > rhs.element.priority
            }
            return lhs.offset < rhs.offset
        }

        // index-in-original-array → trimmed content, for sections that survive.
        var kept: [Int: String] = [:]
        for entry in fillOrder {
            let section = entry.element
            let cap = min(section.maxChars, cost(section.content), remaining)
            if cap < section.minChars { continue }            // not enough room to be useful
            let trimmed = truncate(section.content, toCost: cap, end: section.truncation)
            if trimmed.isEmpty { continue }
            kept[entry.offset] = trimmed
            remaining -= cost(trimmed)
        }

        return sections.enumerated().compactMap { offset, section in
            guard let content = kept[offset] else { return nil }
            var copy = section
            copy.content = content
            return copy
        }
    }

    // UTF-8 byte cost of a string (the budget unit).
    static func cost(_ s: String) -> Int { s.utf8.count }

    // Keep as many whole graphemes from the requested end as fit within `limit` BYTES, so a multi-byte
    // character is never split mid-scalar.
    private static func truncate(_ text: String, toCost limit: Int, end: PromptSection.Truncation) -> String {
        guard cost(text) > limit else { return text }
        guard limit > 0 else { return "" }
        var out = ""
        var used = 0
        switch end {
        case .preserveStart:
            for ch in text {
                let c = ch.utf8.count
                if used + c > limit { break }
                out.append(ch); used += c
            }
            return out
        case .preserveEnd:
            for ch in text.reversed() {
                let c = ch.utf8.count
                if used + c > limit { break }
                out.insert(ch, at: out.startIndex); used += c
            }
            return out
        }
    }
}
