// M0 tests. Token-generation tests are model-gated: they SKIP (never fail) when no GGUF is
// present, so CI without the ~800MB model stays green. Run with a model to exercise the engine:
//   swift test            (auto-resolves Application Support or the HF hub cache)
import XCTest
@testable import Shadowtype

final class ShadowtypeTests: XCTestCase {
    func testScaffoldCompiles() {
        XCTAssertTrue(true)
    }

    /// Resolve a usable default GGUF from Application Support or the Hugging Face hub cache.
    /// Returns nil when nothing is cached locally (test then skips).
    private func resolveCachedModel() -> URL? {
        let mgr = ModelManager()
        let primary = mgr.defaultModelURL()
        if FileManager.default.fileExists(atPath: primary.path) { return primary }

        let hubRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--ggml-org--gemma-3-1b-it-GGUF/snapshots",
                                    isDirectory: true)
        guard let snaps = try? FileManager.default.contentsOfDirectory(at: hubRoot,
                                                                       includingPropertiesForKeys: nil)
        else { return nil }
        for snap in snaps {
            let candidate = snap.appendingPathComponent(ModelManager.defaultModelFileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    func testGeneratesAtLeastTwentyTokens() throws {
        guard let modelURL = resolveCachedModel() else {
            throw XCTSkip("No GGUF model cached locally; skipping. See README/smoke for fetch command.")
        }

        let engine = InferenceEngine()
        try engine.load(modelPath: modelURL.path)
        XCTAssertTrue(engine.isLoaded, "engine should report loaded after load()")
        defer { engine.unload() }

        var pieces: [String] = []
        let start = Date()
        var firstTokenMs: Double = -1
        // Probe raw streaming throughput, not the product's short-clause stop policy: lift the word
        // cap so one prefill streams a substantial run, and chain forward-from-caret to reach >=20.
        engine.maxWords = 64
        var context = "Here is a long list of reasons why people enjoy reading books, written as one continuous run-on clause separated only by commas: people read because"
        while pieces.count < 20 {
            var runEmitted = 0
            try engine.generate(prompt: context, maxTokens: 64) { piece in
                if firstTokenMs < 0 { firstTokenMs = Date().timeIntervalSince(start) * 1000 }
                pieces.append(piece)
                context += piece
                runEmitted += 1
                return true
            }
            if runEmitted == 0 { break }
        }

        XCTAssertGreaterThanOrEqual(pieces.count, 20,
                                    "expected >=20 generated tokens, got \(pieces.count)")
        XCTAssertFalse(pieces.joined().isEmpty, "completion text should be non-empty")
        XCTAssertGreaterThan(firstTokenMs, 0, "should have measured a first-token latency")
    }

    // KV-cache reuse correctness (FR-CE-5): a warm engine that already holds a prefix of the prompt
    // in its cache must, after trimming + reprefilling the divergent suffix, produce IDENTICAL
    // greedy output to a freshly-loaded engine that cold-prefills the whole prompt. If reuse got the
    // token positions or sampling logits wrong, the two outputs would diverge — so equality is a
    // tight proof the reuse path is sound.
    func testWarmReuseMatchesColdGreedyOutput() throws {
        guard let modelURL = resolveCachedModel() else {
            throw XCTSkip("No GGUF model cached locally; skipping.")
        }
        setenv("SHADOWTYPE_GREEDY", "1", 1)            // deterministic greedy for a stable compare
        defer { unsetenv("SHADOWTYPE_GREEDY") }

        func run(_ engine: InferenceEngine, _ prompt: String, _ n: Int) -> String {
            var out = ""
            try? engine.generate(prompt: prompt, maxTokens: n) { out += $0; return true }
            return out
        }

        let full = "The capital of France is"

        let cold = InferenceEngine()
        try cold.load(modelPath: modelURL.path); defer { cold.unload() }
        let coldOut = run(cold, full, 12)

        let warm = InferenceEngine()
        try warm.load(modelPath: modelURL.path); defer { warm.unload() }
        _ = run(warm, "The capital", 4)                 // warms the KV cache with a strict prefix
        let warmOut = run(warm, full, 12)               // exercises trim + suffix-reprefill reuse

        XCTAssertFalse(coldOut.isEmpty, "cold generation should produce output")
        XCTAssertEqual(warmOut, coldOut,
                       "KV-reuse must yield identical greedy output to a cold prefill")
    }
}
