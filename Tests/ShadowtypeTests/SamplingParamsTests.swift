// Pure unit tests for the M0 SamplingParams value type. No model load, no llama.cpp required.
import XCTest
@testable import Shadowtype

final class SamplingParamsTests: XCTestCase {

    // The ghost-text default must reproduce the pre-M0 hardcoded sampler chain BYTE-FOR-BYTE so
    // existing ghost behaviour is unchanged. If you intentionally tune ghost sampling, update both
    // this test AND the documented chain in InferenceEngine in the same commit.
    func testGhostDefaultsMatchPreM0Chain() {
        let g = SamplingParams.ghostDefaults
        XCTAssertEqual(g.temperature, 0.4)
        XCTAssertEqual(g.topP, 0.9)
        XCTAssertEqual(g.topK, 40)
        XCTAssertEqual(g.repeatPenalty, 1.1)
        XCTAssertEqual(g.repeatPenaltyLastN, 64)
        XCTAssertEqual(g.seed, 0xACE1)
        XCTAssertFalse(g.greedy)
        XCTAssertEqual(g.stopStrings, [])
        XCTAssertTrue(g.useEngineStopPolicy,
            "ghost defaults MUST keep useEngineStopPolicy=true or the engine bypasses word buffering")
    }

    func testCommandDefaultsAreCommandShaped() {
        let c = SamplingParams.commandDefaults
        XCTAssertEqual(c.temperature, 0.2, "shell commands want determinism, not prose variety")
        XCTAssertFalse(c.useEngineStopPolicy,
            "command mode MUST stream raw tokens so it stops at the newline, not a sentence/word cap")
        XCTAssertTrue(c.stopStrings.contains("\n"), "command mode MUST stop at end of the single line")
        XCTAssertFalse(c.greedy)
    }

    func testAPIDefaultsDistinctFromGhost() {
        let a = SamplingParams.apiDefaults
        XCTAssertFalse(a.useEngineStopPolicy,
            "API defaults MUST keep useEngineStopPolicy=false so the engine streams raw tokens")
        XCTAssertEqual(a.temperature, 0.7)
        XCTAssertEqual(a.topP, 1.0)
    }

    func testAPIClampedRangesAreRespected() {
        // Temperature clamps to [0, 2]; OpenAI accepts that range and treats 0 as deterministic.
        XCTAssertEqual(SamplingParams.apiClamped(temperature: -1.0).temperature, 0.0)
        XCTAssertEqual(SamplingParams.apiClamped(temperature: 0.0).temperature, 0.0)
        XCTAssertEqual(SamplingParams.apiClamped(temperature: 0.7).temperature, 0.7)
        XCTAssertEqual(SamplingParams.apiClamped(temperature: 9.0).temperature, 2.0)
        // topP clamps to [0, 1]
        XCTAssertEqual(SamplingParams.apiClamped(topP: -0.5).topP, 0.0)
        XCTAssertEqual(SamplingParams.apiClamped(topP: 1.5).topP, 1.0)
        // topK clamps to [1, 10_000]
        XCTAssertEqual(SamplingParams.apiClamped(topK: 0).topK, 1)
        XCTAssertEqual(SamplingParams.apiClamped(topK: 99_999).topK, 10_000)
        // repeat penalty clamps to [0.5, 2.0]
        XCTAssertEqual(SamplingParams.apiClamped(repeatPenalty: 0.1).repeatPenalty, 0.5)
        XCTAssertEqual(SamplingParams.apiClamped(repeatPenalty: 5.0).repeatPenalty, 2.0)
    }

    func testTemperatureZeroFlipsGreedy() {
        // OpenAI contract: temperature 0 is deterministic. We honor it by flipping `greedy=true`
        // so the sampler chain skips top_k/top_p/temp/dist and picks the argmax token directly.
        XCTAssertTrue(SamplingParams.apiClamped(temperature: 0.0).greedy)
        XCTAssertFalse(SamplingParams.apiClamped(temperature: 0.5).greedy)
    }

