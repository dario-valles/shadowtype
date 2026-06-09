// RewriteAction — the local "rewrite selected text" feature's pure core (prompt + output cleaning).
// Apple Writing Tools / Grammarly do this via the cloud; Shadowtype does it 100% on-device with the
// already-loaded model. The catalog ships mostly BASE (pretrained, non-instruct) GGUFs fed raw-prefix
// with NO chat template (see ModelCatalog), so an instruction directive ("Rewrite this formally") is
// unreliable — base models continue text, they don't obey commands. The robust path on the existing
// raw-prefix engine is FEW-SHOT CONTINUATION: a task line + one worked `Text:`→`Rewritten:` exemplar,
// then the user's selection, so the model just completes the established pattern. Works on base AND
// instruct models without any template plumbing. This type is PURE (no AX/UI/LLM) and unit-tested.
import Foundation

enum RewriteAction: String, CaseIterable, Identifiable {
    case improve
    case shorten
    case formal
    case casual
    case fixGrammar
    case summarize

    var id: String { rawValue }

    /// Title shown in the action menu.
    var title: String {
        switch self {
        case .improve:    return "Rewrite"
        case .shorten:    return "Make shorter"
        case .formal:     return "Make formal"
        case .casual:     return "Make casual"
        case .fixGrammar: return "Fix grammar"
        case .summarize:  return "Summarize"
        }
    }

    /// The instruction sentence that heads the few-shot prompt. "Keep the same language" guards against
    /// the cross-language drift base models sometimes emit (mirrors CompletionCoordinator.languageDrifts).
    private var task: String {
        switch self {
        case .improve:
            return "Rewrite the text below so it is clearer and reads better, keeping the same meaning and the same language."
        case .shorten:
            return "Rewrite the text below to be shorter and more concise, keeping the key information and the same language."
        case .formal:
            return "Rewrite the text below in a polished, formal, professional tone, keeping the same meaning and the same language."
        case .casual:
            return "Rewrite the text below in a relaxed, friendly, casual tone, keeping the same meaning and the same language."
        case .fixGrammar:
            return "Correct the spelling, grammar, and punctuation in the text below. Keep the wording and the language otherwise unchanged."
        case .summarize:
            return "Summarize the text below in one or two short sentences, in the same language."
        }
    }

    /// One worked exemplar (input, output) anchoring the transform for the base model.
    private var exemplar: (input: String, output: String) {
        switch self {
        case .improve:
            return ("i think the meeting it was kind of useful but we didnt really decide anything in the end",
                    "I think the meeting was fairly useful, though we didn't actually decide anything in the end.")
        case .shorten:
            return ("I just wanted to quickly check in and see whether you had perhaps had a chance to take a look at the document I sent over earlier this week.",
                    "Have you had a chance to look at the document I sent earlier this week?")
        case .formal:
            return ("hey can u send me that doc when u get a sec? thanks!",
                    "Could you please send me that document when you have a moment? Thank you.")
        case .casual:
            return ("Please find attached the requested report. Do not hesitate to contact me should you require anything further.",
                    "Here's the report you asked for — just give me a shout if you need anything else!")
        case .fixGrammar:
            return ("their going to there favorite resturant tomorow, i cant wait to see they're new menu.",
                    "They're going to their favorite restaurant tomorrow; I can't wait to see their new menu.")
        case .summarize:
            return ("The quarterly numbers came in above plan, driven mostly by stronger renewals and a one-off enterprise deal. Costs were flat, so margins improved. The team wants to reinvest the upside into hiring two more engineers next quarter.",
                    "Revenue beat plan on strong renewals and a large deal, margins improved, and the team plans to reinvest in two new engineering hires.")
        }
    }

