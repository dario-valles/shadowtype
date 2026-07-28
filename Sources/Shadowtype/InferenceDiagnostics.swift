import Foundation
import Darwin

final class InferenceDiagnostics {
    private let modelManager: ModelManager
    private let engine: InferenceEngine

    init(modelManager: ModelManager, engine: InferenceEngine) {
        self.modelManager = modelManager
        self.engine = engine
    }

    private func resolveModelForSmoke() async throws -> URL {
        let primary = modelManager.defaultModelURL()
        if FileManager.default.fileExists(atPath: primary.path) {
            return primary
        }

        let hubRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".cache/huggingface/hub/models--mradermacher--gemma-3-1b-pt-GGUF/snapshots",
                isDirectory: true)
        if let snapshots = try? FileManager.default.contentsOfDirectory(
            at: hubRoot,
            includingPropertiesForKeys: nil
        ) {
            for snapshot in snapshots {
                let candidate =
                    snapshot.appendingPathComponent(ModelManager.defaultModelFileName)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    NSLog("Shadowtype[smoke]: using HF-cached model at \(candidate.path)")
                    return candidate
                }
            }
        }

        NSLog("Shadowtype[smoke]: no cached model — downloading default model")
        return try await modelManager.ensureDefaultModel()
    }

    func runSmoke() {
        Task {
            let prompt = "Here is a long list of reasons why people enjoy reading books, written as one continuous run-on clause separated only by commas: people read because"
            let maxTokens = 64
            var exitCode: Int32 = 0
            do {
                let url = try await resolveModelForSmoke()
                NSLog("Shadowtype[smoke]: loading model \(url.lastPathComponent)")
                let loadStart = Date()
                try engine.load(modelPath: url.path)
                NSLog(
                    "Shadowtype[smoke]: model loaded in \(Int(Date().timeIntervalSince(loadStart) * 1000)) ms")

                var count = 0
                var output = ""
                let generationStart = Date()
                var firstTokenMs: Double = -1
                var context = prompt
                while count < 20 {
                    var runEmitted = 0
                    try engine.generate(prompt: context, maxTokens: maxTokens) { piece in
                        if firstTokenMs < 0 {
                            firstTokenMs =
                                Date().timeIntervalSince(generationStart) * 1000
                        }
                        count += 1
                        runEmitted += 1
                        output += piece
                        context += piece
                        return true
                    }
                    if runEmitted == 0 {
                        break
                    }
                }
                let totalMs = Date().timeIntervalSince(generationStart) * 1000
                let tokensPerSecond =
                    count > 0 ? Double(count) / (totalMs / 1000) : 0

                NSLog("Shadowtype[smoke]: prompt=\"\(prompt)\"")
                NSLog("Shadowtype[smoke]: completion=\"\(output)\"")
                NSLog(
                    "Shadowtype[smoke]: tokens=\(count) firstTokenLatency=\(String(format: "%.1f", firstTokenMs))ms total=\(String(format: "%.1f", totalMs))ms (\(String(format: "%.1f", tokensPerSecond)) tok/s)")
                print(
                    "SMOKE_RESULT tokens=\(count) firstTokenMs=\(String(format: "%.1f", firstTokenMs)) totalMs=\(String(format: "%.1f", totalMs)) tps=\(String(format: "%.1f", tokensPerSecond))")
                print("SMOKE_COMPLETION \(output)")

                if count < 20 {
                    NSLog("Shadowtype[smoke]: FAIL — generated \(count) tokens (<20)")
                    exitCode = 2
                } else {
                    NSLog("Shadowtype[smoke]: PASS — generated \(count) tokens (>=20)")
                }
                engine.unload()
            } catch {
                NSLog("Shadowtype[smoke]: FAIL — \(error)")
                print("SMOKE_RESULT error=\(error)")
                exitCode = 1
            }
            exit(exitCode)
        }
    }

    func runBench() {
        Task {
            var exitCode: Int32 = 0
            do {
                let url = try await resolveModelForSmoke()
                try engine.load(modelPath: url.path)

                let base = String(
                    repeating:
                        "The quarterly review went well and the team is confident about the roadmap, ",
                    count: 6) + "and so"
                let additions = [
                    " the plan", " is", " realistic", " given", " our", " current",
                    " capacity", " this", " quarter", " overall",
                ]

                let coldStart = Date()
                try engine.generate(prompt: base, maxTokens: 1) { _ in false }
                let coldMs = Date().timeIntervalSince(coldStart) * 1000

                var context = base
                var warm: [Double] = []
                for addition in additions {
                    context += addition
                    let start = Date()
                    try engine.generate(prompt: context, maxTokens: 1) { _ in false }
                    warm.append(Date().timeIntervalSince(start) * 1000)
                }
                let average = warm.reduce(0, +) / Double(warm.count)
                let maximum = warm.max() ?? 0

                NSLog(
                    "Shadowtype[bench]: cold=\(String(format: "%.1f", coldMs))ms warm avg=\(String(format: "%.1f", average))ms max=\(String(format: "%.1f", maximum))ms")
                print(
                    "BENCH_RESULT coldMs=\(String(format: "%.1f", coldMs)) warmAvgMs=\(String(format: "%.1f", average)) warmMaxMs=\(String(format: "%.1f", maximum)) budget150=\(maximum < 150 ? "PASS" : "FAIL")")
                engine.unload()
            } catch {
                print("BENCH_RESULT error=\(error)")
                exitCode = 1
            }
            exit(exitCode)
        }
    }
}
