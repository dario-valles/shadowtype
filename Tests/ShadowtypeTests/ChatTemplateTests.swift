// Pure unit tests for the M0 ChatTemplate helper. `apply(...)` is exercised against llama.cpp's
// built-in "chatml" template (no model load required — llama_chat_apply_template recognizes
// well-known template names directly). `read(model:)` requires a loaded model and is exercised
// only via the swift-build integration with a real GGUF; it's intentionally not unit-tested here.
import XCTest
@testable import Shadowtype

final class ChatTemplateTests: XCTestCase {

    func testApplyChatmlProducesExpectedShape() throws {
        // The "chatml" template wraps each turn in `<|im_start|>role\ncontent<|im_end|>\n`. When
        // addAssistantPrefix=true, llama.cpp appends `<|im_start|>assistant\n` at the end so the
        // model continues as the assistant — exactly what /v1/chat/completions wants.
        let msgs: [ChatTemplate.Message] = [
            .init(role: "system", content: "You are a helpful assistant."),
            .init(role: "user", content: "Hello!"),
        ]
        let out = try ChatTemplate.apply(template: "chatml", messages: msgs, addAssistantPrefix: true)
        XCTAssertTrue(out.contains("<|im_start|>system"),
                      "chatml output should contain the system turn marker; got: \(out)")
        XCTAssertTrue(out.contains("<|im_start|>user"),
                      "chatml output should contain the user turn marker; got: \(out)")
        XCTAssertTrue(out.contains("Hello!"),
                      "user message text should appear in the rendered prompt")
        XCTAssertTrue(out.hasSuffix("<|im_start|>assistant\n"),
                      "addAssistantPrefix=true must end the prompt with the assistant turn opener")
    }

    func testApplyChatmlWithoutAssistantPrefix() throws {
        let msgs: [ChatTemplate.Message] = [.init(role: "user", content: "Hi.")]
        let out = try ChatTemplate.apply(template: "chatml", messages: msgs, addAssistantPrefix: false)
        XCTAssertFalse(out.hasSuffix("<|im_start|>assistant\n"),
                       "addAssistantPrefix=false must NOT append the assistant opener")
    }

    func testApplyEmptyMessagesReturnsEmptyString() throws {
        let out = try ChatTemplate.apply(template: "chatml", messages: [], addAssistantPrefix: true)
        XCTAssertEqual(out, "",
            "empty message list should short-circuit to an empty prompt, not a chat-template skeleton")
    }

    func testApplyUnknownTemplateFails() {
        // An unrecognized template name returns a negative status; with no architecture there's no
        // fallback, so we surface it as Failure.applyFailed.
        XCTAssertThrowsError(
            try ChatTemplate.apply(template: "not-a-real-template-name-xyz",
                                   messages: [.init(role: "user", content: "x")],
                                   addAssistantPrefix: true)
        ) { error in
            switch error {
            case ChatTemplate.Failure.applyFailed: break
            default: XCTFail("expected applyFailed, got \(error)")
            }
        }
    }

    // MARK: - gemma fallback (unparseable Jinja template + architecture)

    // gemma-4 ships a 16 KB tool-calling Jinja chat_template whose turn markers are constructed by
    // logic, not present as literals — llama.cpp's substring detector returns -1. With architecture
    // "gemma4" the built-in renderer engages and produces the standard gemma turn format.
    private static let unparseableJinja = "{%- if x -%}{{ y }}{%- endif -%}"

    func testGemmaFallbackRendersTurnFormat() throws {
        let msgs: [ChatTemplate.Message] = [
            .init(role: "system", content: "Be terse."),
            .init(role: "user", content: "Hello!"),
        ]
        let out = try ChatTemplate.apply(template: Self.unparseableJinja, messages: msgs,
                                         addAssistantPrefix: true, architecture: "gemma4")
        // System has no dedicated gemma role: it folds into the first user turn.
        XCTAssertTrue(out.contains("<start_of_turn>user\nBe terse.\n\nHello!<end_of_turn>\n"),
                      "system should fold into the first user turn; got: \(out)")
        XCTAssertFalse(out.contains("<start_of_turn>system"),
                       "gemma has no system role marker")
        XCTAssertTrue(out.hasSuffix("<start_of_turn>model\n"),
                      "addAssistantPrefix=true must end with the gemma model turn opener; got: \(out)")
        XCTAssertFalse(out.contains("<bos>"),
                       "BOS is added at tokenization (addSpecial), not emitted by the renderer")
    }

    func testGemmaFallbackMapsAssistantToModel() throws {
        let msgs: [ChatTemplate.Message] = [
            .init(role: "user", content: "Hi"),
            .init(role: "assistant", content: "Hey"),
            .init(role: "user", content: "Bye"),
        ]
        let out = try ChatTemplate.apply(template: Self.unparseableJinja, messages: msgs,
                                         addAssistantPrefix: false, architecture: "gemma4")
        XCTAssertTrue(out.contains("<start_of_turn>model\nHey<end_of_turn>\n"),
                      "assistant role must render as gemma's `model`; got: \(out)")
        XCTAssertFalse(out.hasSuffix("<start_of_turn>model\n"),
                       "addAssistantPrefix=false must NOT append a trailing model opener")
    }

    func testUnparseableTemplateWithoutKnownArchStillFails() {
        // No fallback for an unknown architecture → original failure is surfaced.
        XCTAssertThrowsError(
            try ChatTemplate.apply(template: Self.unparseableJinja,
                                   messages: [.init(role: "user", content: "x")],
                                   addAssistantPrefix: true, architecture: "some-future-arch")
        ) { error in
            switch error {
            case ChatTemplate.Failure.applyFailed: break
            default: XCTFail("expected applyFailed, got \(error)")
            }
        }
    }

    func testCanApplyTrueForRecognizedTemplate() {
        XCTAssertTrue(ChatTemplate.canApply(template: "chatml", architecture: nil),
                      "a llama.cpp-recognized template should report chat-capable")
    }

    func testCanApplyTrueViaGemmaFallback() {
        XCTAssertTrue(ChatTemplate.canApply(template: Self.unparseableJinja, architecture: "gemma4"),
                      "unparseable template + gemma arch should report chat-capable via fallback")
    }

    func testCanApplyFalseWhenNoTemplateAndNoFallback() {
        XCTAssertFalse(ChatTemplate.canApply(template: Self.unparseableJinja, architecture: "mystery"),
                       "unparseable template + unknown arch should report NOT chat-capable")
    }
}
