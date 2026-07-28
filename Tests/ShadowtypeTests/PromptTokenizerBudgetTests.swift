import XCTest
import CLlama
@testable import Shadowtype

final class PromptTokenizerBudgetTests: XCTestCase {
    private final class OverflowingEngine: InferenceEngineProtocol {
        var isLoaded = true
        var stopAtFirstSentence = false
        var maxWords = 24
        var stopAtSentenceAfterWords = 0
        var maxContextTokens = 128
        var modelChatTemplate: String?
        var modelArchitecture: String?
        var modelSupportsChat = false
        var supportsFIM = false
        var acceptedPrompt: ((String) -> Void)?
        private(set) var prompts: [String] = []

        func load(modelPath: String) throws {}
        func unload() {}
        func requestCancel() {}
        func releaseSeq(_ seqID: Int32) {}

        private func tokenCount(_ prompt: String) -> Int {
            var count = 1
            var asciiBytes = 0
            for scalar in prompt.unicodeScalars {
                switch scalar.value {
                case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                    count += 3
                default:
                    asciiBytes += scalar.utf8.count
                }
            }
            return count + (asciiBytes + 3) / 4
        }

        func generate(prompt: String, maxTokens: Int, seqID: Int32,
                      params: SamplingParams, requiredPrefix: [UInt8]?,
                      onToken: (String) -> Bool,
                      onSample: ((Float, Bool) -> Void)?) throws {
            try generate(
                prompt: prompt, maxTokens: maxTokens, seqID: seqID, params: params,
                contextTokenCap: nil, requiredPrefix: requiredPrefix,
                onToken: onToken, onSample: onSample)
        }

        func generate(prompt: String, maxTokens: Int, seqID: Int32,
                      params: SamplingParams, contextTokenCap: Int?,
                      requiredPrefix: [UInt8]?, onToken: (String) -> Bool,
                      onSample: ((Float, Bool) -> Void)?) throws {
            prompts.append(prompt)
            let cap = contextTokenCap ?? maxContextTokens
            let tokens = tokenCount(prompt)
            if tokens > cap {
                throw InferenceError.contextOverflow(tokens: tokens, cap: cap)
            }
            acceptedPrompt?(prompt)
        }
    }

    private final class RealTokenizer {
        private let model: OpaquePointer
        private let vocab: OpaquePointer

        init(modelPath: String) throws {
            var params = llama_model_default_params()
            params.vocab_only = true
            params.n_gpu_layers = 0
            guard let model = llama_model_load_from_file(modelPath, params) else {
                throw InferenceError.modelLoadFailed(modelPath)
            }
            guard let vocab = llama_model_get_vocab(model) else {
                llama_model_free(model)
                throw InferenceError.tokenizeFailed
            }
            self.model = model
            self.vocab = vocab
        }

        deinit {
            llama_model_free(model)
        }

        func count(_ text: String) throws -> Int {
            let input = InferenceEngine.tokenizationInput(text)
            var capacity = max(8, Int(input.byteCount) + 8)
            while true {
                var output = [llama_token](repeating: 0, count: capacity)
                let count = input.storage.withUnsafeBufferPointer { source in
                    output.withUnsafeMutableBufferPointer { destination in
                        source.baseAddress!.withMemoryRebound(
                            to: CChar.self, capacity: source.count
                        ) { cString in
                            llama_tokenize(
                                vocab, cString, input.byteCount,
                                destination.baseAddress, Int32(capacity), true, true)
                        }
                    }
                }
                if count >= 0 { return Int(count) }
                capacity = Int(-count)
                guard capacity > 0 else { throw InferenceError.tokenizeFailed }
            }
        }
    }

    private struct PromptInput {
        let prefix: String
        var instruction: String? = nil
        var clipboard: String? = nil
        var ocr: String? = nil
        var postCaret: String? = nil
    }

    private struct Validation {
        let initialPrompt: String
        let prompt: String
        let initialTokens: Int
        let tokens: Int
        let initialBudget: Int
        let finalBudget: Int
    }

