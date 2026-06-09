// MCPBridge — stdio JSON-RPC adapter that lets MCP hosts (Claude Code, Cursor, Continue) call
// the running Shadowtype Local API as tools. Bundled into Shadowtype.app/Contents/Resources/
// shadowtype-mcp; users add `{"command": "/Applications/Shadowtype.app/Contents/Resources/
// shadowtype-mcp"}` to their MCP config.
//
// Transport selection (UDS preferred, TCP fallback):
//   1. Try AF_UNIX connect to `~/Library/Application Support/Shadowtype/api.sock`. UDS is the
//      default because it requires no Bearer token — filesystem permissions (0600) are the auth
//      gate, so the user's MCP config has no secret in it.
//   2. If UDS fails (Shadowtype not running, sandbox, stale socket), fall back to TCP
//      127.0.0.1:{port} with `Authorization: Bearer $SHADOWTYPE_API_KEY`. Port is read from
//      `SHADOWTYPE_API_PORT` env, defaulting to 5666.
//
// Tools exposed (MCP `tools/list`):
//   - `complete`: raw text continuation. Args: { prompt, max_tokens?, temperature?, stop? }
//   - `chat`: chat-template completion. Args: { messages, max_tokens?, temperature?, stop? }
//
// Lifecycle: launched fresh per MCP session. Reads newline-delimited JSON-RPC 2.0 from stdin,
// writes responses to stdout. On stdin EOF (host closing), exits cleanly. Errors are surfaced as
// JSON-RPC error responses so the host renders them in-thread.
import Foundation
import Darwin

// MARK: - Logging
// MCP hosts treat stderr as a diagnostics channel. Logging via stdout would corrupt the
// JSON-RPC stream — every byte written to stdout MUST be a valid JSON-RPC message frame.
func diag(_ msg: String) {
    FileHandle.standardError.write(Data("shadowtype-mcp: \(msg)\n".utf8))
}

// MARK: - HTTP request to local Shadowtype server

struct LocalAPIClient {
    let apiKey: String?      // nil when going over UDS (no auth needed)
    let usingUDS: Bool

    enum Failure: Error {
        case connectFailed(String)
        case ioFailed(String)
        case httpError(Int, String)
        case badResponse(String)
    }

    static func connectOrFail() -> LocalAPIClient? {
        // Prefer UDS — no token needed in the MCP host config.
        let udsPath: String = {
            let dir = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
            return dir + "/Shadowtype/api.sock"
        }()
        if FileManager.default.fileExists(atPath: udsPath) {
            return LocalAPIClient(apiKey: nil, usingUDS: true)
        }
        // TCP fallback.
        let key = ProcessInfo.processInfo.environment["SHADOWTYPE_API_KEY"] ?? ""
        if key.isEmpty {
            diag("WARNING: UDS at \(udsPath) not present and SHADOWTYPE_API_KEY env unset — TCP requests will return 401")
        }
        return LocalAPIClient(apiKey: key, usingUDS: false)
    }

