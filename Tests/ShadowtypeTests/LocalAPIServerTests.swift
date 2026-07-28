// LocalAPIServerTests — coverage for the all-ports-busy failure surface and the Bearer-auth
// constant-time compare. The TCP transport
// requires a Bearer token; comparing it with `==`/`!=` would short-circuit on the first mismatching
// byte and leak the key prefix-by-prefix via response timing to a local process that can reach
// 127.0.0.1 but can't read the Keychain. These lock the helper's correctness (timing is not asserted
// here — only that the result is right for matches, mismatches, and length differences).
import XCTest
import CryptoKit
@testable import Shadowtype

final class LocalAPIServerTests: XCTestCase {
    private static let testKey = String(repeating: "ab", count: 32)
    private static let rotatedKey = String(repeating: "cd", count: 32)

    // MARK: - Failure surfacing

    func testAllPortsBusyMessageIsHumanReadable() {
        XCTAssertEqual(LocalAPIServer.allPortsBusyMessage, "Ports 5666\u{2013}5670 are all in use")
    }

    // Occupy every candidate port, then start(): must return nil, set the human-readable
    // lastError, and leave the server fully stopped (no isRunning, no boundPort).
    func testStartAllPortsBusySetsLastErrorAndStaysStopped() {
        var blockers: [Int32] = []
        defer { for fd in blockers { close(fd) } }
        for port in LocalAPIServer.portCandidates {
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { continue }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian
            let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            // A port already busy from another process is busy from start()'s view too — either
            // way every candidate ends up occupied. Keep only the fds we actually bound.
            if bound == 0, Darwin.listen(fd, 1) == 0 { blockers.append(fd) } else { close(fd) }
        }

        // No stop() needed: the failed start() must leave nothing running (that's the assertion) —
        // and stop() would unlink the UDS path of a live Shadowtype instance on this machine.
        let temp = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let server = LocalAPIServer(
            portCandidates: LocalAPIServer.portCandidates,
            udsPath: temp + "/api.sock",
            discoveryPath: temp + "/api-endpoint.json",
            apiKeyProvider: { Self.testKey }
        )
        XCTAssertNil(server.start())
        XCTAssertEqual(server.lastError, LocalAPIServer.allPortsBusyMessage)
        XCTAssertFalse(server.isRunning)
        XCTAssertNil(server.boundPort)
    }

    // MARK: - constantTimeEquals

    func testConstantTimeEqualsMatches() {
        XCTAssertTrue(LocalAPIServer.constantTimeEquals("", ""))
        XCTAssertTrue(LocalAPIServer.constantTimeEquals("abc", "abc"))
        let key = String(repeating: "a1b2", count: 16)  // 64-char hex-shaped key, like a real API key
        XCTAssertTrue(LocalAPIServer.constantTimeEquals(key, key))
        XCTAssertTrue(LocalAPIServer.constantTimeEquals("ünïcоде", "ünïcоде"))  // utf8-byte compare
    }

    func testConstantTimeEqualsRejectsDifferences() {
        XCTAssertFalse(LocalAPIServer.constantTimeEquals("abc", "abd"))   // last byte differs
        XCTAssertFalse(LocalAPIServer.constantTimeEquals("abc", "aXc"))   // middle byte differs
        XCTAssertFalse(LocalAPIServer.constantTimeEquals("Xbc", "abc"))   // first byte differs
        XCTAssertFalse(LocalAPIServer.constantTimeEquals("abc", "abcd"))  // b is a prefix of a-side
        XCTAssertFalse(LocalAPIServer.constantTimeEquals("abcd", "abc"))  // a is longer
        XCTAssertFalse(LocalAPIServer.constantTimeEquals("", "x"))
        XCTAssertFalse(LocalAPIServer.constantTimeEquals("x", ""))
    }

    // MARK: - TCP security policy

    func testTCPAuthenticationOnEveryRoute() throws {
        let fixture = try startFixture()
        defer { fixture.stop() }
        let routes = [
            ("GET", "/v1/health"),
            ("GET", "/v1/models"),
            ("POST", "/v1/completions"),
            ("POST", "/v1/chat/completions"),
        ]
        for (method, path) in routes {
            let body = method == "POST" ? "{}" : ""
            let variants: [(String, Int?)] = [
                ("", 401),
                ("Authorization: Basic \(Self.testKey)\r\n", 401),
                ("Authorization: Bearer  \(Self.testKey)\r\n", 401),
                ("Authorization: Bearer \(Self.testKey) extra\r\n", 401),
                ("Authorization: Bearer wrong\r\n", 401),
                ("Authorization: Bearer \(Self.testKey)\r\n", nil),
            ]
            for (authorization, rejectedStatus) in variants {
                let response = try request(
                    port: fixture.port,
                    raw: "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\n\(authorization)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
                )
                if let rejectedStatus {
                    XCTAssertEqual(status(response), rejectedStatus, "\(method) \(path)")
                } else {
                    XCTAssertNotEqual(status(response), 401, "\(method) \(path)")
                }
            }
        }
    }

