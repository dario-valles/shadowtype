// LocalAPIRoutes — endpoint dispatch + OpenAI-shape request/response codecs for the local
// server. Routes are tiny on purpose: parse the JSON body, validate, build SamplingParams,
// optionally render messages through `ChatTemplate`, call the coordinator's `runRawCompletion`,
// and write either a single JSON response or an SSE stream.
//
// Endpoints (under /v1):
//   GET  /health             — quick liveness + active-model probe
//   GET  /models             — list active model in OpenAI shape (Cursor/llm-cli read this)
//   POST /completions        — raw text continuation (no chat template required)
//   POST /chat/completions   — messages -> render via model's chat template -> completion
//
// All routes share the `runRawCompletion` plumbing on `CompletionCoordinator`; routes never
// call the engine directly.
import Foundation
import Darwin

enum LocalAPIRoutes {

    // Entry point invoked by `LocalAPIServer.handleConnection` after auth+CORS+backpressure pass.
    static func dispatch(server: LocalAPIServer,
                         request: HTTPRequest,
                         fd: Int32,
                         cors: [String: String],
                         isUDS: Bool) {
        let method = request.method.uppercased()
        switch (method, request.path) {
        case ("GET",  "/v1/health"):           handleHealth(server: server, fd: fd, cors: cors)
        case ("GET",  "/v1/models"):           handleModels(server: server, fd: fd, cors: cors)
        case ("POST", "/v1/completions"):      handleCompletions(server: server, request: request, fd: fd, cors: cors, isChat: false)
        case ("POST", "/v1/chat/completions"): handleCompletions(server: server, request: request, fd: fd, cors: cors, isChat: true)
        default:
            LocalHTTPParser.writeResponse(to: fd, status: 404, reason: "Not Found",
                                          headers: cors,
                                          body: server.errorJSON("unknown route"))
        }
    }

    // MARK: - /v1/health -----------------------------------------------------------------------

