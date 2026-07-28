// MCPBridge — stdio JSON-RPC adapter for Shadowtype's local API.
//
// Transport selection:
//   1. Connect to the protected Unix-domain socket.
//   2. If that connection fails, read the protected endpoint discovery file, connect to its
//      loopback port, and authenticate the server with a credential-free HMAC challenge before
//      sending the Bearer key or any tool content.
import Foundation
import CryptoKit
import Darwin

private let maxResponseHeaderBytes = 32 * 1024
private let maxResponseBodyBytes = 8 * 1024 * 1024
private let maxStdinFrameBytes = 1024 * 1024
private let connectTimeoutMilliseconds: Int32 = 2_000
private let socketIOTimeoutMilliseconds: Int32 = {
#if DEBUG
    let environment = ProcessInfo.processInfo.environment
    if environment["SHADOWTYPE_MCP_TESTING"] == "1",
       environment["XCTestConfigurationFilePath"] != nil,
       let raw = environment["SHADOWTYPE_MCP_TEST_IO_TIMEOUT_MS"],
       let value = Int32(raw),
       (50...10_000).contains(value) {
        return value
    }
#endif
    return 10_000
}()

func diag(_ message: String) {
    FileHandle.standardError.write(Data("shadowtype-mcp: \(message)\n".utf8))
}

struct LocalAPIClient {
    enum Endpoint {
        case uds(path: String)
        case tcp(port: UInt16, apiKey: String)
    }

    let endpoint: Endpoint

    var usingUDS: Bool {
        if case .uds = endpoint { return true }
        return false
    }

    enum Failure: Error {
        case connectFailed(String)
        case ioFailed(String)
        case httpError(Int, String)
        case badResponse(String)
        case discoveryFailed(String)
        case authenticationFailed(String)
    }

    private struct Discovery {
        let port: UInt16
        let apiKey: String
    }