    func testTCPRejectsMissingAndNonLoopbackHost() throws {
        let fixture = try startFixture()
        defer { fixture.stop() }
        let missing = try request(
            port: fixture.port,
            raw: "GET /v1/health HTTP/1.1\r\nAuthorization: Bearer \(Self.testKey)\r\n\r\n"
        )
        XCTAssertEqual(status(missing), 421)

        for host in ["example.com", "localhost.evil.com", "127.0.0.1.evil.com", "localhost@evil.com"] {
            let response = try request(
                port: fixture.port,
                raw: "GET /v1/health HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(Self.testKey)\r\n\r\n"
            )
            XCTAssertEqual(status(response), 421, host)
        }
        let local = try request(
            port: fixture.port,
            raw: "GET /v1/health HTTP/1.1\r\nHost: localhost:\(fixture.port)\r\nAuthorization: Bearer \(Self.testKey)\r\n\r\n"
        )
        XCTAssertEqual(status(local), 200)
    }

    func testOriginIsParsedStructurally() throws {
        let fixture = try startFixture()
        defer { fixture.stop() }
        for origin in [
            "http://localhost.evil.com",
            "http://127.0.0.1.evil.com",
            "http://localhost@evil.com",
            "https://localhost",
            "file://",
        ] {
            let response = try request(
                port: fixture.port,
                raw: "GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nOrigin: \(origin)\r\nAuthorization: Bearer \(Self.testKey)\r\n\r\n"
            )
            XCTAssertEqual(status(response), 403, origin)
            XCTAssertFalse(String(decoding: response, as: UTF8.self)
                .contains("Access-Control-Allow-Origin: \(origin)"))
        }
        let allowed = "http://localhost:4321"
        let response = try request(
            port: fixture.port,
            raw: "GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nOrigin: \(allowed)\r\nAuthorization: Bearer \(Self.testKey)\r\n\r\n"
        )
        XCTAssertEqual(status(response), 200)
        XCTAssertTrue(String(decoding: response, as: UTF8.self)
            .contains("Access-Control-Allow-Origin: \(allowed)\r\n"))

        let opaque = try request(
            port: fixture.port,
            raw: "GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nOrigin: null\r\nAuthorization: Bearer \(Self.testKey)\r\n\r\n"
        )
        XCTAssertEqual(status(opaque), 200)
        XCTAssertTrue(String(decoding: opaque, as: UTF8.self)
            .contains("Access-Control-Allow-Origin: null\r\n"))
    }

    func testOPTIONSAllowsOnlyValidatedLoopbackPreflight() throws {
        let fixture = try startFixture()
        defer { fixture.stop() }
        let valid = try request(
            port: fixture.port,
            raw: """
            OPTIONS /v1/chat/completions HTTP/1.1\r
            Host: 127.0.0.1:\(fixture.port)\r
            Origin: http://localhost:3000\r
            Access-Control-Request-Method: POST\r
            Access-Control-Request-Headers: authorization, content-type\r
            \r

            """
        )
        XCTAssertEqual(status(valid), 204)
        XCTAssertTrue(String(decoding: valid, as: UTF8.self)
            .contains("Access-Control-Allow-Origin: http://localhost:3000\r\n"))

        let invalidRequests = [
            "OPTIONS /v1/health HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nAccess-Control-Request-Method: GET\r\n\r\n",
            "OPTIONS /v1/health HTTP/1.1\r\nHost: evil.example\r\nOrigin: http://localhost\r\nAccess-Control-Request-Method: GET\r\n\r\n",
            "OPTIONS /v1/health HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nOrigin: http://localhost.evil.com\r\nAccess-Control-Request-Method: GET\r\n\r\n",
            "OPTIONS /v1/health HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nOrigin: http://localhost\r\nAccess-Control-Request-Method: POST\r\n\r\n",
            "OPTIONS /v1/health HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nOrigin: http://localhost\r\nAccess-Control-Request-Method: GET\r\nAccess-Control-Request-Headers: x-evil\r\n\r\n",
        ]
        for raw in invalidRequests {
            XCTAssertNotEqual(status(try request(port: fixture.port, raw: raw)), 204)
        }
    }