    private func cachedModelURL() -> URL? {
        let primary = ModelManager().defaultModelURL()
        if FileManager.default.fileExists(atPath: primary.path) { return primary }

        let hubRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".cache/huggingface/hub/models--ggml-org--gemma-3-1b-it-GGUF/snapshots",
                isDirectory: true)
        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: hubRoot, includingPropertiesForKeys: nil)
        else { return nil }
        for snapshot in snapshots {
            let candidate = snapshot.appendingPathComponent(ModelManager.defaultModelFileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func assemble(_ input: PromptInput, budget: Int) -> String {
        CompletionCoordinator.assemblePrompt(
            prefix: input.prefix,
            instruction: input.instruction,
            styleHint: nil, styleEnabled: false,
            clipboard: input.clipboard, clipboardEnabled: input.clipboard != nil,
            ocr: input.ocr, ocrEnabled: input.ocr != nil,
            postCaret: input.postCaret,
            steerLanguageName: nil,
            totalChars: budget).prompt
    }

    private func validate(_ input: PromptInput, tokenCap: Int,
                          tokenizer: RealTokenizer) throws -> Validation {
        let initialBudget = CompletionCoordinator.promptBudgetBytes(
            forContextTokens: tokenCap)
        var budget = initialBudget
        var prompt = assemble(input, budget: budget)
        let initialPrompt = prompt
        let initialTokens = try tokenizer.count(prompt)

        for _ in 0..<16 {
            let tokens = try tokenizer.count(prompt)
            if tokens <= tokenCap {
                return Validation(
                    initialPrompt: initialPrompt, prompt: prompt,
                    initialTokens: initialTokens, tokens: tokens,
                    initialBudget: initialBudget, finalBudget: budget)
            }
            guard let next = PromptSectionBudget.nextByteBudget(
                current: budget, tokenCount: tokens, tokenCap: tokenCap)
            else {
                XCTFail("re-budget stalled at \(tokens) tokens for cap \(tokenCap)")
                break
            }
            budget = next
            prompt = assemble(input, budget: budget)
        }
        throw InferenceError.tokenizeFailed
    }

    func testRealTokenizerFitsCJKCodeAndMixedPromptsWithoutLosingCaretTail() throws {
        guard let modelURL = cachedModelURL() else {
            throw XCTSkip("No cached GGUF model; real-tokenizer prompt-budget test skipped.")
        }
        let tokenizer = try RealTokenizer(modelPath: modelURL.path)

        let rareCJK = String(repeating: "龘齉爩靐饕鬱麤灩驫纞", count: 40)
        let code = String(repeating: """
        public func parse<T>(_ input: [T]) -> Result<[T], ParseError> {
            input.enumerated().compactMap { index, value in index.isMultiple(of: 2) ? value : nil }
        }

        """, count: 18)

        let cases: [(name: String, input: PromptInput, sentinel: String)] = [
            (
                "CJK",
                PromptInput(
                    prefix: rareCJK + "【光标附近必须保留】",
                    instruction: "自然に続きを書いてください",
                    ocr: String(repeating: "画面上の会話文です。", count: 80)),
                "【光标附近必须保留】"
            ),
            (
                "source code",
                PromptInput(
                    prefix: code + "\n// CARET_NEARBY_CODE_MUST_SURVIVE",
                    clipboard: code,
                    postCaret: "return finalizedValue\n}"),
                "// CARET_NEARBY_CODE_MUST_SURVIVE"
            ),
            (
                "mixed",
                PromptInput(
                    prefix: code + rareCJK + "\nlet mixed = \"混合内容\" // CARET_MIXED_附近",
                    instruction: "Continue the current document.",
                    ocr: "会議 notes:\n" + code),
                "let mixed = \"混合内容\" // CARET_MIXED_附近"
            ),
        ]

        for item in cases {
            let result = try validate(item.input, tokenCap: 512, tokenizer: tokenizer)
            XCTAssertLessThanOrEqual(
                result.tokens, 512,
                "\(item.name): real tokenizer still exceeds the cap")
            XCTAssertTrue(
                result.prompt.hasSuffix(item.sentinel),
                "\(item.name): caret-adjacent prefix was trimmed away")
        }
    }

    func testByteHeuristicCanPassWhileRealTokenizerOverflows() throws {
        guard let modelURL = cachedModelURL() else {
            throw XCTSkip("No cached GGUF model; real-tokenizer regression test skipped.")
        }
        let tokenizer = try RealTokenizer(modelPath: modelURL.path)

        let sentinel = "[[CARET-REGRESSION]]"
        let input = PromptInput(
            prefix: String(repeating: "龘齉爩靐饕鬱麤灩驫纞", count: 10) + sentinel)
        let result = try validate(input, tokenCap: 128, tokenizer: tokenizer)

        XCTAssertLessThanOrEqual(
            result.initialPrompt.utf8.count, result.initialBudget,
            "legacy byte heuristic should consider this prompt inside budget")
        XCTAssertGreaterThan(
            result.initialTokens, 128,
            "fixture must reproduce byte-pass/token-overflow regression")
        XCTAssertLessThanOrEqual(result.tokens, 128)
        XCTAssertTrue(result.prompt.hasSuffix(sentinel))
        XCTAssertLessThan(result.finalBudget, result.initialBudget)
    }

    func testEnglishProseAssemblyIsUnchangedWhenRealTokenizerAlreadyFits() throws {
        guard let modelURL = cachedModelURL() else {
            throw XCTSkip("No cached GGUF model; real-tokenizer English control skipped.")
        }
        let tokenizer = try RealTokenizer(modelPath: modelURL.path)

        let input = PromptInput(
            prefix: "The quick brown fox jumps over the lazy dog while the editor keeps typing",
            instruction: "Continue naturally.",
            ocr: "The surrounding paragraph discusses a short walk through the city.")
        let result = try validate(input, tokenCap: 256, tokenizer: tokenizer)

        XCTAssertLessThanOrEqual(result.initialTokens, 256)
        XCTAssertEqual(result.prompt, result.initialPrompt)
        XCTAssertEqual(result.finalBudget, result.initialBudget)
    }

    func testRebudgetAlwaysMakesProgressAndProfilesDoNotMixEnglishWithByteHeavyText() {
        XCTAssertEqual(
            PromptSectionBudget.nextByteBudget(
                current: 3_520, tokenCount: 1_900, tokenCap: 1_024),
            1_882)
        XCTAssertNil(PromptSectionBudget.nextByteBudget(
            current: 100, tokenCount: 80, tokenCap: 100))
        XCTAssertEqual(
            PromptSectionBudget.tokenDensityProfile("ordinary English prose"),
            .asciiProse)
        XCTAssertEqual(
            PromptSectionBudget.tokenDensityProfile(
                String(repeating: "let x = values.map { $0 + 1 }; return x;\n", count: 4)),
            .code)
        XCTAssertEqual(
            PromptSectionBudget.tokenDensityProfile("純粋な日本語"),
            .cjk)
        XCTAssertEqual(
            PromptSectionBudget.tokenDensityProfile("English と日本語"),
            .mixedCJK)
    }

    @MainActor
    func testCoordinatorRetriesOverflowBeforeDecodeAndKeepsCaretTail() async {
        let engine = OverflowingEngine()
        let coordinator = CompletionCoordinator(
            engine: engine, overlay: OverlayRenderer(), context: EditContextTracker())
        coordinator.instructionStore = nil
        coordinator.styleProfile = nil
        coordinator.promptCharBudget = CompletionCoordinator.promptBudgetBytes(
            forContextTokens: engine.maxContextTokens)

        let accepted = expectation(description: "tokenizer-validated prompt accepted")
        engine.acceptedPrompt = { _ in accepted.fulfill() }
        let sentinel = "【CARET附近】"
        coordinator.startGeneration(
            prefix: String(repeating: "龘齉爩靐饕鬱麤灩驫纞", count: 20) + sentinel)

        await fulfillment(of: [accepted], timeout: 2)
        XCTAssertGreaterThan(engine.prompts.count, 1)
        XCTAssertTrue(engine.prompts.last?.hasSuffix(sentinel) == true)
    }
}
