// InferenceEnginePerfTests — live inference benchmark over the REAL app path (InferenceEngine +
// the shipped llama.cpp build), used to qualify a model/quant: load time, time-to-first-token
// (prefill latency), and steady-state decode throughput (tok/s).
//
// OPT-IN + NOT HERMETIC: requires a local GGUF and is skipped unless SHADOWTYPE_PERF_MODEL points at
// one, so plain `swift test` stays fast and offline. Greedy decoding (temperature 0) + a fixed
// dangling prompt make runs comparable across quants — e.g. old bartowski Q4_K_M vs the new Google
// QAT Q4_0 for Gemma 4 E2B (the 2026-06-06 catalog swap). Running it at all also confirms the
// model's arch actually loads in the shipped build (the standing "E-/MoE load unverified" caveat).
//
// Run (single model):
//   SHADOWTYPE_PERF_MODEL="$HOME/Library/Application Support/Shadowtype/models/<file>.gguf" \
//     swift test --filter InferenceEnginePerfTests
// Tunables (env): SHADOWTYPE_PERF_TOKENS (default 96), SHADOWTYPE_PERF_ITERS (default 5).
import XCTest
@testable import Shadowtype

final class InferenceEnginePerfTests: XCTestCase {
    // A strongly-dangling, multilingual-neutral prefix: maximises the chance an instruct model keeps
    // decoding (instead of immediate-EOG) so we measure real steady-state throughput, not a stall.
    private let prompt = "The history of the Roman Empire began when a small settlement on the banks of the river Tiber"

    func testModelDecodeThroughput() throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelPath = env["SHADOWTYPE_PERF_MODEL"], !modelPath.isEmpty else {
            throw XCTSkip("perf benchmark — set SHADOWTYPE_PERF_MODEL=/abs/path.gguf to run")
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            return XCTFail("SHADOWTYPE_PERF_MODEL not found on disk: \(modelPath)")
        }
        let maxTokens = env["SHADOWTYPE_PERF_TOKENS"].flatMap { Int($0) } ?? 96
        let iters = max(1, env["SHADOWTYPE_PERF_ITERS"].flatMap { Int($0) } ?? 5)
        let name = URL(fileURLWithPath: modelPath).lastPathComponent

        // --- Load (measured) ---
        let engine = InferenceEngine()
        defer { engine.unload() }
        let clock = ContinuousClock()
        let loadStart = clock.now
        try engine.load(modelPath: modelPath)
        let loadMs = ms(from: loadStart, to: clock.now)

        // Greedy + raw streaming (useEngineStopPolicy=false): decode exactly maxTokens unless the model
        // emits EOG. Deterministic across runs/quants so the comparison is apples-to-apples.
        let params = SamplingParams.apiClamped(temperature: 0)

        // One untimed warmup (Metal shader/JIT + KV alloc) so the first timed run isn't an outlier.
        _ = try runOnce(engine, params: params, maxTokens: maxTokens)

        var ttfts: [Double] = []          // prefill latency (ms): start → first token
        var decodeRates: [Double] = []    // steady-state tok/s after the first token
        var tokenCounts: [Int] = []
        for _ in 0..<iters {
            let r = try runOnce(engine, params: params, maxTokens: maxTokens)
            ttfts.append(r.ttftMs)
            tokenCounts.append(r.tokens)
            if r.tokens > 1, r.decodeSec > 0 {
                decodeRates.append(Double(r.tokens - 1) / r.decodeSec)
            }
        }

        let medTTFT = median(ttfts)
        let medDecode = median(decodeRates)
        let footprintMB = physFootprintMB()
        let minTokens = tokenCounts.min() ?? 0
        let earlyEOG = minTokens < maxTokens

        // The report IS the deliverable — printed so it shows in test output.
        print("""

        ┌─ InferenceEngine perf ─────────────────────────────────────
        │ model           : \(name)
        │ arch            : \(engine.modelArchitecture ?? "?")  chat-template: \(engine.modelChatTemplate != nil)
        │ load time       : \(fmt(loadMs)) ms
        │ resident (RSS)  : \(fmt(footprintMB)) MiB  (CPU-side only — Metal weight buffer NOT counted)
        │ maxTokens/iter  : \(maxTokens)   iters: \(iters)
        │ tokens emitted  : min \(minTokens), max \(tokenCounts.max() ?? 0)\(earlyEOG ? "  ⚠︎ EOG before maxTokens (throughput from a short run)" : "")
        │ TTFT (prefill)  : \(fmt(medTTFT)) ms  (median)
        │ decode          : \(fmt(medDecode)) tok/s  (median)
        └────────────────────────────────────────────────────────────
        """)

        // Sanity gates: loading + producing tokens at a non-absurd rate. Generous so this is a
        // regression tripwire, not a flaky hardware-specific threshold.
        XCTAssertTrue(engine.isLoaded, "model failed to load")
        XCTAssertGreaterThan(minTokens, 0, "\(name) emitted no tokens")
        XCTAssertGreaterThan(medDecode, 1.0, "\(name) decode collapsed below 1 tok/s")
    }

    // MARK: - helpers

    private struct RunResult { let ttftMs: Double; let decodeSec: Double; let tokens: Int }

    /// One greedy generation; returns prefill latency, post-first-token decode duration, token count.
    private func runOnce(_ engine: InferenceEngine, params: SamplingParams, maxTokens: Int) throws -> RunResult {
        let clock = ContinuousClock()
        let start = clock.now
        var firstAt: ContinuousClock.Instant?
        var lastAt = start
        var tokens = 0
        try engine.generate(prompt: prompt, maxTokens: maxTokens, seqID: 1, params: params,
                            requiredPrefix: nil,
                            onToken: { _ in
                                let now = clock.now
                                if firstAt == nil { firstAt = now }
                                lastAt = now
                                tokens += 1
                                return true   // keep decoding until maxTokens / EOG
                            }, onSample: nil)
        let ttftMs = ms(from: start, to: firstAt ?? start)
        let decodeSec = sec(from: firstAt ?? lastAt, to: lastAt)
        return RunResult(ttftMs: ttftMs, decodeSec: decodeSec, tokens: tokens)
    }

    private func ms(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
    private func sec(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
    private func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2
    }
    private func fmt(_ x: Double) -> String { String(format: "%.1f", x) }

    /// Resident set size of this process (Mach `resident_size`) post-warmup. NOTE: this is only a
    /// rough CPU-side floor, not the model's true memory. llama.cpp offloads the weights into a Metal
    /// buffer (`MTL0_Mapped model buffer size` in the load log) on the unified-memory GPU, and that
    /// allocation is NOT counted in the task's `resident_size` — so a 6.5 GB model can read ~1.5 GB
    /// here. For the authoritative footprint read the load-log buffer sizes: total ≈ MTL0_Mapped
    /// model buffer (≈ file size) + KV cache + MTL0/CPU compute buffers. (`phys_footprint` is even
    /// worse — ~200 MiB — so we use RSS as the lesser-evil floor.)
    private func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / (1024 * 1024) : -1
    }
}
