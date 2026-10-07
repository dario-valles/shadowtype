// FoundationModelsEvalTests — live spike measuring Apple's on-device FoundationModels (macOS 26+) against
// Shadowtype's workloads: ghost-text continuation (raw prefix → next few words, first token inside the
// coordinator's ~400 ms deadline), selection rewrite, and a long page-context prefix. It exists so the
// "should FoundationModelsEngine be real?" question is answered with numbers, and can be re-run when Apple
// ships a new on-device model.
//
// OPT-IN + NOT HERMETIC: talks to the system model (Apple Intelligence must be enabled) and is skipped
// unless SHADOWTYPE_FM_EVAL=1, so plain `swift test` stays fast and offline.
//
// Run (all, ~6–10 min; numbers swing a lot with machine load, which every block prints):
//   SHADOWTYPE_FM_EVAL=1 swift test --filter FoundationModelsEvalTests
// One part: --filter FoundationModelsEvalTests/testGhostContinuation (or testRewrite, testEngineRewrite,
// testChat, testLongPrefix). SHADOWTYPE_FM_VARIANTS=B,D narrows the ghost instruction variants.
// The measured results and the decision they led to are recorded at the top of FoundationModelsEngine.swift.
#if canImport(FoundationModels)
import FoundationModels
#endif
import NaturalLanguage
import XCTest
@testable import Shadowtype