    private static var appSupportDirectory: String {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["SHADOWTYPE_MCP_TESTING"] == "1",
           environment["XCTestConfigurationFilePath"] != nil,
           let testDirectory = environment["SHADOWTYPE_MCP_TEST_APP_SUPPORT"],
           testDirectory.hasPrefix("/"),
           !testDirectory.isEmpty {
            return testDirectory
        }
#endif
        let base = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory,
            .userDomainMask,
            true
        ).first ?? NSHomeDirectory()
        return base + "/Shadowtype"
    }

    static func connectOrFail() -> LocalAPIClient? {
        let udsPath = appSupportDirectory + "/api.sock"
        do {
            try validateUDSEndpoint(path: udsPath)
            let probe = try openUDSSocket(path: udsPath)
            close(probe)
            return LocalAPIClient(endpoint: .uds(path: udsPath))
        } catch {
            diag("UDS unavailable (\(describe(error))); trying protected TCP discovery")
        }

        do {
            let discovery = try readProtectedDiscovery(
                path: appSupportDirectory + "/api-endpoint.json"
            )
            return LocalAPIClient(endpoint: .tcp(
                port: discovery.port,
                apiKey: discovery.apiKey
            ))
        } catch {
            diag("TCP discovery/authentication failed: \(describe(error))")
            return nil
        }
    }

    func post(path: String, body: [String: Any]) throws -> [String: Any] {
        var requestBody = body
        requestBody["stream"] = false
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw Failure.badResponse("could not encode request JSON")
        }

        let fd = try openSocket()
        defer { close(fd) }

        let host: String
        let authorization: String
        switch endpoint {
        case .uds:
            host = "localhost"
            authorization = ""
        case let .tcp(port, apiKey):
            try Self.authenticateTCPServer(
                fd: fd,
                port: port,
                apiKey: apiKey,
                keepAlive: true
            )
            host = "127.0.0.1:\(port)"
            authorization = "Authorization: Bearer \(apiKey)\r\n"
        }
        let head =
            "POST \(path) HTTP/1.1\r\n" +
            "Host: \(host)\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Content-Type: application/json\r\n" +
            "Connection: close\r\n" +
            authorization +
            "\r\n"

        let writeDeadline = Self.ioDeadline()
        try Self.sendAll(fd: fd, data: Data(head.utf8), deadline: writeDeadline)
        try Self.sendAll(fd: fd, data: bodyData, deadline: writeDeadline)

        let response = try Self.readResponse(fd: fd)
        guard (200..<300).contains(response.status) else {
            let message = String(data: response.body, encoding: .utf8) ?? "<binary>"
            throw Failure.httpError(response.status, message)
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.body),
              let object = json as? [String: Any] else {
            throw Failure.badResponse("response body is not a JSON object")
        }
        return object
    }

    private func openSocket() throws -> Int32 {
        switch endpoint {
        case let .uds(path):
            try Self.validateUDSEndpoint(path: path)
            return try Self.openUDSSocket(path: path)
        case let .tcp(port, _):
            return try Self.openTCPSocket(port: port)
        }
    }

    private static func validateUDSEndpoint(path: String) throws {
        try validateOwnedDirectory(path: (path as NSString).deletingLastPathComponent)
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw Failure.discoveryFailed("UDS path is absent")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o600 else {
            throw Failure.discoveryFailed("UDS must be an owned 0600 socket")
        }
    }

    private static func validateOwnedDirectory(path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw Failure.discoveryFailed("directory is absent")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o700 else {
            throw Failure.discoveryFailed("directory must be owned by this user with mode 0700")
        }
    }

    private static func readProtectedDiscovery(path: String) throws -> Discovery {
        try validateOwnedDirectory(path: (path as NSString).deletingLastPathComponent)

        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw Failure.discoveryFailed("cannot open endpoint discovery (errno=\(errno))")
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o600,
              info.st_nlink == 1 else {
            throw Failure.discoveryFailed(
                "endpoint discovery must be an owned, single-link 0600 regular file"
            )
        }

        let cap = 4_096
        var bytes = [UInt8](repeating: 0, count: cap + 1)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count >= 0 else {
            throw Failure.discoveryFailed("cannot read endpoint discovery (errno=\(errno))")
        }
        guard count <= cap else {
            throw Failure.discoveryFailed("endpoint discovery exceeds \(cap) bytes")
        }
        let data = Data(bytes.prefix(count))
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any],
              strictInteger(object["version"]) == 1,
              let portValue = strictInteger(object["port"]),
              (1...65_535).contains(portValue),
              let apiKey = object["api_key"] as? String,
              isValidAPIKey(apiKey) else {
            throw Failure.discoveryFailed("endpoint discovery has an invalid schema")
        }
        return Discovery(port: UInt16(portValue), apiKey: apiKey)
    }

    private static func isValidAPIKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let type = String(cString: number.objCType)
        guard !["f", "d"].contains(type) else { return nil }
        return Int(number.stringValue)
    }

    private static func authenticateTCPServer(
        fd: Int32,
        port: UInt16,
        apiKey: String,
        keepAlive: Bool
    ) throws {
        var random = SystemRandomNumberGenerator()
        let challenge = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }
            .map { String(format: "%02x", $0) }
            .joined()

        let request =
            "GET /v1/identity HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(port)\r\n" +
            "X-Shadowtype-Challenge: \(challenge)\r\n" +
            "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        try sendAll(fd: fd, data: Data(request.utf8))
        let response = try readResponse(fd: fd)
        guard response.status == 200,
              let raw = try? JSONSerialization.jsonObject(with: response.body),
              let object = raw as? [String: Any],
              let proof = object["proof"] as? String else {
            throw Failure.authenticationFailed("identity endpoint returned an invalid response")
        }

        let signed = Data(("shadowtype-mcp:" + challenge).utf8)
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: signed,
            using: SymmetricKey(data: Data(apiKey.utf8))
        ))
        guard let actual = decodeHex(proof), constantTimeEqual(actual, expected) else {
            throw Failure.authenticationFailed("identity proof mismatch")
        }
    }

    private static func decodeHex(_ value: String) -> Data? {
        let input = Array(value.utf8)
        guard input.count == 64 else { return nil }
        var output = [UInt8]()
        output.reserveCapacity(32)
        for index in stride(from: 0, to: input.count, by: 2) {
            guard let high = hexNibble(input[index]),
                  let low = hexNibble(input[index + 1]) else {
                return nil
            }
            output.append((high << 4) | low)
        }
        return Data(output)
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func openUDSSocket(path: String) throws -> Int32 {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < capacity else {
            throw Failure.connectFailed("UDS path exceeds sockaddr_un capacity")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Failure.connectFailed("socket(AF_UNIX) failed errno=\(errno)")
        }
        do {
            try configureSocket(fd)
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { bytes in
                    bytes.initialize(repeating: 0, count: capacity)
                    for (index, byte) in pathBytes.enumerated() {
                        bytes[index] = byte
                    }
                }
            }
            try connectWithDeadline(
                fd: fd,
                address: &address,
                length: socklen_t(MemoryLayout<sockaddr_un>.size),
                label: "UDS"
            )
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func openTCPSocket(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw Failure.connectFailed("socket(AF_INET) failed errno=\(errno)")
        }
        do {
            try configureSocket(fd)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_port = in_port_t(port.bigEndian)
            address.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian
            try connectWithDeadline(
                fd: fd,
                address: &address,
                length: socklen_t(MemoryLayout<sockaddr_in>.size),
                label: "TCP 127.0.0.1:\(port)"
            )
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func configureSocket(_ fd: Int32) throws {
        var one: Int32 = 1
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &one,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw Failure.ioFailed("setsockopt(SO_NOSIGPIPE) failed errno=\(errno)")
        }
        var timeout = timeval(
            tv_sec: Int(socketIOTimeoutMilliseconds / 1_000),
            tv_usec: Int32(socketIOTimeoutMilliseconds % 1_000) * 1_000
        )
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw Failure.ioFailed("setsockopt(I/O timeout) failed errno=\(errno)")
        }
    }

    private static func connectWithDeadline<Address>(
        fd: Int32,
        address: inout Address,
        length: socklen_t,
        label: String
    ) throws {
        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0,
              fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw Failure.connectFailed("\(label) could not enable nonblocking connect")
        }

        let result = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        if result < 0 && errno != EINPROGRESS {
            let saved = errno
            _ = fcntl(fd, F_SETFL, originalFlags)
            throw Failure.connectFailed("\(label) connect failed errno=\(saved)")
        }
        if result < 0 {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let deadline = DispatchTime.now().uptimeNanoseconds
                + UInt64(connectTimeoutMilliseconds) * 1_000_000
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else {
                    _ = fcntl(fd, F_SETFL, originalFlags)
                    throw Failure.connectFailed("\(label) connect timed out")
                }
                let remainingNanos = deadline - now
                let remaining = Int32(min(
                    UInt64(Int32.max),
                    max(1, (remainingNanos + 999_999) / 1_000_000)
                ))
                let polled = Darwin.poll(&descriptor, 1, remaining)
                if polled > 0 { break }
                if polled == 0 {
                    _ = fcntl(fd, F_SETFL, originalFlags)
                    throw Failure.connectFailed("\(label) connect timed out")
                }
                if errno != EINTR {
                    let saved = errno
                    _ = fcntl(fd, F_SETFL, originalFlags)
                    throw Failure.connectFailed("\(label) poll failed errno=\(saved)")
                }
            }
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0,
                  socketError == 0 else {
                _ = fcntl(fd, F_SETFL, originalFlags)
                throw Failure.connectFailed(
                    "\(label) connect failed errno=\(socketError == 0 ? errno : socketError)"
                )
            }
        }
        guard fcntl(fd, F_SETFL, originalFlags) == 0 else {
            throw Failure.connectFailed("\(label) could not restore socket flags")
        }
    }

    private static func ioDeadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
            + UInt64(socketIOTimeoutMilliseconds) * 1_000_000
    }

    private static func waitForIO(
        fd: Int32,
        events: Int16,
        deadline: UInt64,
        operation: String
    ) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw Failure.ioFailed("\(operation) timed out")
            }
            let remainingNanos = deadline - now
            let remainingMilliseconds = Int32(min(
                UInt64(Int32.max),
                max(1, (remainingNanos + 999_999) / 1_000_000)
            ))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0,
                      descriptor.revents & Int16(POLLERR) == 0 else {
                    throw Failure.ioFailed("\(operation) socket error")
                }
                return
            }
            if result == 0 {
                throw Failure.ioFailed("\(operation) timed out")
            }
            if errno != EINTR {
                throw Failure.ioFailed("\(operation) poll failed errno=\(errno)")
            }
        }
    }

    private static func sendAll(
        fd: Int32,
        data: Data,
        deadline: UInt64? = nil
    ) throws {
        let deadline = deadline ?? ioDeadline()
        var offset = 0
        while offset < data.count {
            try waitForIO(
                fd: fd,
                events: Int16(POLLOUT),
                deadline: deadline,
                operation: "send"
            )
            let sent = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.send(
                    fd,
                    base.advanced(by: offset),
                    data.count - offset,
                    MSG_DONTWAIT
                )
            }
            if sent > 0 {
                offset += sent
            } else if sent < 0 && errno == EINTR {
                continue
            } else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            } else if sent < 0 {
                throw Failure.ioFailed("send failed errno=\(errno)")
            } else {
                throw Failure.ioFailed("send returned 0")
            }
        }
    }

    private static func readResponse(
        fd: Int32
    ) throws -> (status: Int, headers: [String: String], body: Data) {
        let deadline = ioDeadline()
        let delimiter = Data([13, 10, 13, 10])
        var buffer = Data()
        var split: Range<Data.Index>?
        while split == nil {
            let remaining = maxResponseHeaderBytes + delimiter.count - buffer.count
            guard remaining > 0 else {
                throw Failure.badResponse(
                    "response headers exceed \(maxResponseHeaderBytes) bytes"
                )
            }
            let chunkSize = min(4_096, remaining)
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            try waitForIO(
                fd: fd,
                events: Int16(POLLIN),
                deadline: deadline,
                operation: "response read"
            )
            let received = Darwin.recv(fd, &chunk, chunk.count, MSG_DONTWAIT)
            if received > 0 {
                buffer.append(chunk, count: received)
                split = buffer.range(of: delimiter)
            } else if received == 0 {
                throw Failure.ioFailed("server closed before response headers")
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                throw Failure.ioFailed("response header read failed errno=\(errno)")
            }
        }

        guard let split, split.lowerBound <= maxResponseHeaderBytes else {
            throw Failure.badResponse(
                "response headers exceed \(maxResponseHeaderBytes) bytes"
            )
        }
        let headerData = buffer[..<split.lowerBound]
        var body = Data(buffer[split.upperBound...])
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw Failure.badResponse("response headers are not UTF-8")
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw Failure.badResponse("response has no status line")
        }
        let statusParts = statusLine.split(
            separator: " ",
            maxSplits: 2,
            omittingEmptySubsequences: true
        )
        guard statusParts.count >= 2,
              statusParts[0] == "HTTP/1.1",
              let status = Int(statusParts[1]),
              (100...599).contains(status) else {
            throw Failure.badResponse("invalid response status line")
        }

        var headers: [String: String] = [:]
        var contentLengthValues: [String] = []
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  line.first != " " && line.first != "\t",
                  line.unicodeScalars.allSatisfy({
                      $0.value == 9 || ($0.value >= 32 && $0.value != 127)
                  }),
                  let colon = line.firstIndex(of: ":") else {
                throw Failure.badResponse("malformed response header")
            }
            let name = String(line[..<colon])
            guard !name.isEmpty, name.utf8.allSatisfy(isHeaderTokenByte) else {
                throw Failure.badResponse("malformed response header name")
            }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            let lowerName = name.lowercased()
            if lowerName == "content-length" {
                contentLengthValues.append(value)
            } else if lowerName == "transfer-encoding" {
                throw Failure.badResponse("Transfer-Encoding responses are unsupported")
            }
            if headers[lowerName] == nil {
                headers[lowerName] = value
            }
        }

        guard contentLengthValues.count == 1,
              let contentLength = parseDecimalLength(contentLengthValues[0]),
              contentLength <= maxResponseBodyBytes else {
            throw Failure.badResponse(
                "response requires one valid Content-Length up to \(maxResponseBodyBytes)"
            )
        }
        guard body.count <= contentLength else {
            throw Failure.badResponse("response contains bytes beyond Content-Length")
        }
        while body.count < contentLength {
            let remaining = contentLength - body.count
            var chunk = [UInt8](repeating: 0, count: min(4_096, remaining))
            try waitForIO(
                fd: fd,
                events: Int16(POLLIN),
                deadline: deadline,
                operation: "response read"
            )
            let received = Darwin.recv(fd, &chunk, chunk.count, MSG_DONTWAIT)
            if received > 0 {
                body.append(chunk, count: received)
            } else if received == 0 {
                throw Failure.ioFailed(
                    "server closed mid-body: got \(body.count)/\(contentLength) bytes"
                )
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                throw Failure.ioFailed("response body read failed errno=\(errno)")
            }
        }
        return (status, headers, body)
    }

    private static func parseDecimalLength(_ raw: String) -> Int? {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        var value = 0
        for byte in raw.utf8 {
            let digit = Int(byte - 48)
            guard value <= (Int.max - digit) / 10 else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    private static func isHeaderTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122:
            return true
        case 33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
            return true
        default:
            return false
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let Failure.connectFailed(message),
             let Failure.ioFailed(message),
             let Failure.badResponse(message),
             let Failure.discoveryFailed(message),
             let Failure.authenticationFailed(message):
            return message
        case let Failure.httpError(status, message):
            return "HTTP \(status): \(message)"
        default:
            return String(describing: error)
        }
    }
}