    func testTCPListenerIsBoundExactlyToIPv4Loopback() throws {
        let fixture = try startFixture()
        defer { fixture.stop() }
        XCTAssertEqual(fixture.server.boundTCPIPv4Address(), "127.0.0.1")
    }

    // MARK: - Protected UDS and discovery

    func testUDSAndDiscoveryHaveVerifiedOwnerOnlyPermissions() throws {
        let fixture = try startFixture()
        defer { fixture.stop() }
        XCTAssertLessThan(
            fixture.udsPath.utf8.count,
            MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        )
        XCTAssertTrue(fixture.server.udsIsAvailable)
        assertNode(fixture.directory, type: S_IFDIR, mode: 0o700)
        assertNode(fixture.udsPath, type: S_IFSOCK, mode: 0o600)
        assertNode(fixture.discoveryPath, type: S_IFREG, mode: 0o600)

        let response = try udsRequest(
            path: fixture.udsPath,
            raw: "GET /v1/health HTTP/1.1\r\n\r\n"
        )
        XCTAssertEqual(status(response), 200)
    }

    func testOverlongUDSPathFailsClosedWithoutTruncation() throws {
        try requireLoopbackBindAvailable()
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let overlong = directory + "/" + String(repeating: "x", count: 120)
        XCTAssertGreaterThanOrEqual(
            overlong.utf8.count,
            MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        )
        let server = LocalAPIServer(
            portCandidates: [0],
            udsPath: overlong,
            discoveryPath: directory + "/api-endpoint.json",
            apiKeyProvider: { Self.testKey }
        )
        defer { server.stop() }
        XCTAssertNotNil(server.start())
        XCTAssertFalse(server.udsIsAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlong))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: String(overlong.prefix(MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1))
        ))
    }

    func testUDSRejectsUnprotectableParentAndTCPRemainsBearerProtected() throws {
        try requireLoopbackBindAvailable()
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let blocker = directory + "/not-a-directory"
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker, contents: Data()))
        let server = LocalAPIServer(
            portCandidates: [0],
            udsPath: blocker + "/api.sock",
            discoveryPath: directory + "/api-endpoint.json",
            apiKeyProvider: { Self.testKey }
        )
        defer { server.stop() }
        guard let port = server.start() else { return XCTFail(server.lastError ?? "start failed") }
        XCTAssertFalse(server.udsIsAvailable)
        let response = try request(
            port: port,
            raw: "GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
        )
        XCTAssertEqual(status(response), 401)
    }

    func testServerFailsClosedBeforeBindingWithUnavailableOrInvalidAPIKey() {
        for provider: () -> String? in [{ nil }, { "not-a-valid-key" }] {
            let directory = makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let discoveryPath = directory + "/api-endpoint.json"
            let server = LocalAPIServer(
                portCandidates: [0],
                udsPath: directory + "/api.sock",
                discoveryPath: discoveryPath,
                apiKeyProvider: provider
            )
            XCTAssertNil(server.start())
            XCTAssertFalse(server.isRunning)
            XCTAssertNil(server.boundPort)
            XCTAssertFalse(FileManager.default.fileExists(atPath: discoveryPath))
        }
    }

    func testDiscoveryIdentityProofAndKeyRotationStayConsistent() throws {
        let fixture = try startFixture()
        defer { fixture.stop() }
        var discovered = try discovery(at: fixture.discoveryPath)
        XCTAssertEqual(discovered.version, 1)
        XCTAssertEqual(discovered.port, fixture.port)
        XCTAssertEqual(discovered.apiKey, Self.testKey)
        assertIdentity(port: fixture.port, key: discovered.apiKey)

        NotificationCenter.default.post(
            name: .shadowtypeAPIKeyDidChange,
            object: nil,
            userInfo: ["apiKey": Self.rotatedKey]
        )
        discovered = try discovery(at: fixture.discoveryPath)
        XCTAssertEqual(discovered.apiKey, Self.rotatedKey)
        assertIdentity(port: fixture.port, key: discovered.apiKey)
        let oldKey = try request(
            port: fixture.port,
            raw: "GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nAuthorization: Bearer \(Self.testKey)\r\n\r\n"
        )
        XCTAssertEqual(status(oldKey), 401)
    }

    func testIdentityRejectsMissingMalformedChallengeAndHost() throws {
        let fixture = try startFixture()
        defer { fixture.stop() }
        let requests = [
            "GET /v1/identity HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\n\r\n",
            "GET /v1/identity HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nX-Shadowtype-Challenge: abc\r\n\r\n",
            "GET /v1/identity HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nX-Shadowtype-Challenge: \(String(repeating: "A", count: 64))\r\n\r\n",
        ]
        for raw in requests {
            XCTAssertEqual(status(try request(port: fixture.port, raw: raw)), 400)
        }
        let missingHost = try request(
            port: fixture.port,
            raw: "GET /v1/identity HTTP/1.1\r\nX-Shadowtype-Challenge: \(String(repeating: "a", count: 64))\r\n\r\n"
        )
        XCTAssertEqual(status(missingHost), 421)
    }

    // MARK: - Pre-auth connection admission and deadlines

    func testSlowLorisDeadlineReleasesAdmissionCapacity() throws {
        let fixture = try startFixture(headerTimeout: 0.2, bodyTimeout: 0.4)
        defer { fixture.stop() }
        var slowSockets: [Int32] = []
        defer { slowSockets.forEach { close($0) } }
        for _ in 0..<LocalAPIServer.maxPendingDepth {
            let fd = try tcpConnect(port: fixture.port)
            slowSockets.append(fd)
            XCTAssertTrue(LocalHTTPParser.writeAll(
                fd: fd,
                data: Data("GET /v1/health HTTP/1.1\r\n".utf8)
            ))
        }
        XCTAssertTrue(waitUntil(timeout: 1) {
            fixture.server.admittedConnectionCount == LocalAPIServer.maxPendingDepth
        })

        let busy = try request(
            port: fixture.port,
            raw: "GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nAuthorization: Bearer \(Self.testKey)\r\n\r\n"
        )
        XCTAssertEqual(status(busy), 503)
        XCTAssertTrue(waitUntil(timeout: 1) {
            fixture.server.admittedConnectionCount == 0
        })

        let recovered = try request(
            port: fixture.port,
            raw: "GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nAuthorization: Bearer \(Self.testKey)\r\n\r\n"
        )
        XCTAssertEqual(status(recovered), 200)
    }

    func testHeaderDeadlineIsAbsoluteDespiteDripFeed() throws {
        let fixture = try startFixture(headerTimeout: 0.18, bodyTimeout: 0.5)
        defer { fixture.stop() }
        let fd = try tcpConnect(port: fixture.port)
        defer { close(fd) }
        for byte in "GET".utf8 {
            _ = LocalHTTPParser.writeAll(fd: fd, data: Data([byte]))
            usleep(80_000)
        }
        let response = readResponse(fd: fd)
        XCTAssertEqual(status(response), 408)
        XCTAssertTrue(waitUntil(timeout: 1) { fixture.server.admittedConnectionCount == 0 })
    }

    func testBodyReceiveDeadlineReleasesCapacity() throws {
        let fixture = try startFixture(headerTimeout: 0.2, bodyTimeout: 0.25)
        defer { fixture.stop() }
        let fd = try tcpConnect(port: fixture.port)
        defer { close(fd) }
        XCTAssertTrue(LocalHTTPParser.writeAll(
            fd: fd,
            data: Data("POST /v1/completions HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nContent-Length: 10\r\n\r\n{".utf8)
        ))
        XCTAssertEqual(status(readResponse(fd: fd)), 408)
        XCTAssertTrue(waitUntil(timeout: 1) { fixture.server.admittedConnectionCount == 0 })
    }

    // MARK: - Helpers

    private struct Fixture {
        let server: LocalAPIServer
        let port: Int
        let directory: String
        let udsPath: String
        let discoveryPath: String

        func stop() {
            server.stop()
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    private struct Discovery: Decodable {
        let version: Int
        let port: Int
        let apiKey: String

        enum CodingKeys: String, CodingKey {
            case version, port
            case apiKey = "api_key"
        }
    }

    private func startFixture(headerTimeout: TimeInterval = 1,
                              bodyTimeout: TimeInterval = 1) throws -> Fixture {
        try requireLoopbackBindAvailable()
        let directory = makeTemporaryDirectory()
        let udsPath = directory + "/api.sock"
        let discoveryPath = directory + "/api-endpoint.json"
        let server = LocalAPIServer(
            portCandidates: [0],
            udsPath: udsPath,
            discoveryPath: discoveryPath,
            apiKeyProvider: { Self.testKey },
            headerReceiveTimeout: headerTimeout,
            bodyReceiveTimeout: bodyTimeout
        )
        guard let port = server.start() else {
            try? FileManager.default.removeItem(atPath: directory)
            throw NSError(domain: "LocalAPIServerTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: server.lastError ?? "start failed"])
        }
        return Fixture(server: server, port: port, directory: directory,
                       udsPath: udsPath, discoveryPath: discoveryPath)
    }

    private func requireLoopbackBindAvailable() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian
        let result = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result < 0, errno == EPERM {
            throw XCTSkip("managed sandbox denies AF_INET loopback bind")
        }
    }

    private func makeTemporaryDirectory() -> String {
        // Keep the textual socket path below Darwin's 104-byte sockaddr_un.sun_path limit.
        // NSTemporaryDirectory() expands to a long /var/folders/... prefix on macOS; adding a
        // UUID there makes the intended happy-path fixture genuinely unrepresentable.
        let path = "/tmp/shadowtype-server-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return path
    }

    private func tcpConnect(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED
            close(fd)
            throw POSIXError(code)
        }
        return fd
    }

    private func request(port: Int, raw: String) throws -> Data {
        let fd = try tcpConnect(port: port)
        defer { close(fd) }
        XCTAssertTrue(LocalHTTPParser.writeAll(fd: fd, data: Data(raw.utf8)))
        return readResponse(fd: fd)
    }

    private func udsRequest(path: String, raw: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self,
                                     capacity: pathCapacity) { output in
                memset(output, 0, pathCapacity)
                for (index, byte) in bytes.enumerated() {
                    output[index] = CChar(bitPattern: byte)
                }
            }
        }
        let connected = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        XCTAssertTrue(LocalHTTPParser.writeAll(fd: fd, data: Data(raw.utf8)))
        return readResponse(fd: fd)
    }

    private func readResponse(fd: Int32) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                result.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return result
    }

    private func status(_ response: Data) -> Int? {
        let line = String(decoding: response, as: UTF8.self)
            .components(separatedBy: "\r\n").first ?? ""
        let pieces = line.split(separator: " ")
        return pieces.count > 1 ? Int(pieces[1]) : nil
    }

    private func discovery(at path: String) throws -> Discovery {
        try JSONDecoder().decode(Discovery.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func assertIdentity(port: Int, key: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let challenge = String(repeating: "a1", count: 32)
        let fd = try! tcpConnect(port: port)
        defer { close(fd) }
        XCTAssertTrue(LocalHTTPParser.writeAll(
            fd: fd,
            data: Data("GET /v1/identity HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: keep-alive\r\nX-Shadowtype-Challenge: \(challenge)\r\n\r\n".utf8)
        ), file: file, line: line)
        let response = readOneResponse(fd: fd)
        XCTAssertEqual(status(response), 200, file: file, line: line)
        XCTAssertTrue(String(decoding: response, as: UTF8.self)
            .contains("Connection: keep-alive\r\n"), file: file, line: line)
        let boundary = response.range(of: Data("\r\n\r\n".utf8))!
        let json = try! JSONSerialization.jsonObject(
            with: Data(response[boundary.upperBound...])
        ) as! [String: String]
        let expected = HMAC<SHA256>.authenticationCode(
            for: Data(("shadowtype-mcp:" + challenge).utf8),
            using: SymmetricKey(data: Data(key.utf8))
        ).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(json["proof"], expected, file: file, line: line)

        XCTAssertTrue(LocalHTTPParser.writeAll(
            fd: fd,
            data: Data("POST /v1/completions HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(key)\r\nContent-Length: 2\r\n\r\n{}".utf8)
        ), file: file, line: line)
        XCTAssertEqual(status(readOneResponse(fd: fd)), 503, file: file, line: line)
    }

    private func readOneResponse(fd: Int32) -> Data {
        let separator = Data("\r\n\r\n".utf8)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.range(of: separator) == nil {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return received }
            received.append(buffer, count: count)
        }
        guard let boundary = received.range(of: separator) else { return received }
        let head = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
        let contentLength = head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1]
                .trimmingCharacters(in: .whitespaces)) } ?? 0
        let expectedCount = boundary.upperBound + contentLength
        while received.count < expectedCount {
            let count = recv(fd, &buffer, min(buffer.count, expectedCount - received.count), 0)
            guard count > 0 else { break }
            received.append(buffer, count: count)
        }
        return Data(received.prefix(expectedCount))
    }

    private func assertNode(_ path: String, type: mode_t, mode: mode_t,
                            file: StaticString = #filePath, line: UInt = #line) {
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0, file: file, line: line)
        XCTAssertEqual(info.st_uid, geteuid(), file: file, line: line)
        XCTAssertEqual(info.st_mode & S_IFMT, type, file: file, line: line)
        XCTAssertEqual(info.st_mode & 0o777, mode, file: file, line: line)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }
}
