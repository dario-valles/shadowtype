import XCTest
import Foundation
import CryptoKit
import Darwin

final class MCPBridgeSecurityTests: XCTestCase {
    func testTCPAuthenticatesBeforeSecretAndPromptOnSameConnection() throws {
        let fixture = try MCPBridgeFixture(behavior: .completion)
        defer { fixture.stop() }
        let request = call(
            id: 1,
            tool: "complete",
            arguments: ["prompt": "private prompt", "max_tokens": 16]
        )

        let result = try runBridge(frames: [request], appSupport: fixture.directory)
        XCTAssertEqual(result.status, 0)
        let response = try XCTUnwrap(result.responses[1])
        let payload = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNil(response["error"])
        XCTAssertNotNil(payload["content"])

        let capture = fixture.capture()
        XCTAssertTrue(capture.postFollowedIdentityOnSameConnection)
        XCTAssertEqual(capture.identityRequests.count, 1)
        XCTAssertFalse(capture.identityRequests.joined().contains(fixture.apiKey))
        XCTAssertFalse(capture.identityRequests.joined().contains("private prompt"))
        XCTAssertTrue(capture.postRequest?.contains("Authorization: Bearer \(fixture.apiKey)") == true)
        XCTAssertTrue(capture.postRequest?.contains("private prompt") == true)
    }

    func testWrongIdentityProofSendsNoSecretOrToolContent() throws {
        let fixture = try MCPBridgeFixture(behavior: .wrongProof)
        defer { fixture.stop() }
        let request = call(
            id: 1,
            tool: "complete",
            arguments: ["prompt": "must-not-leak"]
        )

        let result = try runBridge(frames: [request], appSupport: fixture.directory)
        let response = try XCTUnwrap(result.responses[1])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual((error["code"] as? NSNumber)?.intValue, -32603)
        let allRequests = fixture.capture().identityRequests.joined()
        XCTAssertFalse(allRequests.contains(fixture.apiKey))
        XCTAssertFalse(allRequests.contains("must-not-leak"))
        XCTAssertNil(fixture.capture().postRequest)
    }

    func testResponseHeaderAndBodyCapsAreEnforced() throws {
        for behavior in [MCPBridgeFixture.Behavior.oversizedHeader, .oversizedBody] {
            let fixture = try MCPBridgeFixture(behavior: behavior)
            defer { fixture.stop() }
            let result = try runBridge(
                frames: [call(id: 1, tool: "complete", arguments: ["prompt": "x"])],
                appSupport: fixture.directory
            )
            let response = try XCTUnwrap(result.responses[1])
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual((error["code"] as? NSNumber)?.intValue, -32603)
            let message = error["message"] as? String ?? ""
            XCTAssertTrue(
                message.contains("response headers exceed") ||
                message.contains("Content-Length up to"),
                "\(behavior): \(message)"
            )
        }
    }

    func testResponseDeadlineIsAbsoluteAgainstDripFeed() throws {
        let fixture = try MCPBridgeFixture(behavior: .dripHeader)
        defer { fixture.stop() }
        let result = try runBridge(
            frames: [call(id: 1, tool: "complete", arguments: ["prompt": "x"])],
            appSupport: fixture.directory,
            ioTimeoutMilliseconds: 100
        )
        let response = try XCTUnwrap(result.responses[1])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual((error["code"] as? NSNumber)?.intValue, -32603)
        XCTAssertTrue((error["message"] as? String)?.contains("timed out") == true)
    }