    // Open a fresh socket to either UDS or TCP. Caller closes the returned fd.
    private func openSocket() throws -> Int32 {
        if usingUDS {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 { throw Failure.connectFailed("socket(AF_UNIX) failed errno=\(errno)") }
            let dir = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
            let path = dir + "/Shadowtype/api.sock"
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                    memset(cptr, 0, 104)
                    for (i, b) in path.utf8.prefix(103).enumerated() {
                        cptr[i] = CChar(bitPattern: b)
                    }
                }
            }
            let rc = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if rc < 0 {
                let e = errno
                close(fd)
                throw Failure.connectFailed("UDS connect failed errno=\(e) (is Shadowtype running with Local API enabled?)")
            }
            return fd
        } else {
            let portStr = ProcessInfo.processInfo.environment["SHADOWTYPE_API_PORT"] ?? "5666"
            let port = UInt16(portStr) ?? 5666
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            if fd < 0 { throw Failure.connectFailed("socket(AF_INET) failed errno=\(errno)") }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port.bigEndian)
            addr.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian
            let rc = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc < 0 {
                let e = errno
                close(fd)
                throw Failure.connectFailed("TCP connect to 127.0.0.1:\(port) failed errno=\(e) (is Shadowtype running?)")
            }
            return fd
        }
    }

    // POST a JSON body to /v1/<path>, return the parsed JSON response object. Non-streaming
    // (we set `"stream": false` in the body). Closes the socket. Caller validates the response.
    func post(path: String, body: [String: Any]) throws -> [String: Any] {
        var b = body
        b["stream"] = false   // bridge accumulates; MCP tool results aren't streamed (v1)
        let bodyData = try JSONSerialization.data(withJSONObject: b)
        let fd = try openSocket()
        defer { close(fd) }

        var head = "POST \(path) HTTP/1.1\r\nHost: shadowtype\r\nContent-Length: \(bodyData.count)\r\n"
        head += "Content-Type: application/json\r\nConnection: close\r\n"
        if let key = apiKey, !key.isEmpty {
            head += "Authorization: Bearer \(key)\r\n"
        }
        head += "\r\n"

        try sendAll(fd: fd, data: Data(head.utf8))
        try sendAll(fd: fd, data: bodyData)

        let (status, _, respBody) = try readResponse(fd: fd)
        if status < 200 || status >= 300 {
            let msg = String(data: respBody, encoding: .utf8) ?? "<binary>"
            throw Failure.httpError(status, msg)
        }
        guard let json = try? JSONSerialization.jsonObject(with: respBody) as? [String: Any] else {
            throw Failure.badResponse("response body not JSON object: \(String(data: respBody, encoding: .utf8) ?? "")")
        }
        return json
    }

    private func sendAll(fd: Int32, data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return send(fd, base, remaining.count, 0)
            }
            if n > 0 { remaining = remaining.dropFirst(n); continue }
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.ioFailed("send failed errno=\(errno)")
            }
            throw Failure.ioFailed("send returned 0 (peer closed)")
        }
    }

    // Minimal HTTP/1.1 response reader: parse status line, read headers, read Content-Length
    // bytes of body. We use Connection: close so we don't need chunked encoding handling.
    private func readResponse(fd: Int32) throws -> (status: Int, headers: [String: String], body: Data) {
        var buf = Data()
        // Read until end of headers.
        while !buf.contains(Data([0x0D, 0x0A, 0x0D, 0x0A])) {
            var chunk = [UInt8](repeating: 0, count: 1024)
            let n = recv(fd, &chunk, chunk.count, 0)
            if n == 0 { throw Failure.ioFailed("server closed before sending headers") }
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.ioFailed("recv failed errno=\(errno)")
            }
            buf.append(chunk, count: n)
        }
        let split = buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))!
        let headBytes = buf[..<split.lowerBound]
        var bodyHead = Data(buf[split.upperBound...])
        guard let headStr = String(data: headBytes, encoding: .utf8) else {
            throw Failure.badResponse("header bytes not UTF-8")
        }
        let lines = headStr.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { throw Failure.badResponse("no status line") }
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw Failure.badResponse("bad status line: \(first)")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[..<c].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { headers[k] = v }
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        while bodyHead.count < contentLength {
            var chunk = [UInt8](repeating: 0, count: min(4096, contentLength - bodyHead.count))
            let n = recv(fd, &chunk, chunk.count, 0)
            if n == 0 {
                // Review #9: surfacing this as a partial body led the caller to log
                // "response body not JSON object", hiding the real cause (server died mid-stream
                // e.g. Shadowtype quit while Claude Code had an MCP call in flight). Throw a
                // truncation-specific error so the MCP host sees what actually happened.
                throw Failure.ioFailed("server closed mid-body: got \(bodyHead.count)/\(contentLength) bytes (Shadowtype likely quit during the call)")
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.ioFailed("recv failed errno=\(errno) (mid-body)")
            }
            bodyHead.append(chunk, count: n)
        }
        return (status, headers, bodyHead)
    }
}

// MARK: - MCP JSON-RPC core

let protocolVersion = "2024-11-05"
let serverName = "shadowtype-mcp"
let serverVersion = "1.0.0"

let tools: [[String: Any]] = [
    [
        "name": "complete",
        "description": "Run a raw text completion using the Shadowtype local LLM (no chat template). Best for plain continuation, code completion, or models without a chat template.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "Text the model should continue."],
                "max_tokens": ["type": "integer", "minimum": 1, "maximum": 2048, "default": 256],
                "temperature": ["type": "number", "minimum": 0, "maximum": 2, "default": 0.7],
                "stop": ["type": "array", "items": ["type": "string"], "description": "Stop substrings."],
            ],
            "required": ["prompt"],
        ],
    ],
    [
        "name": "chat",
        "description": "Run a chat completion using the active model's chat template. Standard OpenAI messages shape. Errors if the loaded model has no chat template (use `complete` instead).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "messages": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "role": ["type": "string", "enum": ["system", "user", "assistant"]],
                            "content": ["type": "string"],
                        ],
                        "required": ["role", "content"],
                    ],
                ],
                "max_tokens": ["type": "integer", "minimum": 1, "maximum": 2048, "default": 256],
                "temperature": ["type": "number", "minimum": 0, "maximum": 2, "default": 0.7],
                "stop": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["messages"],
        ],
    ],
]

// Write a JSON-RPC response/notification to stdout as one line of JSON. MCP stdio framing uses
// newline-delimited JSON.
func writeMessage(_ obj: [String: Any]) {
    var obj = obj
    obj["jsonrpc"] = "2.0"
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let line = String(data: data, encoding: .utf8) else {
        diag("failed to serialize response")
        return
    }
    let frame = line + "\n"
    FileHandle.standardOutput.write(Data(frame.utf8))
}

func writeError(id: Any?, code: Int, message: String) {
    writeMessage([
        "id": id ?? NSNull(),
        "error": [
            "code": code,
            "message": message,
        ],
    ])
}

func writeResult(id: Any, result: [String: Any]) {
    writeMessage(["id": id, "result": result])
}

