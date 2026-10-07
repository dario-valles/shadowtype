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

    // A resolved snippet wins over the typo/autocorrect path and the model, but never in shell mode.
    func testSnippetDecision() {
        let match = SnippetMatch(name: "sig", expansion: "Best,\nD", typedRun: ";sig")
        XCTAssertEqual(
            CompletionActivationEvaluator.evaluate(
                actionSnapshot(prefix: "Thanks ;sig", typo: .likely(run: ";sig", correction: "sign"),
                               snippet: match)
            ),
            .snippet(match)
        )
        XCTAssertEqual(
            CompletionActivationEvaluator.evaluate(
                actionSnapshot(prefix: "mac $ ls ;sig", shellMode: true, terminalText: "mac $ ls ;sig",
                               typo: .notLikely, snippet: match)
            ),
            .generate(prefix: "mac $ ls ;sig", shellMode: true, terminalText: "mac $ ls ;sig")
        )
        let nonProse = CompletionActivationEvaluator.Snapshot(
            prefix: ";sig", shellMode: false, terminalText: nil, nonProseField: true,
            midLineEnabled: true, caretAtLineEnd: true, emojiEnabled: true, emoji: nil,
            typo: .notLikely, holdBackOnTypos: true, contextCapturePendingWithoutContext: false,
            snippet: match)
        XCTAssertEqual(CompletionActivationEvaluator.evaluate(nonProse), .skip(.nonProseField))
    }

    // The snippet trigger bypasses only the word-boundary gate (a partial name ending in `-`).
    func testSnippetTriggerBypassesBoundaryGate() {
        func decision(snippetTrigger: Bool) -> CompletionActivationEvaluator.PrefixDecision {
            CompletionActivationEvaluator.evaluatePrefix(
                .init(forced: false, bundleId: "com.apple.TextEdit", terminalText: nil,
                      editorFieldHeight: nil, editorWindowHeight: nil, shellCommandsEnabled: false,
                      originalPrefix: "Hi ;sig-", prefix: "Hi ;sig-", focusSeq: 1,
                      emojiTrigger: false, minPrefixChars: 2, snippetTrigger: snippetTrigger),
                capabilityGate: FocusCapabilityFlickerGate()
            ).decision
        }
        XCTAssertEqual(decision(snippetTrigger: false), .skip(.notBoundary))
        XCTAssertEqual(decision(snippetTrigger: true), .continueEvaluation(prefix: "Hi ;sig-", shellMode: false))
    }

    private func actionSnapshot(
        prefix: String,
        shellMode: Bool = false,
        terminalText: String? = nil,
        emoji: EmojiCompletion? = nil,
        typo: CompletionActivationEvaluator.TypoAssessment,
        snippet: SnippetMatch? = nil
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
            contextCapturePendingWithoutContext: false,
            snippet: snippet
        )
    }
}