let protocolVersion = "2024-11-05"
let serverName = "shadowtype-mcp"
let serverVersion = "1.0.0"

let tools: [[String: Any]] = [
    [
        "name": "complete",
        "description": "Run a raw text completion using the Shadowtype local LLM.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string"],
                "max_tokens": [
                    "type": "integer", "minimum": 1, "maximum": 2048, "default": 256,
                ],
                "temperature": [
                    "type": "number", "minimum": 0, "maximum": 2, "default": 0.7,
                ],
                "stop": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["prompt"],
            "additionalProperties": false,
        ],
    ],
    [
        "name": "chat",
        "description": "Run a chat completion using the active model's chat template.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "messages": [
                    "type": "array",
                    "minItems": 1,
                    "items": [
                        "type": "object",
                        "properties": [
                            "role": [
                                "type": "string",
                                "enum": ["system", "user", "assistant"],
                            ],
                            "content": ["type": "string"],
                        ],
                        "required": ["role", "content"],
                        "additionalProperties": false,
                    ],
                ],
                "max_tokens": [
                    "type": "integer", "minimum": 1, "maximum": 2048, "default": 256,
                ],
                "temperature": [
                    "type": "number", "minimum": 0, "maximum": 2, "default": 0.7,
                ],
                "stop": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["messages"],
            "additionalProperties": false,
        ],
    ],
]