// MARK: - Dispatch

let client = LocalAPIClient.connectOrFail()

func handleInitialize(id: Any) {
    let result: [String: Any] = [
        "protocolVersion": protocolVersion,
        "capabilities": ["tools": [:] as [String: Any]],
        "serverInfo": ["name": serverName, "version": serverVersion],
    ]
    writeResult(id: id, result: result)
}

func handleToolsList(id: Any) {
    writeResult(id: id, result: ["tools": tools])
}

func handleToolsCall(id: Any, params: [String: Any]) {
    guard let name = params["name"] as? String else {
        writeError(id: id, code: -32602, message: "tools/call missing 'name'"); return
    }
    let args = (params["arguments"] as? [String: Any]) ?? [:]

    guard let client else {
        writeError(id: id, code: -32603,
                   message: "Could not connect to Shadowtype (server not running?). Enable Local API in Shadowtype's settings."); return
    }

    do {
        let text: String
        switch name {
        case "complete":
            guard let prompt = args["prompt"] as? String else {
                writeError(id: id, code: -32602, message: "complete: 'prompt' required (string)"); return
            }
            var body: [String: Any] = ["model": "shadowtype", "prompt": prompt]
            forwardCommonArgs(args, into: &body)
            let resp = try client.post(path: "/v1/completions", body: body)
            text = extractTextCompletion(resp)
        case "chat":
            guard let msgs = args["messages"] as? [[String: Any]] else {
                writeError(id: id, code: -32602, message: "chat: 'messages' required (array of {role,content})"); return
            }
            var body: [String: Any] = ["model": "shadowtype", "messages": msgs]
            forwardCommonArgs(args, into: &body)
            let resp = try client.post(path: "/v1/chat/completions", body: body)
            text = extractChatCompletion(resp)
        default:
            writeError(id: id, code: -32601, message: "unknown tool: \(name)"); return
        }
        writeResult(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": false,
        ])
    } catch let LocalAPIClient.Failure.connectFailed(msg) {
        writeError(id: id, code: -32603, message: "Local API connect failed: \(msg)")
    } catch let LocalAPIClient.Failure.httpError(status, msg) {
        writeError(id: id, code: -32603, message: "Local API HTTP \(status): \(msg)")
    } catch let LocalAPIClient.Failure.ioFailed(msg) {
        writeError(id: id, code: -32603, message: "Local API I/O failed: \(msg)")
    } catch let LocalAPIClient.Failure.badResponse(msg) {
        writeError(id: id, code: -32603, message: "Local API bad response: \(msg)")
    } catch {
        writeError(id: id, code: -32603, message: "tool call failed: \(error)")
    }
}

func forwardCommonArgs(_ args: [String: Any], into body: inout [String: Any]) {
    if let m = args["max_tokens"] { body["max_tokens"] = m }
    if let t = args["temperature"] { body["temperature"] = t }
    if let p = args["top_p"] { body["top_p"] = p }
    if let s = args["stop"] { body["stop"] = s }
}

func extractTextCompletion(_ resp: [String: Any]) -> String {
    if let choices = resp["choices"] as? [[String: Any]],
       let first = choices.first,
       let text = first["text"] as? String {
        return text
    }
    return ""
}

func extractChatCompletion(_ resp: [String: Any]) -> String {
    if let choices = resp["choices"] as? [[String: Any]],
       let first = choices.first,
       let message = first["message"] as? [String: Any],
       let content = message["content"] as? String {
        return content
    }
    return ""
}

// MARK: - Stdin loop

diag("starting (transport=\(client?.usingUDS == true ? "UDS" : (client == nil ? "none" : "TCP")))")

let stdin = FileHandle.standardInput
var pending = Data()

while true {
    let data = stdin.availableData
    if data.isEmpty {
        // EOF — host closed the pipe. Clean exit.
        diag("stdin EOF; exiting")
        exit(0)
    }
    pending.append(data)

    // Parse newline-delimited JSON messages.
    while let nl = pending.firstIndex(of: 0x0A) {
        let lineData = pending[..<nl]
        pending.removeSubrange(...nl)
        guard !lineData.isEmpty else { continue }

        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            // Malformed input — ignore. We can't write an error back because we have no id.
            diag("ignoring non-JSON stdin line")
            continue
        }
        let id = obj["id"]
        let method = obj["method"] as? String ?? ""
        let params = (obj["params"] as? [String: Any]) ?? [:]

        switch method {
        case "initialize":
            if let id { handleInitialize(id: id) }
        case "notifications/initialized":
            // No response per MCP spec (it's a notification, has no id).
            break
        case "tools/list":
            if let id { handleToolsList(id: id) }
        case "tools/call":
            if let id { handleToolsCall(id: id, params: params) }
        case "ping":
            if let id { writeResult(id: id, result: [:]) }
        case "":
            // Response to one of our calls (we don't make any). Ignore.
            break
        default:
            if let id {
                writeError(id: id, code: -32601, message: "method not found: \(method)")
            }
        }
    }
}