    func testDeclaredToolSchemasRejectInvalidValuesAtomically() throws {
        let calls: [[String: Any]] = [
            call(id: 1, tool: "complete", arguments: ["prompt": 7]),
            call(id: 2, tool: "complete", arguments: ["prompt": "x", "max_tokens": true]),
            call(id: 3, tool: "complete", arguments: ["prompt": "x", "max_tokens": 1.5]),
            call(id: 4, tool: "complete", arguments: ["prompt": "x", "max_tokens": 0]),
            call(id: 5, tool: "complete", arguments: ["prompt": "x", "max_tokens": 2049]),
            call(id: 6, tool: "complete", arguments: ["prompt": "x", "temperature": true]),
            call(id: 7, tool: "complete", arguments: ["prompt": "x", "temperature": -0.1]),
            call(id: 8, tool: "complete", arguments: ["prompt": "x", "temperature": 2.1]),
            call(id: 9, tool: "complete", arguments: ["prompt": "x", "stop": ["ok", 9]]),
            call(id: 10, tool: "complete", arguments: ["prompt": "x", "top_p": 0.5]),
            call(id: 11, tool: "chat", arguments: ["messages": "not-an-array"]),
            call(id: 12, tool: "chat", arguments: [
                "messages": [
                    ["role": "user", "content": "valid"],
                    ["role": "tool", "content": "invalid"],
                ],
            ]),
            call(id: 13, tool: "chat", arguments: [
                "messages": [
                    ["role": "user", "content": "valid"],
                    ["role": "assistant", "content": 4],
                ],
            ]),
            call(id: 14, tool: "chat", arguments: [
                "messages": [
                    ["role": "user", "content": "valid", "extra": "rejected"],
                ],
            ]),
            call(id: 15, tool: "chat", arguments: ["messages": []]),
        ]

        let result = try runBridge(frames: calls)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.responses.count, calls.count)
        for id in 1...calls.count {
            let response = try XCTUnwrap(result.responses[id])
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual((error["code"] as? NSNumber)?.intValue, -32602, "id \(id)")
        }
    }

    func testToolSchemaAdvertisesClosedObjects() throws {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
        ]
        let result = try runBridge(frames: [request])
        let response = try XCTUnwrap(result.responses[1])
        let payload = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["complete", "chat"])
        for tool in tools {
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            if tool["name"] as? String == "chat" {
                let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
                let messages = try XCTUnwrap(properties["messages"] as? [String: Any])
                let items = try XCTUnwrap(messages["items"] as? [String: Any])
                XCTAssertEqual(items["additionalProperties"] as? Bool, false)
            }
        }
    }

    func testOversizedStdinFrameTerminatesBridge() throws {
        let oversized = Data(repeating: UInt8(ascii: "x"), count: 1024 * 1024 + 1)
        let result = try runBridge(rawInput: oversized)
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stderr.contains("frame exceeds 1048576 bytes"))
    }

    func testOverflowingIntegerIsRejectedWithoutTruncation() throws {
        let frame = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"complete","arguments":{"prompt":"x","max_tokens":9223372036854775808}}}

        """
        let result = try runBridge(rawInput: Data(frame.utf8))
        let response = try XCTUnwrap(result.responses[1])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual((error["code"] as? NSNumber)?.intValue, -32602)
    }

    func testDiscoveryRejectsInsecureDirectoryBeforeConnecting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-insecure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
        let discovery = directory.appendingPathComponent("api-endpoint.json")
        try Data(
            "{\"version\":1,\"port\":5666,\"api_key\":\"\(String(repeating: "a", count: 64))\"}".utf8
        ).write(to: discovery)
        XCTAssertEqual(chmod(discovery.path, 0o600), 0)

        let result = try runBridge(
            frames: [call(id: 1, tool: "complete", arguments: ["prompt": "secret"])],
            appSupport: directory
        )
        XCTAssertTrue(result.stderr.contains("directory must be owned by this user with mode 0700"))
        XCTAssertFalse(result.stderr.contains("TCP 127.0.0.1"))
    }

    private func call(id: Int, tool: String, arguments: Any) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ]
    }

    private func runBridge(
        frames: [[String: Any]],
        appSupport: URL? = nil,
        ioTimeoutMilliseconds: Int? = nil
    ) throws -> (status: Int32, responses: [Int: [String: Any]], stderr: String) {
        var input = Data()
        for frame in frames {
            input.append(try JSONSerialization.data(withJSONObject: frame))
            input.append(10)
        }
        return try runBridge(
            rawInput: input,
            appSupport: appSupport,
            ioTimeoutMilliseconds: ioTimeoutMilliseconds
        )
    }

    private func runBridge(
        rawInput: Data,
        appSupport: URL? = nil,
        ioTimeoutMilliseconds: Int? = nil
    ) throws -> (status: Int32, responses: [Int: [String: Any]], stderr: String) {
        let executable = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).appendingPathComponent(".build/debug/MCPBridge")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("MCPBridge product has not been built")
        }

        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-input-\(UUID().uuidString)")
        try rawInput.write(to: inputURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inputHandle.close() }

        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = executable
        process.standardInput = inputHandle
        process.standardOutput = output
        process.standardError = errors
        if let appSupport {
            var environment = ProcessInfo.processInfo.environment
            environment["SHADOWTYPE_MCP_TESTING"] = "1"
            environment["SHADOWTYPE_MCP_TEST_APP_SUPPORT"] = appSupport.path
            environment["XCTestConfigurationFilePath"] =
                environment["XCTestConfigurationFilePath"] ?? "/tmp/shadowtype-tests"
            if let ioTimeoutMilliseconds {
                environment["SHADOWTYPE_MCP_TEST_IO_TIMEOUT_MS"] =
                    String(ioTimeoutMilliseconds)
            }
            process.environment = environment
        }
        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        var responses: [Int: [String: Any]] = [:]
        for line in outputData.split(separator: 10) {
            guard let raw = try? JSONSerialization.jsonObject(with: Data(line)),
                  let object = raw as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue else {
                continue
            }
            responses[id] = object
        }
        return (
            process.terminationStatus,
            responses,
            String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}

private final class MCPBridgeFixture: @unchecked Sendable {
    enum Behavior: CustomStringConvertible {
        case completion
        case wrongProof
        case oversizedHeader
        case oversizedBody
        case dripHeader

        var description: String {
            switch self {
            case .completion: return "completion"
            case .wrongProof: return "wrongProof"
            case .oversizedHeader: return "oversizedHeader"
            case .oversizedBody: return "oversizedBody"
            case .dripHeader: return "dripHeader"
            }
        }
    }

    struct Capture {
        let identityRequests: [String]
        let postRequest: String?
        let postFollowedIdentityOnSameConnection: Bool
    }

    let apiKey = String(repeating: "a", count: 64)
    let directory: URL
    private let behavior: Behavior
    private let listenFD: Int32
    private let lock = NSLock()
    private var identities: [String] = []
    private var post: String?
    private var sameConnection = false
    private var stopped = false

    init(behavior: Behavior) throws {
        self.behavior = behavior
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        listenFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard listenFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var yes: Int32 = 1
        setsockopt(
            listenFD,
            SOL_SOCKET,
            SO_REUSEADDR,
            &yes,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = 0
        address.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    listenFD,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0, Darwin.listen(listenFD, 4) == 0 else {
            let savedError = errno
            close(listenFD)
            if savedError == EPERM {
                throw XCTSkip("sandbox does not permit loopback test listeners")
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(savedError))
        }
        var actual = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &actualLength)
            }
        }
        guard named == 0 else {
            close(listenFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let discovery: [String: Any] = [
            "version": 1,
            "port": Int(UInt16(bigEndian: actual.sin_port)),
            "api_key": apiKey,
        ]
        let discoveryURL = directory.appendingPathComponent("api-endpoint.json")
        try JSONSerialization.data(withJSONObject: discovery).write(to: discoveryURL)
        guard chmod(discoveryURL.path, 0o600) == 0 else {
            close(listenFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        Thread.detachNewThread { [self] in serve() }
    }

    func capture() -> Capture {
        lock.lock()
        defer { lock.unlock() }
        return Capture(
            identityRequests: identities,
            postRequest: post,
            postFollowedIdentityOnSameConnection: sameConnection
        )
    }

    func stop() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()
        if shouldStop {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func serve() {
        var connectionIndex = 0
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var noPipe: Int32 = 1
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )
            connectionIndex += 1
            handle(fd: fd, connectionIndex: connectionIndex)
            close(fd)
            if behavior == .wrongProof || connectionIndex >= 1 { return }
        }
    }

    private func handle(fd: Int32, connectionIndex: Int) {
        guard let identity = readRequest(fd: fd) else { return }
        lock.lock()
        identities.append(identity)
        lock.unlock()
        sendIdentity(fd: fd, request: identity)
        if behavior == .wrongProof { return }

        guard let request = readRequest(fd: fd) else { return }
        lock.lock()
        post = request
        sameConnection = true
        lock.unlock()

        switch behavior {
        case .completion:
            sendJSON(
                fd: fd,
                object: ["choices": [["text": "done"]]],
                connection: "close"
            )
        case .oversizedHeader:
            let response =
                "HTTP/1.1 200 OK\r\nX-Pad: \(String(repeating: "x", count: 33 * 1024))" +
                "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            sendAll(fd: fd, data: Data(response.utf8))
        case .oversizedBody:
            sendAll(
                fd: fd,
                data: Data(
                    "HTTP/1.1 200 OK\r\nContent-Length: 8388609\r\nConnection: close\r\n\r\n".utf8
                )
            )
        case .dripHeader:
            sendAll(fd: fd, data: Data("H".utf8))
            usleep(300_000)
        case .wrongProof:
            break
        }
    }

    private func sendIdentity(fd: Int32, request: String) {
        let challenge = header("X-Shadowtype-Challenge", in: request) ?? ""
        let proof: String
        if behavior == .wrongProof {
            proof = String(repeating: "0", count: 64)
        } else {
            let code = HMAC<SHA256>.authenticationCode(
                for: Data(("shadowtype-mcp:" + challenge).utf8),
                using: SymmetricKey(data: Data(apiKey.utf8))
            )
            proof = Data(code).map { String(format: "%02x", $0) }.joined()
        }
        sendJSON(fd: fd, object: ["proof": proof], connection: "keep-alive")
    }

    private func sendJSON(fd: Int32, object: [String: Any], connection: String) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        let head =
            "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n" +
            "Content-Type: application/json\r\nConnection: \(connection)\r\n\r\n"
        sendAll(fd: fd, data: Data(head.utf8) + body)
    }

    private func readRequest(fd: Int32) -> String? {
        let marker = Data([13, 10, 13, 10])
        var data = Data()
        while data.range(of: marker) == nil, data.count < 2 * 1024 * 1024 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { return nil }
            data.append(bytes, count: count)
        }
        guard let split = data.range(of: marker),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else {
            return nil
        }
        let length = Int(header("Content-Length", in: head) ?? "0") ?? 0
        var body = Data(data[split.upperBound...])
        while body.count < length {
            var bytes = [UInt8](repeating: 0, count: min(4096, length - body.count))
            let count = recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { return nil }
            body.append(bytes, count: count)
        }
        return head + "\r\n\r\n" + (String(data: body, encoding: .utf8) ?? "")
    }

    private func header(_ name: String, in request: String) -> String? {
        for line in request.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].caseInsensitiveCompare(name) == .orderedSame {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func sendAll(fd: Int32, data: Data) {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return send(fd, base.advanced(by: offset), data.count - offset, 0)
            }
            guard count > 0 else { return }
            offset += count
        }
    }
}
