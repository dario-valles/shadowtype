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

    // Tail window whose START only moves in `anchor`-byte steps — the byte-level twin of the engine's
    // anchored token trim (InferenceEngine.trimToWindow).
    //
    // Why not just keep the last `maxCost` bytes: a plain `.preserveEnd` truncation slides its start
    // forward by one byte on EVERY keystroke, so the assembled prompt is never a strict extension of the
    // previous one. The engine's KV reuse is a longest-common-PREFIX match (InferenceEngine.reuseLength),
    // so a one-byte slide diverges the streams at the first prefix token and forces a full cold re-prefill
    // of the whole window on every fire — the exact per-keystroke cold-prefill this pass exists to kill,
    // just relocated from the engine's trim to the allocator's.
    //
    // Rounding the DROP up to a multiple of `anchor` pins the window start until the text grows past the
    // next multiple, so the prompt is byte-stable (a strict extension) for ~`anchor` bytes at a time and
    // one cold prefill amortizes over hundreds of keystrokes. Costs at most `anchor` bytes of kept context
    // versus the naive window — cheap next to a re-prefill per keystroke.
    // The granularity anchoredTail re-anchors at. Rounding up costs at most one step of kept content, so
    // the step stays small relative to the window — a 512-byte step against a 650-byte cap would throw
    // away most of the caret text. Exposed because a caller that budgets OTHER sections around the
    // windowed content must quantize its reservation to the SAME step, or its own arithmetic reintroduces
    // the per-keystroke drift this whole mechanism exists to remove (see quantizedReservation).
    static func anchorStep(maxCost: Int, anchor: Int = 512) -> Int {
        max(1, min(anchor, maxCost / 4))
    }

    // How many bytes to set aside for a section of `cost` bytes that is capped at `maxCost`, rounded UP to
    // the anchor step. anchoredTail pins the kept window's START, but its LENGTH still grows a byte per
    // keystroke — so a budget computed from the live cost shrinks a byte per keystroke, and any section
    // allocated from the remainder gets re-cut every fire. When that section sits in FRONT of the caret
    // text (all of them do), that is a mutating prompt head and a cold re-prefill on every keystroke.
    // Quantizing holds the reservation still between re-anchors while still shrinking to fit a short
    // prefix, so the context blocks are not starved when the draft is small.
    static func quantizedReservation(cost: Int, maxCost: Int, anchor: Int = 512) -> Int {
        guard maxCost > 0, cost > 0 else { return 0 }
        let step = anchorStep(maxCost: maxCost, anchor: anchor)
        return min(maxCost, ((cost + step - 1) / step) * step)
    }

    static func anchoredTail(_ s: String, maxCost: Int, anchor: Int = 512) -> String {
        let total = cost(s)
        guard total > maxCost else { return s }
        guard maxCost > 0 else { return "" }
        let minDrop = total - maxCost
        let step = anchorStep(maxCost: maxCost, anchor: anchor)
        // Round the drop UP so the kept window is never larger than maxCost.
        let drop = ((minDrop + step - 1) / step) * step
        guard drop < total else { return "" }
        return truncate(s, toCost: total - drop, end: .preserveEnd)
    }

    // Head window: as many whole graphemes from the START as fit in `maxCost` bytes. The mirror of
    // anchoredTail for content whose USEFUL end is the head — today the post-caret block, where the text
    // nearest the caret is what the completion must not duplicate and the far end is the droppable part.
    // Needs no anchoring: unlike the prefix, this content does not grow at the kept end while the user
    // types, so a fixed-cost head cut is already byte-stable across a burst.
    static func headWithinCost(_ s: String, maxCost: Int) -> String {
        truncate(s, toCost: max(0, maxCost), end: .preserveStart)
    }

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
