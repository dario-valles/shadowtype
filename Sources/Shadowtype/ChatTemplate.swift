// ChatTemplate — thin wrapper around llama.cpp's chat-template helpers. The /v1/chat/completions
// path uses `apply(...)` to render OpenAI `messages` into a single raw prompt string the engine can
// tokenize and continue from. The ghost-text path NEVER goes through here (it's raw-prefix only —
// the FR-CE-5 KV-cache moat depends on token positions staying stable across keystrokes, which a
// chat template would shift).
//
// llama_chat_apply_template is the same function llama-cli uses; it understands every template
// shipped with llama.cpp (chatml, llama-3, gemma, qwen, deepseek, etc.). It is NOT a Jinja parser
// — only the built-in templates are recognized. Custom templates fail with a negative return.
import Foundation
import CLlama

enum ChatTemplate {
    struct Message: Equatable {
        let role: String   // "system" | "user" | "assistant" | ...
        let content: String
    }

    enum Failure: Error, Equatable {
        case noTemplate
        case applyFailed(Int32)
    }

    // Read the chat template baked into the GGUF metadata (tokenizer.chat_template). Returns nil
    // when the model has no template — the API layer then rejects /v1/chat/completions with HTTP
    // 400 and steers the caller to /v1/completions for raw text. `model` is the OpaquePointer the
    // engine holds; pass `name=nil` to get the default template (alternates exist for tool-use).
    static func read(model: OpaquePointer) -> String? {
        guard let cstr = llama_model_chat_template(model, nil) else { return nil }
        let s = String(cString: cstr)
        return s.isEmpty ? nil : s
    }

    // Read `general.architecture` from the GGUF metadata (e.g. "gemma4", "qwen2", "llama"). Used to
    // pick a built-in fallback renderer when llama.cpp's substring detector can't classify the
    // model's baked-in template — newer arches (gemma-4) ship a full Jinja chat_template whose turn
    // markers are constructed by logic, not present as literals, so `llama_chat_apply_template`
    // returns -1 even though the turn format is well-known. Returns nil if the key is absent.
    static func readArchitecture(model: OpaquePointer) -> String? {
        var buf = [CChar](repeating: 0, count: 128)
        let n = buf.withUnsafeMutableBufferPointer { p in
            llama_model_meta_val_str(model, "general.architecture", p.baseAddress, p.count)
        }
        guard n > 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }

    // Dry-run used by the API layer to set `supports_chat` honestly: advertise chat only when we can
    // actually render a prompt — either llama.cpp recognizes the template, or we have a built-in
    // fallback for the architecture. Probes with a single user message; never throws.
    static func canApply(template: String, architecture: String?) -> Bool {
        let probe = [Message(role: "user", content: "ping")]
        if let s = try? apply(template: template, messages: probe, addAssistantPrefix: true,
                              architecture: architecture), !s.isEmpty {
            return true
        }
        return false
    }

    // Render `messages` using `template` (the string read from the model, or one of llama.cpp's
    // built-ins like "chatml"). When `addAssistantPrefix` is true, the template appends the
    // assistant turn-start tokens so the model continues as the assistant — this is what /v1/chat/
    // completions wants. False is for the unusual case of rendering a partial transcript verbatim.
    //
    // Grows the output buffer on overflow once; chat prompts are typically small but a long system
    // message + history can exceed the initial 4 KiB.
    static func apply(template: String, messages: [Message], addAssistantPrefix: Bool,
                      architecture: String? = nil) throws -> String {
        guard !messages.isEmpty else { return "" }

        // strdup makes each role/content a stable malloc'd C string. We can't use String.withCString
        // here because the closures don't compose for a variable-length array of messages — the
        // pointers would dangle as soon as each block exits. Manual allocation + defer is the
        // straightforward shape.
        let roleCStrs: [UnsafeMutablePointer<CChar>?] = messages.map { strdup($0.role) }
        let contentCStrs: [UnsafeMutablePointer<CChar>?] = messages.map { strdup($0.content) }
        defer {
            for p in roleCStrs { if let p { free(p) } }
            for p in contentCStrs { if let p { free(p) } }
        }

        let msgs: [llama_chat_message] = (0..<messages.count).map { i in
            llama_chat_message(
                role: UnsafePointer(roleCStrs[i]),
                content: UnsafePointer(contentCStrs[i])
            )
        }

        // Start at 4 KiB; grow once if llama returns "buffer too small" (a positive value > length).
        var bufSize: Int32 = 4096
        var buf = [CChar](repeating: 0, count: Int(bufSize))

        func invoke() -> Int32 {
            template.withCString { tmplPtr in
                msgs.withUnsafeBufferPointer { msgPtr in
                    buf.withUnsafeMutableBufferPointer { bufPtr in
                        llama_chat_apply_template(
                            tmplPtr,
                            msgPtr.baseAddress,
                            messages.count,
                            addAssistantPrefix,
                            bufPtr.baseAddress,
                            bufSize
                        )
                    }
                }
            }
        }

        var written = invoke()
        if written > bufSize {
            bufSize = written + 1
            buf = [CChar](repeating: 0, count: Int(bufSize))
            written = invoke()
        }
        if written < 0 {
            // llama.cpp couldn't classify this template (custom Jinja it doesn't recognize). Fall
            // back to a hand-rolled renderer keyed on the GGUF architecture before giving up.
            if let fb = renderFallback(architecture: architecture, messages: messages,
                                       addAssistantPrefix: addAssistantPrefix) {
                return fb
            }
            throw Failure.applyFailed(written)
        }

        // The returned length includes the rendered prompt; the buffer is null-terminated.
        return String(cString: buf)
    }

    // Built-in renderers for arches whose shipped chat_template is full Jinja that llama.cpp's
    // substring detector can't classify (returns -1 above). These reproduce the *plain-chat* prompt
    // the template would emit — tool-calling / multimodal extras are intentionally dropped, which is
    // fine for a text-completion API. Returns nil when we have no fallback for the architecture, so
    // the caller still surfaces the original failure.
    private static func renderFallback(architecture: String?, messages: [Message],
                                       addAssistantPrefix: Bool) -> String? {
        guard let arch = architecture?.lowercased() else { return nil }
        if arch.hasPrefix("gemma") {
            return renderGemma(messages: messages, addAssistantPrefix: addAssistantPrefix)
        }
        return nil
    }

    // Gemma turn format: `<start_of_turn>{user|model}\n{content}<end_of_turn>\n`, closing with an
    // open `<start_of_turn>model\n` when a continuation is wanted. Gemma has no system role, so a
    // leading system message is folded into the first user turn (two newlines), matching llama.cpp's
    // own built-in gemma handling. BOS is added at tokenization (addSpecial: true), so none here.
    private static func renderGemma(messages: [Message], addAssistantPrefix: Bool) -> String {
        var pendingSystem = ""
        var out = ""
        for m in messages {
            switch m.role {
            case "system":
                pendingSystem += pendingSystem.isEmpty ? m.content : "\n\n" + m.content
            default:
                let role = (m.role == "assistant" || m.role == "model") ? "model" : "user"
                var content = m.content
                if role == "user", !pendingSystem.isEmpty {
                    content = pendingSystem + "\n\n" + content
                    pendingSystem = ""
                }
                out += "<start_of_turn>\(role)\n\(content)<end_of_turn>\n"
            }
        }
        // A trailing/standalone system message with no following user turn still needs a home.
        if !pendingSystem.isEmpty {
            out += "<start_of_turn>user\n\(pendingSystem)<end_of_turn>\n"
        }
        if addAssistantPrefix {
            out += "<start_of_turn>model\n"
        }
        return out
    }
}