func writeMessage(_ object: [String: Any]) {
    var object = object
    object["jsonrpc"] = "2.0"
    guard let data = try? JSONSerialization.data(withJSONObject: object) else {
        diag("failed to serialize response")
        return
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func writeError(id: Any?, code: Int, message: String) {
    writeMessage([
        "id": id ?? NSNull(),
        "error": ["code": code, "message": message],
    ])
}

func writeResult(id: Any, result: [String: Any]) {
    writeMessage(["id": id, "result": result])
}

enum ValidatedToolCall {
    case complete([String: Any])
    case chat([String: Any])
}

enum ToolValidationResult {
    case success(ValidatedToolCall)
    case failure(String)
}

func validateToolCall(name: String, arguments: Any?) -> ToolValidationResult {
    guard let arguments = arguments as? [String: Any] else {
        return .failure("arguments must be an object")
    }
    let commonKeys: Set<String> = ["max_tokens", "temperature", "stop"]
    let allowedKeys: Set<String>
    switch name {
    case "complete": allowedKeys = commonKeys.union(["prompt"])
    case "chat": allowedKeys = commonKeys.union(["messages"])
    default: return .failure("unknown tool: \(name)")
    }
    let unknown = Set(arguments.keys).subtracting(allowedKeys)
    guard unknown.isEmpty else {
        return .failure("unknown argument(s): \(unknown.sorted().joined(separator: ", "))")
    }

    var common: [String: Any] = [:]
    if let raw = arguments["max_tokens"] {
        guard let value = strictJSONInteger(raw), (1...2_048).contains(value) else {
            return .failure("'max_tokens' must be an integer from 1 through 2048")
        }
        common["max_tokens"] = value
    }
    if let raw = arguments["temperature"] {
        guard let value = strictJSONNumber(raw), value.isFinite, (0...2).contains(value) else {
            return .failure("'temperature' must be a finite number from 0 through 2")
        }
        common["temperature"] = value
    }
    if let raw = arguments["stop"] {
        guard let values = raw as? [Any] else {
            return .failure("'stop' must be an array of strings")
        }
        var stops: [String] = []
        stops.reserveCapacity(values.count)
        for value in values {
            guard let stop = value as? String else {
                return .failure("'stop' must contain only strings")
            }
            stops.append(stop)
        }
        common["stop"] = stops
    }

    switch name {
    case "complete":
        guard let prompt = arguments["prompt"] as? String else {
            return .failure("'prompt' is required and must be a string")
        }
        common["model"] = "shadowtype"
        common["prompt"] = prompt
        return .success(.complete(common))
    case "chat":
        guard let rawMessages = arguments["messages"] as? [Any],
              !rawMessages.isEmpty else {
            return .failure("'messages' is required and must be a non-empty array")
        }
        var messages: [[String: Any]] = []
        messages.reserveCapacity(rawMessages.count)
        for (index, rawMessage) in rawMessages.enumerated() {
            guard let message = rawMessage as? [String: Any],
                  Set(message.keys) == Set(["role", "content"]),
                  let role = message["role"] as? String,
                  ["system", "user", "assistant"].contains(role),
                  let content = message["content"] as? String else {
                return .failure(
                    "'messages[\(index)]' must contain exactly a valid role and string content"
                )
            }
            messages.append(["role": role, "content": content])
        }
        common["model"] = "shadowtype"
        common["messages"] = messages
        return .success(.chat(common))
    default:
        return .failure("unknown tool: \(name)")
    }
}

func strictJSONInteger(_ value: Any) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else {
        return nil
    }
    let type = String(cString: number.objCType)
    guard !["f", "d"].contains(type) else { return nil }
    return Int(number.stringValue)
}

func strictJSONNumber(_ value: Any) -> Double? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else {
        return nil
    }
    return number.doubleValue
}