final class FoundationModelsEvalTests: XCTestCase {
    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["SHADOWTYPE_FM_EVAL"] == "1" else {
            throw XCTSkip("FoundationModels spike — set SHADOWTYPE_FM_EVAL=1 to run")
        }
    }

    func testGhostContinuation() async throws {
        try requireOptIn()
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        try FMEval.requireAvailable()
        await FMEval.ghost()
        #else
        throw XCTSkip("SDK has no FoundationModels")
        #endif
    }

    func testRewrite() async throws {
        try requireOptIn()
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        try FMEval.requireAvailable()
        await FMEval.rewrite()
        #else
        throw XCTSkip("SDK has no FoundationModels")
        #endif
    }

    // The shipped path end to end: FoundationModelsEngine (sync bridge, rewrite sampling) fed the prompts
    // RewriteAction builds — the llama few-shot one and the zero-shot instruction one — for every action,
    // flagging an answer that copies the few-shot exemplar or drifts out of the selection's language.
    func testEngineRewrite() throws {
        try requireOptIn()
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        try FMEval.requireAvailable()
        try FMEval.engineRewrite()
        #else
        throw XCTSkip("SDK has no FoundationModels")
        #endif
    }

    func testChat() async throws {
        try requireOptIn()
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        try FMEval.requireAvailable()
        await FMEval.chat()
        #else
        throw XCTSkip("SDK has no FoundationModels")
        #endif
    }

    func testLongPrefix() async throws {
        try requireOptIn()
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        try FMEval.requireAvailable()
        await FMEval.longPrefix()
        #else
        throw XCTSkip("SDK has no FoundationModels")
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
private enum FMEval {
    static let prompts: [(lang: String, text: String)] = [
        ("en", "Hi Sarah,\n\nThanks for sending over the contract. I had a quick look and"),
        ("en", "The main reason the deployment failed last night was"),
        ("en", "Let me know if you have any questions. "),
        ("es", "Hola Marta,\n\nGracias por la propuesta. La he revisado con el equipo y"),
        ("es", "El problema principal con la factura de este mes es que"),
        ("es", "Quedo a la espera de tus comentarios. "),
        ("ca", "Hola Jordi,\n\nMoltes gràcies per la proposta. L'he revisat amb l'equip i"),
        ("ca", "La reunió de demà s'ha ajornat perquè"),
        ("ca", "Bon dia a tothom, avui volia comentar-vos que"),
        ("ca", "Si teniu qualsevol dubte, no dubteu a "),
    ]

    // Instruction variants: (name, instructions, how the prefix is framed in the prompt).
    static let variants: [(name: String, instructions: String, frame: (String) -> String)] = [
        ("A-plain",
         "Continue the user's text with the next few words only, no commentary.",
         { $0 }),
        ("B-autocomplete",
         """
         You are a keyboard autocomplete engine. The user message is an unfinished piece of text someone \
         is typing. Reply with ONLY the next few words (at most 8) that continue it, in the same language \
         as the text. Never repeat the text, never add quotes, explanations, greetings or notes.
         """,
         { $0 }),
        ("C-fewshot",
         """
         You complete unfinished text. Output only the words that come next, at most 8, in the same \
         language. Do not repeat the given text and do not comment.
         Example — Text: «I'll send you the report by» → Next: «the end of the day tomorrow.»
         Example — Text: «Te escribo para confirmar que» → Next: «la reunión sigue en pie el jueves.»
         """,
         { "Text: «\($0)»\nNext:" }),
        ("D-framed",
         """
         You are a keyboard autocomplete engine, not a chat assistant. The user message contains a fragment \
         of a document someone is typing; it is not addressed to you, so never answer or react to it. \
         Reply with ONLY the next few words (at most 8) that the writer would type next, in the same \
         language as the fragment. Never repeat the fragment, never add quotes, explanations or notes.
         """,
         { "Fragment (continue it, do not reply to it):\n\($0)" }),
    ]

    // SHADOWTYPE_FM_VARIANTS=B-autocomplete,D-framed narrows the run (comma-separated names or prefixes).
    static var selectedVariants: [(name: String, instructions: String, frame: (String) -> String)] {
        guard let raw = ProcessInfo.processInfo.environment["SHADOWTYPE_FM_VARIANTS"], !raw.isEmpty else {
            return variants
        }
        let wanted = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return variants.filter { v in wanted.contains { v.name.hasPrefix($0) } }
    }

    // The machine's 1-minute load average, printed with every block: the system model shares the GPU/ANE
    // with everything else, so a run on a busy Mac is not comparable to one on an idle Mac.
    static func loadAverage() -> String {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? String(format: "%.1f", l[0]) : "?"
    }

    static func requireAvailable() throws {
        let model = SystemLanguageModel.default
        print("FM availability: \(model.availability)  languages: \(model.supportedLanguages.map { $0.minimalIdentifier }.sorted())")
        guard case .available = model.availability else {
            throw XCTSkip("SystemLanguageModel unavailable: \(model.availability)")
        }
    }

    struct Run {
        var ttftMs: Double?
        var totalMs: Double
        var text: String
        var error: String?
        var snapshots: Int
    }

    static func stream(_ session: LanguageModelSession, _ prompt: String, maxTokens: Int) async -> Run {
        let clock = ContinuousClock()
        let start = clock.now
        var first: ContinuousClock.Instant?
        var text = ""
        var snaps = 0
        var err: String?
        do {
            #if compiler(>=6.4)
            let opts = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
            #else
            let opts = GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
            #endif
            for try await snap in session.streamResponse(to: prompt, options: opts) {
                snaps += 1
                text = snap.content
                if first == nil, text.contains(where: { !$0.isWhitespace }) { first = clock.now }
            }
        } catch {
            err = describe(error)
        }
        return Run(ttftMs: first.map { ms(start, $0) }, totalMs: ms(start, clock.now), text: text,
                   error: err, snapshots: snaps)
    }

    // The error's case name (exceededContextWindowSize, guardrailViolation, unsupportedLanguageOrLocale,
    // rateLimited, refusal, …) without its debug payload. String-based so it compiles against every SDK's
    // error enum (macOS 27 moved most cases to LanguageModelError).
    static func describe(_ error: Error) -> String {
        let full = String(describing: error)
        return full.split(separator: "(", maxSplits: 1).first.map(String.init) ?? full
    }

    // MARK: quality heuristics (the raw output is printed too — these are a first-pass flag only)

    static func echoes(prefix: String, output: String) -> Bool {
        let o = norm(output), p = norm(prefix)
        guard !o.isEmpty else { return false }
        let head = String(p.prefix(min(20, p.count)))
        let tailWords = p.split(separator: " ").suffix(4).joined(separator: " ")
        return o.hasPrefix(head) || (tailWords.count > 8 && o.contains(tailWords))
    }

    static func commentary(_ output: String) -> Bool {
        let t = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.first.map({ "\"“«'‘`*".contains($0) }) == true { return true }
        let lower = t.lowercased()
        let openers = ["sure", "here", "certainly", "of course", "continuation", "next:", "text:", "output",
                       "claro", "aquí", "aqui", "por supuesto", "continuación", "i'm sorry", "i can't",
                       "lo siento", "as an", "note:"]
        if openers.contains(where: { lower.hasPrefix($0) }) { return true }
        return t.contains("\n")
    }

    static func language(_ s: String) -> String {
        let r = NLLanguageRecognizer()
        r.processString(s)
        return r.dominantLanguage?.rawValue ?? "?"
    }

    static func norm(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func ms(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    static func f(_ x: Double?) -> String { x.map { String(format: "%.0f", $0) } ?? "—" }
    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "⏎")
    }

    // MARK: ghost

    static func ghost() async {
        let maxTokens = 16
        for v in selectedVariants {
            print("\n=== ghost variant \(v.name)  (load avg \(loadAverage())) ===")
            print("instructions: \(oneLine(v.instructions))")
            var ttftCold: [Double] = [], ttftWarm: [Double] = [], ttftPrewarm: [Double] = [], totals: [Double] = []
            var echo = 0, comment = 0, langSwitch = 0, errors = 0, under400 = 0, n = 0
            for (i, p) in prompts.enumerated() {
                // cold: brand-new session, no prewarm. (Only the very first call in the process can be
                // truly cold for the system model; afterwards this is "fresh session, model hot".)
                let s1 = LanguageModelSession(instructions: v.instructions)
                let cold = await stream(s1, v.frame(p.text), maxTokens: maxTokens)
                // warm: same session again — the realistic "reuse a session" path; the transcript grows.
                let warm = await stream(s1, v.frame(p.text), maxTokens: maxTokens)
                // prewarmed: fresh session + prewarm(promptPrefix: instructions-only) and a short idle, the
                // way an engine would keep one session armed ahead of the next keystroke.
                let s3 = LanguageModelSession(instructions: v.instructions)
                s3.prewarm()
                try? await Task.sleep(for: .milliseconds(600))
                let pre = await stream(s3, v.frame(p.text), maxTokens: maxTokens)

                for (label, r) in [("cold", cold), ("warm", warm), ("prewarm", pre)] {
                    let lang = language(p.text + " " + r.text)
                    let outLang = r.text.split(separator: " ").count >= 3 ? language(r.text) : "-"
                    let e = echoes(prefix: p.text, output: r.text)
                    let c = commentary(r.text)
                    print("[\(v.name)] #\(i) \(p.lang) \(label): ttft=\(f(r.ttftMs))ms total=\(f(r.totalMs))ms snaps=\(r.snapshots) "
                          + "echo=\(e) commentary=\(c) outLang=\(outLang) mixLang=\(lang)"
                          + (r.error.map { " ERROR=\($0)" } ?? "")
                          + "\n      → \"\(oneLine(r.text))\"")
                }
                for r in [cold, warm, pre] {
                    n += 1
                    if r.error != nil { errors += 1; continue }
                    if echoes(prefix: p.text, output: r.text) { echo += 1 }
                    if commentary(r.text) { comment += 1 }
                    let words = r.text.split(separator: " ").count
                    if words >= 3, language(r.text) != p.lang { langSwitch += 1 }
                    if let t = r.ttftMs, t <= 400 { under400 += 1 }
                    totals.append(r.totalMs)
                }
                if let t = cold.ttftMs { ttftCold.append(t) }
                if let t = warm.ttftMs { ttftWarm.append(t) }
                if let t = pre.ttftMs { ttftPrewarm.append(t) }
            }
            print("""
            ┌─ FM ghost summary [\(v.name)] ─────────────────────────
            │ TTFT cold    : median \(f(median(ttftCold))) ms  (min \(f(ttftCold.min())), max \(f(ttftCold.max())))
            │ TTFT warm    : median \(f(median(ttftWarm))) ms  (same session, 2nd call)
            │ TTFT prewarm : median \(f(median(ttftPrewarm))) ms  (fresh session + prewarm())
            │ total        : median \(f(median(totals))) ms
            │ ≤400ms TTFT  : \(under400)/\(n)
            │ load avg now : \(loadAverage())
            │ echo \(echo)  commentary \(comment)  langSwitch \(langSwitch)  errors \(errors)  (of \(n))
            └────────────────────────────────────────────────────────
            """)
        }
    }

    // MARK: rewrite

    static func rewrite() async {
        let selections: [(String, String)] = [
            ("en", "hey, can't make it tomorrow, can we push the meeting to friday? also the numbers in the deck look off, pls check before sending to the client. thx"),
            ("es", "oye, mañana no puedo, ¿lo movemos al viernes? y los números de la presentación no cuadran, revísalos antes de mandarlo al cliente. gracias"),
            ("ca", "ei, demà no puc, ho podem passar a divendres? i els números de la presentació no quadren, revisa-ho abans d'enviar-ho al client. gràcies"),
        ]
        let instr = """
        Rewrite the user's text in a polished, formal, professional tone, keeping the same meaning and the \
        same language as the text. Output only the rewritten text, with no preamble, quotes or notes.
        """
        print("rewrite (load avg \(loadAverage()))")
        for (lang, sel) in selections {
            // (1) instruction-native: FM's natural shape.
            let s = LanguageModelSession(instructions: instr)
            let r = await stream(s, sel, maxTokens: 300)
            print("[rewrite formal/instr] \(lang): ttft=\(f(r.ttftMs))ms total=\(f(r.totalMs))ms outLang=\(language(r.text))"
                  + (r.error.map { " ERROR=\($0)" } ?? "") + "\n      → \"\(oneLine(r.text))\"")
            // (2) the existing few-shot continuation prompt the llama path uses, as a plain prompt.
            let langName = ["en": "English", "es": "Spanish", "ca": "Catalan"][lang]
            let fewShot = RewriteAction.prompt(for: .formal, selection: sel, language: lang == "en" ? nil : langName)
            let s2 = LanguageModelSession()
            let r2 = await stream(s2, fewShot, maxTokens: 300)
            let cleaned = RewriteAction.cleanOutput(r2.text)
            print("[rewrite formal/fewshot] \(lang): ttft=\(f(r2.ttftMs))ms total=\(f(r2.totalMs))ms outLang=\(language(cleaned))"
                  + (r2.error.map { " ERROR=\($0)" } ?? "") + "\n      raw → \"\(oneLine(r2.text))\"\n      cleaned → \"\(oneLine(cleaned))\"")
        }
    }

    // MARK: engine rewrite (the shipped path)

    static func engineRewrite() throws {
        let engine = FoundationModelsEngine()
        try engine.load(modelPath: "")
        let cases: [(code: String, name: String, text: String)] = [
            ("en", "English", "hey, can't make it tomorrow, can we push the meeting to friday? also the numbers in the deck look off, pls check before sending to the client. thx"),
            ("es", "Spanish", "oye, mañana no puedo, ¿lo movemos al viernes? y los números de la presentación no cuadran, revísalos antes de mandarlo al cliente. gracias"),
        ]
        // Every exemplar output, to catch an answer that copies one instead of rewriting the selection.
        let exemplarOutputs = RewriteAction.allCases.map {
            RewriteAction.cleanOutput(String(RewriteAction.prompt(for: $0, selection: "§").split(separator: "\n")[3]))
        }
        var tally: [String: (ok: Int, copied: Int, wrongLang: Int, empty: Int, ms: [Double])] = [:]
        for c in cases {
            for action in RewriteAction.allCases {
                let prompts = [
                    ("fewshot", RewriteAction.prompt(for: action, selection: c.text, language: c.name)),
                    ("instruct", RewriteAction.instructionPrompt(for: action, selection: c.text, language: c.name)),
                ]
                for (kind, prompt) in prompts {
                    let clock = ContinuousClock(), start = clock.now
                    var out = ""
                    do {
                        try engine.generate(prompt: prompt, maxTokens: RewriteAction.maxTokens(forSelection: c.text),
                                            seqID: 2, params: .rewriteDefaults(), requiredPrefix: nil,
                                            onToken: { out += $0; return true }, onSample: nil)
                    } catch {
                        out = ""
                        print("[engine \(kind) \(action.rawValue) \(c.code)] ERROR \(describe(error))")
                    }
                    let d = start.duration(to: clock.now)
                    let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                    // Mirrors CompletionCoordinator.rewrite: the Apple path keeps paragraph breaks.
                    let cleaned = RewriteAction.cleanOutput(out, selectionWasMultiline: kind == "instruct")
                    let copied = exemplarOutputs.contains { !$0.isEmpty && cleaned.contains(String($0.prefix(40))) }
                    let lang = language(cleaned)
                    var t = tally[kind] ?? (0, 0, 0, 0, [])
                    if cleaned.isEmpty { t.empty += 1 } else if copied { t.copied += 1 }
                    else if lang != c.code { t.wrongLang += 1 } else { t.ok += 1 }
                    t.ms.append(ms)
                    tally[kind] = t
                    print("[engine \(kind) \(action.rawValue) \(c.code)] \(f(ms))ms lang=\(lang) copied=\(copied) → \"\(oneLine(cleaned))\"")
                }
            }
        }
        for (kind, t) in tally.sorted(by: { $0.key < $1.key }) {
            print("[engine summary \(kind)] ok \(t.ok)  copiedExemplar \(t.copied)  wrongLang \(t.wrongLang)  empty \(t.empty)  median \(f(median(t.ms)))ms  max \(f(t.ms.max()))ms")
        }
    }

    // MARK: chat (the /v1/chat/completions shape: system → instructions, user → prompt)

    static func chat() async {
        print("chat (load avg \(loadAverage()))")
        let turns: [(String, String)] = [
            ("en", "In one sentence, why do unit tests matter?"),
            ("es", "En una frase, ¿por qué importan los tests unitarios?"),
            ("ca", "En una frase, per què són importants els tests unitaris?"),
        ]
        for (lang, user) in turns {
            let s = LanguageModelSession(instructions: "You are a helpful assistant. Answer concisely.")
            let r = await stream(s, user, maxTokens: 120)
            print("[chat] \(lang): ttft=\(f(r.ttftMs))ms total=\(f(r.totalMs))ms snaps=\(r.snapshots) outLang=\(language(r.text))"
                  + (r.error.map { " ERROR=\($0)" } ?? "") + "\n      → \"\(oneLine(r.text))\"")
        }
    }

    // MARK: long prefix (~1500 tokens of page context + caret line)

    static func longPrefix() async {
        let paragraph = """
        Following up on yesterday's planning session, here is a summary of where each workstream stands. \
        The billing migration is on track: the new invoice generator has been running in shadow mode for two \
        weeks and the discrepancies we found were all rounding differences on multi-currency accounts, which \
        finance has signed off on. The onboarding redesign slipped by a week because the copy review took \
        longer than expected, but design has already handed over the final screens. Support volume is down \
        twelve percent since the help-center refresh, mostly in password and invoice questions. \n\n
        """
        let instr = variants[1].instructions
        print("long prefix (load avg \(loadAverage()))")
        for (label, reps) in [("~1500tok", 13), ("~3000tok", 26), ("~4500tok", 39)] {
            let text = String(repeating: paragraph, count: reps) + "The one open risk I want to flag before Friday is that"
            var tokens = "~\(text.count / 4)?"
            #if compiler(>=6.4)
            if #available(macOS 26.4, *) {
                if let c = try? await SystemLanguageModel.default.tokenCount(for: Prompt(text)) { tokens = "\(c)" }
            }
            #endif
            let s = LanguageModelSession(instructions: instr)
            let r = await stream(s, text, maxTokens: 16)
            print("[long \(label)] chars=\(text.count) tokens=\(tokens) ttft=\(f(r.ttftMs))ms total=\(f(r.totalMs))ms"
                  + (r.error.map { " ERROR=\($0)" } ?? "") + "\n      → \"\(oneLine(r.text))\"")
            let s2 = LanguageModelSession(instructions: instr)
            s2.prewarm()
            try? await Task.sleep(for: .milliseconds(600))
            let r2 = await stream(s2, text, maxTokens: 16)
            print("[long \(label) prewarm] ttft=\(f(r2.ttftMs))ms total=\(f(r2.totalMs))ms"
                  + (r2.error.map { " ERROR=\($0)" } ?? "") + "\n      → \"\(oneLine(r2.text))\"")
            // prewarm(promptPrefix:) with the page context itself — the closest FM gets to llama's KV
            // prefix reuse. Given a generous idle so the prefill can finish before the "keystroke".
            guard reps == 13 else { continue }
            let s3 = LanguageModelSession(instructions: instr)
            s3.prewarm(promptPrefix: Prompt(String(repeating: paragraph, count: reps)))
            try? await Task.sleep(for: .seconds(15))
            let r3 = await stream(s3, text, maxTokens: 16)
            print("[long \(label) prefix-prewarm +15s idle] ttft=\(f(r3.ttftMs))ms total=\(f(r3.totalMs))ms"
                  + (r3.error.map { " ERROR=\($0)" } ?? "") + "\n      → \"\(oneLine(r3.text))\"")
        }
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2
    }
}
#endif