    private static func handleHealth(server: LocalAPIServer, fd: Int32, cors: [String: String]) {
        let loaded = server.coordinator?.isModelLoaded ?? false
        let active = activeModelName()
        let supportsFIM = server.coordinator?.modelSupportsFIM ?? false
        let supportsChat = server.coordinator?.modelSupportsChat ?? false
        let body: [String: Any] = [
            "ok": loaded,
            "model": active,
            "ctx": 4096,
            "supports_fim": supportsFIM,
            "supports_chat": supportsChat,
            "version": appShortVersion(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{\"ok\":false}".utf8)
        LocalHTTPParser.writeResponse(to: fd, status: 200, reason: "OK",
                                      headers: cors.merging(["Content-Type": "application/json"]) { _, b in b },
                                      body: data)
    }

    // MARK: - /v1/models -----------------------------------------------------------------------

    private static func handleModels(server: LocalAPIServer, fd: Int32, cors: [String: String]) {
        let active = activeModelEntry()
        let supportsFIM = server.coordinator?.modelSupportsFIM ?? false
        let supportsChat = server.coordinator?.modelSupportsChat ?? false
        // OpenAI shape: { object: "list", data: [{ id, object, created, owned_by }] } — plus our
        // own `supports_fim` + `supports_chat` so Cursor/Continue can locally decide whether to
        // send a `suffix` or `messages` field before hitting an endpoint.
        let now = Int(Date().timeIntervalSince1970)
        let data: [String: Any] = [
            "object": "list",
            "data": [[
                "id": active.id,
                "object": "model",
                "created": now,
                "owned_by": "shadowtype",
                "supports_fim": supportsFIM,
                "supports_chat": supportsChat,
            ]],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: data)) ?? Data("{}".utf8)
        LocalHTTPParser.writeResponse(to: fd, status: 200, reason: "OK",
                                      headers: cors.merging(["Content-Type": "application/json"]) { _, b in b },
                                      body: json)
    }

    // MARK: - /v1/completions + /v1/chat/completions -------------------------------------------

    private static func handleCompletions(server: LocalAPIServer,
                                          request: HTTPRequest,
                                          fd: Int32,
                                          cors: [String: String],
                                          isChat: Bool) {
        guard let coordinator = server.coordinator else {
            LocalHTTPParser.writeResponse(to: fd, status: 500, reason: "Server Error",
                                          headers: cors, body: server.errorJSON("coordinator unavailable"))
            return
        }

        // --- Parse JSON body ----------------------------------------------------------------
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            LocalHTTPParser.writeResponse(to: fd, status: 400, reason: "Bad Request",
                                          headers: cors, body: server.errorJSON("body must be JSON object"))
            return
        }

        let stream = (body["stream"] as? Bool) ?? false
        let maxTokens = max(1, min(2048, (body["max_tokens"] as? Int) ?? 256))
        let modelName = (body["model"] as? String) ?? activeModelName()

        // M5 FIM: /v1/completions accepts an optional `suffix` field (OpenAI legacy completions).
        // When set + the active model has FIM tokens, we ship the request through the engine's
        // FIM tokenizer. Reject explicitly when `suffix` is present against a non-FIM model so
        // the client gets a clear error instead of silently raw-prefix continuation that ignores
        // half its input. Chat completions ignore `suffix` (FIM isn't a chat concept).
        let suffix: String? = (!isChat) ? (body["suffix"] as? String) : nil
        if let suffix, !suffix.isEmpty, !coordinator.modelSupportsFIM {
            LocalHTTPParser.writeResponse(to: fd, status: 400, reason: "Bad Request",
                                          headers: cors,
                                          body: server.errorJSON("active model does not support fill-in-middle — omit `suffix` or switch to a FIM-trained model (Qwen-Coder, DeepSeek-Coder, CodeLlama, StarCoder)"))
            return
        }

        // --- Render prompt ------------------------------------------------------------------
        let prompt: String
        do {
            if isChat {
                guard let msgs = body["messages"] as? [[String: Any]], !msgs.isEmpty else {
                    LocalHTTPParser.writeResponse(to: fd, status: 400, reason: "Bad Request",
                                                  headers: cors,
                                                  body: server.errorJSON("messages required"))
                    return
                }
                guard let tmpl = coordinator.modelChatTemplate, !tmpl.isEmpty,
                      coordinator.modelSupportsChat else {
                    LocalHTTPParser.writeResponse(to: fd, status: 400, reason: "Bad Request",
                                                  headers: cors,
                                                  body: server.errorJSON("active model does not support chat rendering — use /v1/completions"))
                    return
                }
                let parsed: [ChatTemplate.Message] = msgs.compactMap { m in
                    guard let role = m["role"] as? String,
                          let content = m["content"] as? String else { return nil }
                    return ChatTemplate.Message(role: role, content: content)
                }
                guard !parsed.isEmpty else {
                    LocalHTTPParser.writeResponse(to: fd, status: 400, reason: "Bad Request",
                                                  headers: cors,
                                                  body: server.errorJSON("messages malformed"))
                    return
                }
                prompt = try ChatTemplate.apply(template: tmpl, messages: parsed, addAssistantPrefix: true,
                                                architecture: coordinator.modelArchitecture)
            } else {
                // OpenAI /v1/completions: `prompt` can be a string or [String]. We accept both.
                if let s = body["prompt"] as? String { prompt = s }
                else if let arr = body["prompt"] as? [String], !arr.isEmpty { prompt = arr.joined(separator: "\n") }
                else {
                    LocalHTTPParser.writeResponse(to: fd, status: 400, reason: "Bad Request",
                                                  headers: cors,
                                                  body: server.errorJSON("prompt required"))
                    return
                }
            }
        } catch ChatTemplate.Failure.applyFailed(let code) {
            LocalHTTPParser.writeResponse(to: fd, status: 400, reason: "Bad Request",
                                          headers: cors,
                                          body: server.errorJSON("chat template apply failed (code \(code))"))
            return
        } catch {
            LocalHTTPParser.writeResponse(to: fd, status: 400, reason: "Bad Request",
                                          headers: cors,
                                          body: server.errorJSON("prompt construction failed: \(error)"))
            return
        }

        // Sampling params from OpenAI-shape fields. `fim` is attached after the prompt is in hand:
        // we already validated above that suffix presence implies FIM support, so we just bundle
        // (prompt, suffix) as the FIM payload and the engine ignores `prompt` in that branch.
        let fim: FIMRequest? = {
            guard let suffix = suffix, !suffix.isEmpty else { return nil }
            return FIMRequest(prefix: prompt, suffix: suffix)
        }()
        // Chat turn-delimiters leak as plain text on GGUFs that don't flag them as EOG tokens
        // (e.g. gemma's `<end_of_turn>` token 106 in some conversions), so the engine's
        // `llama_vocab_is_eog` stop never fires and the sentinel rides out in `content`. Add the
        // common chat-end sentinels as stop strings for chat requests — stop strings are excluded
        // from the emitted output, fixing both the streaming and non-streaming paths model-agnostically.
        let userStops = stopStringsFromBody(body)
        let stops = isChat ? (Self.chatEndSentinels + userStops) : userStops
        let params = SamplingParams.apiClamped(
            temperature: body["temperature"] as? Double,
            topP: body["top_p"] as? Double,
            topK: body["top_k"] as? Int,            // not OpenAI; ours, for clients that pass it
            repeatPenalty: body["frequency_penalty"] as? Double,
            seed: body["seed"] as? Int,
            stop: stops,
            fim: fim,
            // Local debug/QA extension: `"ghost": true` runs the real ghost decode loop so a harness
            // can faithfully test on-screen ghost output (not the rawer API stream). FIM and chat both
            // own their own decode shape, so the flag only applies to plain /v1/completions.
            ghostStopPolicy: (body["ghost"] as? Bool ?? false) && !isChat && fim == nil)

        // --- Run the decode ---------------------------------------------------------------
        let cancelToken = CompletionCoordinator.APIRequestCancelToken()
        let requestID = "shadowtype-" + APIKeyStore.randomHex(byteCount: 8)
        let createdAt = Int(Date().timeIntervalSince1970)

        if stream {
            runStreaming(server: server, fd: fd, cors: cors,
                         coordinator: coordinator,
                         prompt: prompt, params: params, maxTokens: maxTokens,
                         requestID: requestID, createdAt: createdAt,
                         modelName: modelName, isChat: isChat,
                         cancelToken: cancelToken)
        } else {
            runNonStreaming(server: server, fd: fd, cors: cors,
                            coordinator: coordinator,
                            prompt: prompt, params: params, maxTokens: maxTokens,
                            requestID: requestID, createdAt: createdAt,
                            modelName: modelName, isChat: isChat,
                            cancelToken: cancelToken)
        }
    }