func extractTextCompletion(_ response: [String: Any]) throws -> String {
    guard let choices = response["choices"] as? [[String: Any]],
          let first = choices.first,
          let text = first["text"] as? String else {
        throw LocalAPIClient.Failure.badResponse("completion response has no text choice")
    }
    return text
}

func extractChatCompletion(_ response: [String: Any]) throws -> String {
    guard let choices = response["choices"] as? [[String: Any]],
          let first = choices.first,
          let message = first["message"] as? [String: Any],
          let content = message["content"] as? String else {
        throw LocalAPIClient.Failure.badResponse("chat response has no message content")
    }
    return content
}

let client = LocalAPIClient.connectOrFail()

func handleToolsCall(id: Any, params: [String: Any]) {
    guard let name = params["name"] as? String else {
        writeError(id: id, code: -32602, message: "tools/call missing string 'name'")
        return
    }
    let validation = validateToolCall(name: name, arguments: params["arguments"])
    let call: ValidatedToolCall
    switch validation {
    case let .success(value):
        call = value
    case let .failure(message):
        let code = message.hasPrefix("unknown tool:") ? -32601 : -32602
        writeError(id: id, code: code, message: "\(name): \(message)")
        return
    }

    guard let client else {
        writeError(
            id: id,
            code: -32603,
            message: "Could not authenticate the running Shadowtype Local API."
        )
        return
    }

    do {
        let text: String
        switch call {
        case let .complete(body):
            text = try extractTextCompletion(
                client.post(path: "/v1/completions", body: body)
            )
        case let .chat(body):
            text = try extractChatCompletion(
                client.post(path: "/v1/chat/completions", body: body)
            )
        }
        writeResult(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": false,
        ])
    } catch let LocalAPIClient.Failure.connectFailed(message) {
        writeError(id: id, code: -32603, message: "Local API connect failed: \(message)")
    } catch let LocalAPIClient.Failure.httpError(status, message) {
        writeError(id: id, code: -32603, message: "Local API HTTP \(status): \(message)")
    } catch let LocalAPIClient.Failure.ioFailed(message) {
        writeError(id: id, code: -32603, message: "Local API I/O failed: \(message)")
    } catch let LocalAPIClient.Failure.badResponse(message) {
        writeError(id: id, code: -32603, message: "Local API bad response: \(message)")
    } catch let LocalAPIClient.Failure.discoveryFailed(message) {
        writeError(id: id, code: -32603, message: "Local API discovery failed: \(message)")
    } catch let LocalAPIClient.Failure.authenticationFailed(message) {
        writeError(id: id, code: -32603, message: "Local API authentication failed: \(message)")
    } catch {
        writeError(id: id, code: -32603, message: "tool call failed: \(error)")
    }
}

