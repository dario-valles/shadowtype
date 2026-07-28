import XCTest
@testable import Shadowtype

final class CompletionActivationEvaluatorTests: XCTestCase {
    func testOrderedActivationDecisionChain() {
        var gate = FocusCapabilityFlickerGate()
        let prose = CompletionActivationEvaluator.PrefixSnapshot(
            forced: false,
            bundleId: "com.apple.TextEdit",
            terminalText: nil,
            editorFieldHeight: nil,
            editorWindowHeight: nil,
            shellCommandsEnabled: false,
            originalPrefix: "Hello",
            prefix: "Hello",
            focusSeq: 7,
            emojiTrigger: false,
            minPrefixChars: 2
        )
        var prefixResult = CompletionActivationEvaluator.evaluatePrefix(prose, capabilityGate: gate)
        XCTAssertEqual(prefixResult.decision, .continueEvaluation(prefix: "Hello", shellMode: false))
        gate = prefixResult.capabilityGate

        let missing = CompletionActivationEvaluator.PrefixSnapshot(
            forced: false,
            bundleId: "com.apple.TextEdit",
            terminalText: nil,
            editorFieldHeight: nil,
            editorWindowHeight: nil,
            shellCommandsEnabled: false,
            originalPrefix: nil,
            prefix: nil,
            focusSeq: 7,
            emojiTrigger: false,
            minPrefixChars: 2
        )
        prefixResult = CompletionActivationEvaluator.evaluatePrefix(missing, capabilityGate: gate)
        XCTAssertEqual(prefixResult.decision, .holdCapability(misses: 1))
        prefixResult = CompletionActivationEvaluator.evaluatePrefix(
            missing,
            capabilityGate: prefixResult.capabilityGate
        )
        XCTAssertEqual(prefixResult.decision, .skip(.missingPrefix))

        let idleTerminal = CompletionActivationEvaluator.PrefixSnapshot(
            forced: false,
            bundleId: "com.apple.Terminal",
            terminalText: "mac $ git st",
            editorFieldHeight: nil,
            editorWindowHeight: nil,
            shellCommandsEnabled: false,
            originalPrefix: "mac $ git st",
            prefix: "mac $ git st",
            focusSeq: 8,
            emojiTrigger: false,
            minPrefixChars: 2
        )
        XCTAssertEqual(
            CompletionActivationEvaluator.evaluatePrefix(
                idleTerminal,
                capabilityGate: FocusCapabilityFlickerGate()
            ).decision,
            .skip(.idleContext)
        )

        let emojiDecision = CompletionActivationEvaluator.evaluate(
            actionSnapshot(
                prefix: "hello :+",
                emoji: EmojiCompletion(),
                typo: .likely(run: ":+", correction: "ignored")
            )
        )
        XCTAssertEqual(emojiDecision, .emoji(value: "👍", queryLength: 2))

        XCTAssertEqual(
            CompletionActivationEvaluator.evaluate(
                actionSnapshot(
                    prefix: "hello becuase",
                    typo: .likely(run: "becuase", correction: "because")
                )
            ),
            .correction(value: "because", run: "becuase")
        )
        XCTAssertEqual(
            CompletionActivationEvaluator.evaluate(
                actionSnapshot(
                    prefix: "hello becuase",
                    typo: .likely(run: "becuase", correction: nil)
                )
            ),
            .skip(.typo)
        )

        let shell = actionSnapshot(
            prefix: "mac $ git st",
            shellMode: true,
            terminalText: "mac $ git status\nmac $ git st",
            typo: .notLikely
        )
        XCTAssertEqual(
            CompletionActivationEvaluator.evaluate(shell),
            .shellHistory(remainder: "atus")
        )
    }

    private func actionSnapshot(
        prefix: String,
        shellMode: Bool = false,
        terminalText: String? = nil,
        emoji: EmojiCompletion? = nil,
        typo: CompletionActivationEvaluator.TypoAssessment
    ) -> CompletionActivationEvaluator.Snapshot {
        CompletionActivationEvaluator.Snapshot(
            prefix: prefix,
            shellMode: shellMode,
            terminalText: terminalText,
            nonProseField: false,
            midLineEnabled: true,
            caretAtLineEnd: true,
            emojiEnabled: true,
            emoji: emoji,
            typo: typo,
            holdBackOnTypos: true,
            contextCapturePendingWithoutContext: false
        )
    }
}