    // --- Streaming SSE path -------------------------------------------------------------------

    private static func runStreaming(server: LocalAPIServer,
                                     fd: Int32, cors: [String: String],
                                     coordinator: CompletionCoordinator,
                                     prompt: String, params: SamplingParams, maxTokens: Int,
                                     requestID: String, createdAt: Int,
                                     modelName: String, isChat: Bool,
                                     cancelToken: CompletionCoordinator.APIRequestCancelToken) {
        guard LocalHTTPParser.writeSSEHead(to: fd, extraHeaders: cors) else { return }

        // OpenAI streaming convention: chat completions emit `{ choices: [{delta:{...},index,finish_reason}] }`
        // until done; legacy completions emit `{ choices: [{text, index, finish_reason}] }`.
        let sem = DispatchSemaphore(value: 0)
        var finishReason = "stop"

        coordinator.runRawCompletion(
            prompt: prompt, params: params, maxTokens: maxTokens,
            cancelToken: cancelToken,
            onPiece: { piece in
                let json = encodeChunk(piece: piece, isChat: isChat, requestID: requestID,
                                       createdAt: createdAt, modelName: modelName,
                                       finishReason: nil)
                let ok = LocalHTTPParser.sseEvent(to: fd, json: json)
                if !ok { cancelToken.cancel() }
                return ok
            },
            onComplete: { result in
                switch result {
                case .success: break
                case .failure(.modelNotLoaded):
                    finishReason = "model_not_loaded"
                case .failure(.decodeFailed):
                    finishReason = "error"
                }
                // Final terminal chunk with finish_reason set.
                let json = encodeChunk(piece: "", isChat: isChat, requestID: requestID,
                                       createdAt: createdAt, modelName: modelName,
                                       finishReason: finishReason)
                _ = LocalHTTPParser.sseEvent(to: fd, json: json)
                _ = LocalHTTPParser.sseDone(to: fd)
                sem.signal()
            }
        )
        sem.wait()
    }