func processFrame(_ lineData: Data) {
    guard let raw = try? JSONSerialization.jsonObject(with: lineData),
          let object = raw as? [String: Any] else {
        writeError(id: nil, code: -32700, message: "parse error")
        return
    }
    let id = object["id"]
    guard let method = object["method"] as? String else {
        if id != nil {
            writeError(id: id, code: -32600, message: "invalid request")
        }
        return
    }

    switch method {
    case "initialize":
        if let id {
            writeResult(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": serverName, "version": serverVersion],
            ])
        }
    case "notifications/initialized":
        break
    case "tools/list":
        if let id { writeResult(id: id, result: ["tools": tools]) }
    case "tools/call":
        guard let id else { return }
        guard let params = object["params"] as? [String: Any] else {
            writeError(id: id, code: -32602, message: "tools/call params must be an object")
            return
        }
        handleToolsCall(id: id, params: params)
    case "ping":
        if let id { writeResult(id: id, result: [:]) }
    default:
        if let id {
            writeError(id: id, code: -32601, message: "method not found: \(method)")
        }
    }
}

diag("starting (transport=\(client?.usingUDS == true ? "UDS" : (client == nil ? "none" : "TCP")))")

let stdin = FileHandle.standardInput
var pending = Data()

while true {
    let data = stdin.availableData
    if data.isEmpty {
        diag("stdin EOF; exiting")
        exit(0)
    }
    pending.append(data)

    while let newline = pending.firstIndex(of: 10) {
        let frameLength = pending.distance(from: pending.startIndex, to: newline)
        guard frameLength <= maxStdinFrameBytes else {
            diag("stdin JSON-RPC frame exceeds \(maxStdinFrameBytes) bytes; terminating")
            exit(1)
        }
        let lineData = Data(pending[..<newline])
        pending.removeSubrange(...newline)
        if !lineData.isEmpty {
            processFrame(lineData)
        }
    }
    guard pending.count <= maxStdinFrameBytes else {
        diag("stdin JSON-RPC frame exceeds \(maxStdinFrameBytes) bytes; terminating")
        exit(1)
    }
}