    /// Build the raw-prefix few-shot prompt. `userTone` (the user's global/per-app instruction) is woven
    /// into the task line only when present — the caller passes nil for Free/no-instruction so the prompt
    /// shape is stable. `language` is the English name of the selection's detected language ("Spanish",
    /// "Catalan", …); when set, the second block uses a `Text (in <Lang>):` / `Rewritten (in <Lang>):`
    /// marker and the task line carries an explicit "Write the rewritten text in <Lang>." directive — the
    /// English exemplar can't carry the steer alone, so a base model otherwise mirrors it and emits
    /// English regardless of the selection. Pure + testable.
    static func prompt(for action: RewriteAction, selection: String, userTone: String? = nil,
                       language: String? = nil) -> String {
        let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLang = !(lang ?? "").isEmpty
        var taskLine = action.task
        if hasLang { taskLine += " Write the rewritten text in \(lang!)." }
        if let tone = userTone?.trimmingCharacters(in: .whitespacesAndNewlines), !tone.isEmpty {
            taskLine += " Also follow this style preference: \(tone)"
        }
        let ex = action.exemplar
        let textMarker = hasLang ? "Text (in \(lang!)):" : "Text:"
        let rewrittenMarker = hasLang ? "Rewritten (in \(lang!)):" : "Rewritten:"
        // The trailing "Rewritten:" with no newline is the continuation point — the model writes the
        // transformed selection next, then typically starts a fresh "\n\nText:" block (our stop marker).
        return """
        \(taskLine)

        Text: \(ex.input)
        Rewritten: \(ex.output)

        \(textMarker) \(selection)
        \(rewrittenMarker)
        """
    }

    /// A generous token budget scaled to the selection so the model can finish without runaway. Roughly
    /// selection-length × 1.7 (rewrites are usually ≈ the same size; summaries finish well under it),
    /// floored so tiny selections still complete and capped at 1024 (≈4000 chars) so a paragraph-sized
    /// rewrite doesn't truncate mid-sentence — the prior 256-token cap visibly cut off long selections,
    /// leaving the head replaced and the tail stranded ("only part replaced"). 1024 + a ~150-token
    /// exemplar + selection still fits the engine's 4096-token context for any realistic selection.
    static func maxTokens(forSelection selection: String) -> Int {
        let approxTokens = max(1, selection.count / 4)   // ~4 chars/token
        return min(1024, max(64, Int(Double(approxTokens) * 1.7) + 32))
    }

    /// Clean the raw model continuation into the text to inject. Cuts at the first new exemplar block the
    /// base model starts ("\n\nText:" / "\nText:") and at the first paragraph break after content; strips
    /// an echoed "Rewritten:" label and wrapping quotes; trims surrounding + trailing inline whitespace.
    /// Pure + testable.
    /// `selectionWasMultiline` suppresses the paragraph-break truncation below: when the user's selection
    /// itself spans multiple lines/paragraphs, a `\n\n` in the output is a LEGITIMATE paragraph the model
    /// preserved, not the base model "starting anew" — cutting there silently dropped the rest of a
    /// multi-paragraph rewrite. The `\nText:` / `\n\nRewritten:` markers still bound any real runaway.
    static func cleanOutput(_ raw: String, selectionWasMultiline: Bool = false) -> String {
        var s = raw
        // Halt markers where the model rolled into a fresh few-shot block. `Text (` / `Rewritten (`
        // catch the language-tagged variants (`Text (in Spanish):`) the new prompt mode emits.
        for marker in ["\n\nText:", "\nText:", "\n\nText (", "\nText (",
                       "\n\nRewritten:", "\n\nRewritten ("] {
            if let r = s.range(of: marker) { s = String(s[..<r.lowerBound]) }
        }
        // First paragraph break after real content (the base model's "ended, starting anew" tell) — but
        // only for single-paragraph selections, where a `\n\n` can't be part of the intended rewrite.
        if !selectionWasMultiline,
           let content = s.firstIndex(where: { !$0.isWhitespace }),
           let r = s.range(of: "\n\n", range: content ..< s.endIndex) {
            s = String(s[..<r.lowerBound])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop an echoed label if the model repeated it.
        if let r = s.range(of: "Rewritten:"), r.lowerBound == s.startIndex {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Unwrap a fully quote-wrapped result (model sometimes quotes the rewrite).
        if s.count >= 2, let first = s.first, let last = s.last,
           (first == "\"" && last == "\"") || (first == "\u{201C}" && last == "\u{201D}") {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}