    // --- Non-streaming single-response path ---------------------------------------------------

    private static func runNonStreaming(server: LocalAPIServer,
                                        fd: Int32, cors: [String: String],
                                        coordinator: CompletionCoordinator,
                                        prompt: String, params: SamplingParams, maxTokens: Int,
                                        requestID: String, createdAt: Int,
                                        modelName: String, isChat: Bool,
                                        cancelToken: CompletionCoordinator.APIRequestCancelToken) {
        let sem = DispatchSemaphore(value: 0)
        let accLock = NSLock()
        var acc = ""
        var finalError: CompletionCoordinator.LocalAPIError?

        coordinator.runRawCompletion(
            prompt: prompt, params: params, maxTokens: maxTokens,
            cancelToken: cancelToken,
            onPiece: { piece in
                accLock.lock(); acc += piece; accLock.unlock()
                return true
            },
            onComplete: { result in
                if case .failure(let e) = result { finalError = e }
                sem.signal()
            }
        )
        sem.wait()

        if let err = finalError {
            let (status, reason, msg) = mapError(err)
            LocalHTTPParser.writeResponse(to: fd, status: status, reason: reason,
                                          headers: cors.merging(["Content-Type": "application/json"]) { _, b in b },
                                          body: server.errorJSON(msg))
            return
        }

        // Ghost-mode debug flag (`"ghost": true`): the decode loop already ran the ghost STOP policy;
        // now also run the overlay SANITIZER (markup/placeholder/rule strip → list-marker strip →
        // low-value gate) so the response matches what actually renders on screen, not the raw stream.
        // Without this the harness still sees "[Insert ...]"/"<u>...". Only applies to plain completions.
        if params.useEngineStopPolicy, !isChat {
            let cleaned = CompletionCoordinator.strippingLeadingListMarker(
                CompletionCoordinator.sanitizedSuggestion(acc))
            acc = CompletionCoordinator.isLowValueSuggestion(cleaned) ? "" : cleaned
        }

        let json = encodeFinal(text: acc, isChat: isChat, requestID: requestID,
                               createdAt: createdAt, modelName: modelName,
                               promptTokenEstimate: estimateTokens(prompt),
                               completionTokenEstimate: estimateTokens(acc))
        LocalHTTPParser.writeResponse(to: fd, status: 200, reason: "OK",
                                      headers: cors.merging(["Content-Type": "application/json"]) { _, b in b },
                                      body: json)
    }

    // --- Encoders ----------------------------------------------------------------------------

    // One streaming chunk. When `finishReason` is set, this is the terminal chunk; OpenAI clients
    // also expect `data: [DONE]\n\n` after, which the caller emits via `sseDone`.
    private static func encodeChunk(piece: String, isChat: Bool,
                                    requestID: String, createdAt: Int, modelName: String,
                                    finishReason: String?) -> Data {
        if isChat {
            // chat completions stream: delta carries the role only on the first chunk in OpenAI's
            // spec; most clients tolerate role on every chunk. We omit role here and let clients
            // infer "assistant" from the route — Cursor + Continue + llm-cli all accept this.
            var delta: [String: Any] = [:]
            if !piece.isEmpty { delta["content"] = piece }
            var choice: [String: Any] = ["index": 0, "delta": delta]
            if let fr = finishReason { choice["finish_reason"] = fr } else { choice["finish_reason"] = NSNull() }
            let obj: [String: Any] = [
                "id": requestID,
                "object": "chat.completion.chunk",
                "created": createdAt,
                "model": modelName,
                "choices": [choice],
            ]
            return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        } else {
            var choice: [String: Any] = ["index": 0, "text": piece]
            if let fr = finishReason { choice["finish_reason"] = fr } else { choice["finish_reason"] = NSNull() }
            let obj: [String: Any] = [
                "id": requestID,
                "object": "text_completion",
                "created": createdAt,
                "model": modelName,
                "choices": [choice],
            ]
            return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        }
    }