    func testStopStringsCappedAtSixteen() {
        // Cap raised 8→16: the chat path prepends ~6 turn-end sentinels (chatEndSentinels) ahead of
        // up to a few user stops, so the bound must clear that combined set while still capping a
        // misbehaving client's per-piece scan.
        let many = (0..<20).map { "stop\($0)" }
        let p = SamplingParams.apiClamped(stop: many)
        XCTAssertEqual(p.stopStrings.count, 16)
        XCTAssertEqual(p.stopStrings.first, "stop0")
    }

    func testSeedTruncationDoesNotCrash() {
        // Seed comes in as Int from OpenAI bodies; truncating to UInt32 must not trap on values
        // that exceed UInt32.max (a client passing a huge integer doesn't deserve a crash).
        let p = SamplingParams.apiClamped(seed: Int.max)
        XCTAssertNotNil(p.seed)
    }

    // --- M5 FIM ----------------------------------------------------------------------------

    func testGhostAndAPIDefaultsHaveNoFIM() {
        XCTAssertNil(SamplingParams.ghostDefaults.fim,
                     "ghost text never uses FIM; the flag must default off")
        XCTAssertNil(SamplingParams.apiDefaults.fim,
                     "API defaults must be raw-prompt; clients opt in by passing `suffix`")
    }

    func testAPIClampedWithoutFIMReturnsNilFIM() {
        let p = SamplingParams.apiClamped(temperature: 0.5)
        XCTAssertNil(p.fim,
                     "apiClamped(fim: nil) must keep the field nil — silent FIM activation is bad")
    }

    func testAPIClampedWithFIMRetainsPrefixAndSuffix() {
        let request = FIMRequest(prefix: "def hello():\n    ", suffix: "\n    return result\n")
        let p = SamplingParams.apiClamped(temperature: 0.2, fim: request)
        XCTAssertEqual(p.fim, request,
                       "FIM payload must round-trip — the engine reads .prefix + .suffix directly")
    }

    // --- Repetition-penalty window priming (InferenceEngine.penaltyPrimeTokens) ---------------
    // The bug: llama_sampler_accept only ever saw tokens the CALL generated, so with maxTokens 16-24
    // the 64-token penalty window never held a single PROMPT token — nothing discouraged the ghost
    // from echoing what the user had just typed, while short-range repetition inside the completion
    // was still penalised.

    func testPenaltyPrimeIsTheLastNPromptTokensInOrder() {
        let prompt = (1...200).map { Int32($0) }
        let primed = Array(InferenceEngine.penaltyPrimeTokens(prompt: prompt, lastN: 64))
        XCTAssertEqual(primed.count, 64)
        XCTAssertEqual(primed.first, 137)
        XCTAssertEqual(primed.last, 200,
                       "the ring buffer evicts from the front — the most recent prompt token must be accepted LAST")
    }

    func testPenaltyPrimeHandlesShortPrompt() {
        let prompt: [Int32] = [7, 8, 9]
        XCTAssertEqual(Array(InferenceEngine.penaltyPrimeTokens(prompt: prompt, lastN: 64)), prompt)
    }

    func testPenaltyPrimeEmptyWithoutAWindow() {
        // repeatPenaltyLastN == 0 is a documented no-op inside llama.cpp's penalties sampler; priming
        // it would be pointless work. API defaults use 0 — clients bring their own penalty.
        XCTAssertTrue(InferenceEngine.penaltyPrimeTokens(prompt: [1, 2, 3], lastN: 0).isEmpty)
        XCTAssertEqual(SamplingParams.apiDefaults.repeatPenaltyLastN, 0)
        XCTAssertEqual(SamplingParams.ghostDefaults.repeatPenaltyLastN, 64,
                       "ghost keeps a penalty window, so the prompt tail is what gets replayed into it")
    }

    func testFIMRequestEquality() {
        let a = FIMRequest(prefix: "foo", suffix: "bar")
        let b = FIMRequest(prefix: "foo", suffix: "bar")
        let c = FIMRequest(prefix: "foo", suffix: "baz")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
