// ModelContinuationEvalTests — side-by-side raw-continuation check used to qualify a catalog model:
// greedy ghost-path completions over a fixed en/es/ca prompt set, plus how many come back EMPTY (the
// instruct-model end-of-turn failure the catalog's base-over-instruct rule exists to avoid) and the
// first-token latency on a ~1500-token prompt, which is what the coordinator's 400 ms deadline sees.
//
// OPT-IN + NOT HERMETIC, like InferenceEnginePerfTests: skipped unless SHADOWTYPE_EVAL_MODEL points at
// a local GGUF. The printed table IS the deliverable; read the completions, the asserts only catch a
// model that loads but produces nothing at all.
//
// Run:
//   SHADOWTYPE_EVAL_MODEL="/abs/path/model.gguf" swift test --filter ModelContinuationEvalTests
import XCTest
@testable import Shadowtype

final class ModelContinuationEvalTests: XCTestCase {
    // Dangling AND complete-looking prefixes in the three languages the catalog notes keep coming back
    // to. The Catalan rows are the close-language steering case (a model drifting into Spanish).
    private let prompts: [(lang: String, text: String)] = [
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

    func testContinuationsAndLongPromptLatency() throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelPath = env["SHADOWTYPE_EVAL_MODEL"], !modelPath.isEmpty else {
            throw XCTSkip("model eval — set SHADOWTYPE_EVAL_MODEL=/abs/path.gguf to run")
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            return XCTFail("SHADOWTYPE_EVAL_MODEL not found on disk: \(modelPath)")
        }
        setenv("SHADOWTYPE_GREEDY", "1", 1)            // deterministic, comparable across models
        defer { unsetenv("SHADOWTYPE_GREEDY") }

        let engine = InferenceEngine()
        defer { engine.unload() }
        try engine.load(modelPath: modelPath)

        var rows: [String] = []
        var empty = 0
        for p in prompts {
            var out = ""
            // Seq 1 (the engine has n_seq_max = 4), released after every row so no row inherits
            // another row's KV prefix.
            try engine.generate(prompt: p.text, maxTokens: 24, seqID: 1,
                                params: .ghostDefaults, requiredPrefix: nil,
                                onToken: { out += $0; return true }, onSample: nil)
            engine.releaseSeq(1)
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { empty += 1 }
            let tail = p.text.suffix(36).replacingOccurrences(of: "\n", with: "⏎")
            rows.append("│ [\(p.lang)] …\(tail) ⟶ \(out.replacingOccurrences(of: "\n", with: "⏎"))")
        }

        // ~1500-token prompt, the size the coordinator assembles with page context. A unique first line
        // per run defeats prefix KV reuse so every timing is a cold prefill.
        let paragraph = String(repeating: "Gracias por la propuesta, la he revisado con el equipo y creo que podemos avanzar con la segunda opción si ajustamos el calendario. ", count: 45)
        var ttfts: [Double] = []
        let clock = ContinuousClock()
        for run in 0..<4 {
            let start = clock.now
            var first: ContinuousClock.Instant?
            try engine.generate(prompt: "Run \(run) \(UUID().uuidString)\n" + paragraph + "Un saludo y",
                                maxTokens: 4, seqID: 1, params: .ghostDefaults, requiredPrefix: nil,
                                onToken: { _ in if first == nil { first = clock.now }; return false },
                                onSample: nil)
            engine.releaseSeq(1)
            if let first, run > 0 {   // run 0 is the Metal warmup
                let d = start.duration(to: first)
                ttfts.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            }
        }
        let medTTFT = ttfts.sorted()[ttfts.count / 2]

        print("""

        ┌─ Continuation eval: \(URL(fileURLWithPath: modelPath).lastPathComponent)
        │ arch: \(engine.modelArchitecture ?? "?")   empty: \(empty)/\(prompts.count)   TTFT@~1500 tok: \(String(format: "%.0f", medTTFT)) ms
        \(rows.joined(separator: "\n"))
        └────────────────────────────────────────────────────────────
        """)
        XCTAssertLessThan(empty, prompts.count, "model produced no continuation for any prompt")
    }
}