    private static func encodeFinal(text: String, isChat: Bool,
                                    requestID: String, createdAt: Int, modelName: String,
                                    promptTokenEstimate: Int, completionTokenEstimate: Int) -> Data {
        let usage: [String: Int] = [
            "prompt_tokens": promptTokenEstimate,
            "completion_tokens": completionTokenEstimate,
            "total_tokens": promptTokenEstimate + completionTokenEstimate,
        ]
        if isChat {
            let obj: [String: Any] = [
                "id": requestID,
                "object": "chat.completion",
                "created": createdAt,
                "model": modelName,
                "choices": [[
                    "index": 0,
                    "message": ["role": "assistant", "content": text],
                    "finish_reason": "stop",
                ]],
                "usage": usage,
            ]
            return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        } else {
            let obj: [String: Any] = [
                "id": requestID,
                "object": "text_completion",
                "created": createdAt,
                "model": modelName,
                "choices": [[
                    "index": 0,
                    "text": text,
                    "finish_reason": "stop",
                ]],
                "usage": usage,
            ]
            return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        }
    }

    // --- Helpers -----------------------------------------------------------------------------

    // Chat-turn-end sentinels across the instruct families we load (gemma, ChatML/Qwen, Llama-3,
    // Phi, generic). These never legitimately appear in assistant prose, so using them as stop
    // strings for chat requests is safe and strips a leaked delimiter regardless of EOG flagging.
    static let chatEndSentinels: [String] = [
        "<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<|end|>", "<end_of_text>", "</s>",
    ]

    private static func stopStringsFromBody(_ body: [String: Any]) -> [String] {
        if let arr = body["stop"] as? [String] { return arr }
        if let s = body["stop"] as? String { return [s] }
        return []
    }

    private static func activeModelEntry() -> ModelCatalogEntry {
        let id = UserDefaults.standard.string(forKey: ModelManager.selectedModelDefaultsKey)
        if let id, let entry = ModelCatalog.entries.first(where: { $0.id == id }) { return entry }
        return ModelCatalog.entries[0]
    }

    private static func activeModelName() -> String { activeModelEntry().id }

    // Lightweight token estimate for `usage` reporting: ~4 chars per token, English-leaning.
    // Local models have no per-request tokenizer surface here (we'd need to call into the engine
    // again), and the OpenAI clients only display this for cost UX which doesn't apply to a
    // local server. Close-enough beats accurate-and-slow.
    private static func estimateTokens(_ s: String) -> Int { max(1, s.count / 4) }

    // App version pulled from Info.plist so /v1/health is useful for debugging field reports.
    private static func appShortVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    private static func mapError(_ err: CompletionCoordinator.LocalAPIError) -> (Int, String, String) {
        switch err {
        case .modelNotLoaded:  return (503, "Service Unavailable", "no model loaded")
        case .decodeFailed(let inner):
            // Review #2: surface FIM context overflow as a user-fixable 400 ("shorten your
            // prefix/suffix") instead of a generic 500. The engine refuses to silently front-
            // trim a FIM token stream because dropping fim_pre / fim_suf would feed the model
            // framing it was never trained on.
            if case InferenceError.fimContextOverflow(let toks, let cap) = inner {
                return (400, "Bad Request",
                        "FIM prompt+suffix tokenizes to \(toks) tokens but max context is \(cap) — shorten prefix or suffix")
            }
            return (500, "Server Error", "decode failed")
        }
    }
}
