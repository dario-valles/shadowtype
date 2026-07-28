// LocalAPIServer — the M1 entry point that turns the already-loaded llama.cpp model into a Mac-
// wide product surface. Two transports, one router:
//   - TCP on `127.0.0.1:<port>` (default 5666; cycles to 5670 on EADDRINUSE) for browser tools,
//     Cursor/Zed/Continue/Aider, and the MCP bridge fallback. Bearer-auth required (key from
//     Keychain via APIKeyStore).
//   - Unix Domain Socket at `~/Library/Application Support/Shadowtype/api.sock` for local-only
//     agents (Claude Code, the in-bundle MCP bridge). UDS bypasses Bearer auth — filesystem
//     permissions (mode 0600) are the gate, so the shim doesn't need a token in its config.
//
// Both transports are BSD sockets in blocking mode; each accepted connection runs on a worker
// queue. We cap concurrent in-flight requests via the SAME `inferenceQueue` serialization that
// owns ghost text: requests can stack up but only one decodes at a time. A bounded
// `pendingDepth` returns HTTP 503 when too many requests pile up.
import Foundation
import Darwin
import AppKit
import CryptoKit

final class LocalAPIServer {

    // --- Configuration -----------------------------------------------------------------------

    static let portCandidates: [Int] = [5666, 5667, 5668, 5669, 5670]
    static let maxPendingDepth: Int = 4
    static let defaultHeaderReceiveTimeout: TimeInterval = 5
    static let defaultBodyReceiveTimeout: TimeInterval = 10

    // Human-readable all-ports-busy reason — surfaced verbatim in Settings, so phrase it for users.
    static var allPortsBusyMessage: String {
        "Ports \(portCandidates.first!)\u{2013}\(portCandidates.last!) are all in use"
    }

    // The path matches what the MCP bridge looks for; keep them in sync.
    static var udsPath: String {
        let dir = (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? NSHomeDirectory())
        return dir + "/Shadowtype/api.sock"
    }

    static var discoveryPath: String {
        let dir = (udsPath as NSString).deletingLastPathComponent
        return dir + "/api-endpoint.json"
    }

    // --- State ------------------------------------------------------------------------------

    private(set) var isRunning = false
    private(set) var boundPort: Int? = nil
    private(set) var lastError: String? = nil

    private var tcpFD: Int32 = -1
    private var udsFD: Int32 = -1
    private var tcpAcceptSource: DispatchSourceRead?
    private var udsAcceptSource: DispatchSourceRead?
    private let configuredPorts: [Int]
    private let configuredUDSPath: String?
    private let configuredDiscoveryPath: String
    private let apiKeyProvider: () -> String?
    private let headerReceiveTimeout: TimeInterval
    private let bodyReceiveTimeout: TimeInterval
    private var activeAPIKey: String?
    private var publishedDiscovery = false
    private var publishedDiscoveryData: Data?

    // Worker queue per connection — concurrent because each connection is just I/O + a single
    // inferenceQueue.async dispatch; cheap to spawn but bounded by `pendingDepth`.
    private let workerQueue = DispatchQueue(label: "com.shadowtype.localapi.worker",
                                            qos: .userInitiated, attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "com.shadowtype.localapi.state")
    private var pendingDepth: Int = 0

    // Dependencies (weak — owner is AppDelegate, lives longer than us anyway).
    weak var coordinator: CompletionCoordinator?
    weak var modelManager: ModelManager?

    convenience init() {
        self.init(portCandidates: Self.portCandidates,
                  udsPath: Self.udsPath,
                  discoveryPath: Self.discoveryPath,
                  apiKeyProvider: APIKeyStore.verifiedAPIKey,
                  headerReceiveTimeout: Self.defaultHeaderReceiveTimeout,
                  bodyReceiveTimeout: Self.defaultBodyReceiveTimeout)
    }

    init(portCandidates: [Int],
         udsPath: String?,
         discoveryPath: String,
         apiKeyProvider: @escaping () -> String?,
         headerReceiveTimeout: TimeInterval = LocalAPIServer.defaultHeaderReceiveTimeout,
         bodyReceiveTimeout: TimeInterval = LocalAPIServer.defaultBodyReceiveTimeout) {
        self.configuredPorts = portCandidates
        self.configuredUDSPath = udsPath
        self.configuredDiscoveryPath = discoveryPath
        self.apiKeyProvider = apiKeyProvider
        self.headerReceiveTimeout = headerReceiveTimeout
        self.bodyReceiveTimeout = bodyReceiveTimeout
    }

    // --- Public API -------------------------------------------------------------------------

    // Start TCP + UDS listeners. Idempotent — second call is a no-op while running. Returns the
    // actually bound TCP port on success.
    @discardableResult
    func start() -> Int? {
        if isRunning { return boundPort }
        lastError = nil
        guard let apiKey = apiKeyProvider(), APIKeyStore.isValidAPIKey(apiKey) else {
            lastError = "Could not securely store the local API key"
            return nil
        }
        activeAPIKey = apiKey

        // TCP — cycle through candidate ports until one binds.
        for port in configuredPorts {
            if let binding = bindTCP(port: port) {
                tcpFD = binding.fd
                boundPort = binding.port
                break
            }
        }
        guard boundPort != nil else {
            // Leave state fully stopped: isRunning stays false, no FDs were kept, no accept sources
            // started. Callers read `lastError` to tell the user why start() returned nil.
            lastError = Self.allPortsBusyMessage
            activeAPIKey = nil
            return nil
        }

        if let path = configuredUDSPath {
            udsFD = bindUDS(path: path)
            if udsFD < 0 {
                NSLog("Shadowtype: LocalAPIServer UDS security/bind failed at \(path); TCP only")
            }
        }

        guard let port = boundPort,
              publishDiscovery(port: port, apiKey: apiKey) else {
            lastError = "Could not securely publish the local API endpoint"
            closeBoundSockets()
            boundPort = nil
            activeAPIKey = nil
            return nil
        }

        startAccept()
        isRunning = true
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleAPIKeyChanged(_:)),
            name: .shadowtypeAPIKeyDidChange, object: nil)
        observeSleepWake()
        return boundPort
    }

    func stop() {
        isRunning = false
        tcpAcceptSource?.cancel(); tcpAcceptSource = nil
        udsAcceptSource?.cancel(); udsAcceptSource = nil
        if tcpFD >= 0 { close(tcpFD); tcpFD = -1 }
        if udsFD >= 0 {
            close(udsFD)
            udsFD = -1
            if let path = configuredUDSPath { unlink(path) }
        }
        removePublishedDiscovery()
        activeAPIKey = nil
        boundPort = nil
        NotificationCenter.default.removeObserver(self)
    }

    // Reachable URL for the menu-bar "Copy API URL" affordance.
    var apiURLString: String {
        guard let p = boundPort else { return "" }
        return "http://127.0.0.1:\(p)/v1"
    }

    deinit { stop() }

    // --- TCP bind ---------------------------------------------------------------------------

    private func bindTCP(port: Int) -> (fd: Int32, port: Int)? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { return nil }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // SO_NOSIGPIPE so a peer reset doesn't kill the whole process via SIGPIPE; we already
        // handle EPIPE on send via writeAll's return value.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        // 127.0.0.1 — local only. Never bind 0.0.0.0; that exposes the model to the network.
        addr.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindStatus = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, addrLen)
            }
        }
        if bindStatus < 0 { close(fd); return nil }
        if Darwin.listen(fd, 16) < 0 { close(fd); return nil }
        var actual = addr
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &actual) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &actualLen)
            }
        }
        guard nameStatus == 0 else { close(fd); return nil }
        return (fd, Int(UInt16(bigEndian: actual.sin_port)))
    }

    // --- UDS bind ---------------------------------------------------------------------------

    private func bindUDS(path: String) -> Int32 {
        let dir = (path as NSString).deletingLastPathComponent
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path),
              ensureProtectedDirectory(dir) else { return -1 }
        var stale = stat()
        if lstat(path, &stale) == 0 {
            guard stale.st_uid == geteuid(),
                  stale.st_mode & S_IFMT == S_IFSOCK,
                  unlink(path) == 0 else { return -1 }
        } else if errno != ENOENT {
            return -1
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { cptr in
                memset(cptr, 0, pathCapacity)
                for (i, b) in pathBytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindStatus = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, addrLen)
            }
        }
        if bindStatus < 0 { close(fd); return -1 }
        guard chmod(path, 0o600) == 0,
              verifyNode(path: path, type: S_IFSOCK, mode: 0o600),
              Darwin.listen(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            return -1
        }
        return fd
    }

    private func ensureProtectedDirectory(_ path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == geteuid(),
                  info.st_mode & S_IFMT == S_IFDIR else { return false }
        } else {
            guard errno == ENOENT else { return false }
            do {
                try FileManager.default.createDirectory(atPath: path,
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                return false
            }
            guard lstat(path, &info) == 0,
                  info.st_uid == geteuid(),
                  info.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        guard chmod(path, 0o700) == 0 else { return false }
        return verifyNode(path: path, type: S_IFDIR, mode: 0o700)
    }

    private func verifyNode(path: String, type: mode_t, mode: mode_t) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_uid == geteuid()
            && info.st_mode & S_IFMT == type
            && info.st_mode & 0o777 == mode
    }

    private func publishDiscovery(port: Int, apiKey: String) -> Bool {
        let dir = (configuredDiscoveryPath as NSString).deletingLastPathComponent
        guard ensureProtectedDirectory(dir) else { return false }
        let object: [String: Any] = ["version": 1, "port": port, "api_key": apiKey]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        let temp = dir + "/.api-endpoint-\(UUID().uuidString).tmp"
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        var succeeded = writeFile(fd: fd, data: data)
        if succeeded { succeeded = fsync(fd) == 0 }
        if close(fd) != 0 { succeeded = false }
        guard succeeded,
              chmod(temp, 0o600) == 0,
              verifyNode(path: temp, type: S_IFREG, mode: 0o600),
              rename(temp, configuredDiscoveryPath) == 0,
              verifyNode(path: configuredDiscoveryPath, type: S_IFREG, mode: 0o600) else {
            unlink(temp)
            return false
        }
        publishedDiscovery = true
        publishedDiscoveryData = data
        return true
    }

    private func writeFile(fd: Int32, data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            while offset < bytes.count {
                let amount = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if amount > 0 {
                    offset += amount
                } else if amount < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func removePublishedDiscovery() {
        guard publishedDiscovery else { return }
        if let expected = publishedDiscoveryData,
           readProtectedFile(configuredDiscoveryPath) == expected {
            unlink(configuredDiscoveryPath)
        }
        publishedDiscovery = false
        publishedDiscoveryData = nil
    }

    private func readProtectedFile(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600,
              info.st_size >= 0, info.st_size <= 4096 else { return nil }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while output.count < Int(info.st_size) {
            let amount = Darwin.read(fd, &buffer, min(buffer.count, Int(info.st_size) - output.count))
            if amount > 0 {
                output.append(buffer, count: amount)
            } else if amount < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return output
    }

    private func closeBoundSockets() {
        if tcpFD >= 0 { close(tcpFD); tcpFD = -1 }
        if udsFD >= 0 {
            close(udsFD)
            udsFD = -1
            if let path = configuredUDSPath { unlink(path) }
        }
        removePublishedDiscovery()
    }

    // --- Accept loop --------------------------------------------------------------------------

    private func startAccept() {
        if tcpFD >= 0 {
            let src = DispatchSource.makeReadSource(fileDescriptor: tcpFD, queue: workerQueue)
            src.setEventHandler { [weak self] in self?.acceptOnce(listenFD: self?.tcpFD ?? -1, isUDS: false) }
            src.resume()
            tcpAcceptSource = src
        }
        if udsFD >= 0 {
            let src = DispatchSource.makeReadSource(fileDescriptor: udsFD, queue: workerQueue)
            src.setEventHandler { [weak self] in self?.acceptOnce(listenFD: self?.udsFD ?? -1, isUDS: true) }
            src.resume()
            udsAcceptSource = src
        }
    }

    private func acceptOnce(listenFD: Int32, isUDS: Bool) {
        guard listenFD >= 0 else { return }
        var addr = sockaddr_storage()
        var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let clientFD = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                accept(listenFD, sa, &addrLen)
            }
        }
        if clientFD < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
            NSLog("Shadowtype: LocalAPIServer accept failed errno=\(errno)")
            return
        }
        var yes: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        let admitted: Bool = stateQueue.sync {
            if pendingDepth >= Self.maxPendingDepth { return false }
            pendingDepth += 1
            return true
        }
        guard admitted else {
            LocalHTTPParser.writeResponse(to: clientFD, status: 503, reason: "Service Unavailable",
                                          body: errorJSON("server busy"))
            close(clientFD)
            return
        }

        workerQueue.async { [weak self] in
            guard let self else {
                close(clientFD)
                return
            }
            self.handleConnection(fd: clientFD, isUDS: isUDS)
        }
    }

    // --- Request handling ---------------------------------------------------------------------

    private func handleConnection(fd: Int32, isUDS: Bool) {
        defer {
            close(fd)
            stateQueue.sync { pendingDepth -= 1 }
        }

        guard let request = readRequest(fd: fd) else { return }
        let expectsFollowup = handleParsedRequest(request, fd: fd, isUDS: isUDS,
                                                  identityAllowed: true)
        if expectsFollowup, let followup = readRequest(fd: fd) {
            _ = handleParsedRequest(followup, fd: fd, isUDS: isUDS,
                                    identityAllowed: false)
        }
    }

    private func readRequest(fd: Int32) -> HTTPRequest? {
        do {
            let started = DispatchTime.now()
            return try LocalHTTPParser.read(
                from: fd,
                headerDeadline: started + headerReceiveTimeout,
                bodyDeadline: started + bodyReceiveTimeout
            )
        } catch LocalHTTPError.clientClosed {
            return nil
        } catch LocalHTTPError.deadlineExceeded {
            LocalHTTPParser.writeResponse(to: fd, status: 408, reason: "Request Timeout",
                                          body: errorJSON("request receive deadline exceeded"))
            return nil
        } catch {
            LocalHTTPParser.writeResponse(to: fd, status: 400, reason: "Bad Request",
                                          body: errorJSON("malformed request"))
            return nil
        }
    }

    @discardableResult
    private func handleParsedRequest(_ req: HTTPRequest,
                                     fd: Int32,
                                     isUDS: Bool,
                                     identityAllowed: Bool) -> Bool {
        if !isUDS, !Self.isLoopbackHost(req.header("Host")) {
            LocalHTTPParser.writeResponse(to: fd, status: 421, reason: "Misdirected Request",
                                          body: errorJSON("Host must be loopback"))
            return false
        }
        if let origin = req.header("Origin"), !Self.isAllowedOrigin(origin) {
            LocalHTTPParser.writeResponse(to: fd, status: 403, reason: "Forbidden",
                                          body: errorJSON("Origin must be loopback"))
            return false
        }

        if req.method.uppercased() == "OPTIONS" {
            guard !isUDS, validPreflight(req) else {
                LocalHTTPParser.writeResponse(to: fd, status: 403, reason: "Forbidden",
                                              body: errorJSON("invalid CORS preflight"))
                return false
            }
            LocalHTTPParser.writeResponse(to: fd, status: 204, reason: "No Content",
                                          headers: corsHeaders(req: req))
            return false
        }

        if identityAllowed, !isUDS,
           req.method.uppercased() == "GET", req.path == "/v1/identity" {
            return handleIdentity(request: req, fd: fd)
        }

        // Auth: UDS bypass (filesystem perm gate); TCP requires Bearer match.
        if !isUDS {
            guard let configured = currentAPIKey() else {
                LocalHTTPParser.writeResponse(to: fd, status: 503, reason: "Service Unavailable",
                                              body: errorJSON("API authentication unavailable"))
                return false
            }
            let presented: String? = {
                guard let h = req.header("Authorization"),
                      h.count > "Bearer ".count,
                      h.prefix("Bearer ".count).caseInsensitiveCompare("Bearer ") == .orderedSame
                else { return nil }
                let token = String(h.dropFirst("Bearer ".count))
                guard APIKeyStore.isValidAPIKey(token) else { return nil }
                return token
            }()
            let authorized = presented.map { Self.constantTimeEquals($0, configured) } ?? false
            if !authorized {
                LocalHTTPParser.writeResponse(to: fd, status: 401, reason: "Unauthorized",
                                              headers: corsHeaders(req: req),
                                              body: errorJSON("invalid bearer token"))
                return false
            }
        }

        // Route — pure dispatch over path. Each handler owns its own response/SSE writes; we just
        // give it the fd + request + a CORS-header bag it should include on its response.
        LocalAPIRoutes.dispatch(server: self, request: req, fd: fd, cors: corsHeaders(req: req), isUDS: isUDS)
        return false
    }

    // --- CORS ---------------------------------------------------------------------------------

    // Local browser tools (a webapp on file:// or localhost:*) should be able to talk to the
    // API. Echo back the origin if it's local-ish so credentials work; otherwise omit and let
    // the browser block (no wildcard with credentials).
    private func corsHeaders(req: HTTPRequest) -> [String: String] {
        var hdrs: [String: String] = [
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Authorization, Content-Type",
            "Access-Control-Max-Age": "600",
        ]
        if let origin = req.header("Origin"), Self.isAllowedOrigin(origin) {
            hdrs["Access-Control-Allow-Origin"] = origin
            hdrs["Vary"] = "Origin"
        }
        return hdrs
    }

    static func isLoopbackHost(_ value: String?) -> Bool {
        guard let value, !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("@") else { return false }
        let components = URLComponents(string: "http://\(value)")
        guard let components,
              components.user == nil, components.password == nil,
              components.path.isEmpty,
              components.query == nil, components.fragment == nil,
              let host = components.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static func isAllowedOrigin(_ value: String) -> Bool {
        if value == "null" { return true }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty,
              let host = components.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func validPreflight(_ req: HTTPRequest) -> Bool {
        guard req.header("Origin") != nil,
              let requestedMethod = req.header("Access-Control-Request-Method")?.uppercased()
        else { return false }
        let expectedMethod: String?
        switch req.path {
        case "/v1/health", "/v1/models": expectedMethod = "GET"
        case "/v1/completions", "/v1/chat/completions": expectedMethod = "POST"
        default: expectedMethod = nil
        }
        guard requestedMethod == expectedMethod else { return false }
        if let requestedHeaders = req.header("Access-Control-Request-Headers") {
            let allowed = Set(["authorization", "content-type"])
            let supplied = requestedHeaders.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard !supplied.isEmpty, supplied.allSatisfy(allowed.contains) else { return false }
        }
        return true
    }

    private func handleIdentity(request: HTTPRequest, fd: Int32) -> Bool {
        guard let challenge = request.header("X-Shadowtype-Challenge"),
              challenge.utf8.count == 64,
              challenge.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
              let apiKey = currentAPIKey() else {
            LocalHTTPParser.writeResponse(to: fd, status: 400, reason: "Bad Request",
                                          body: errorJSON("invalid identity challenge"))
            return false
        }
        let input = Data(("shadowtype-mcp:" + challenge).utf8)
        let code = HMAC<SHA256>.authenticationCode(
            for: input,
            using: SymmetricKey(data: Data(apiKey.utf8))
        )
        let proof = code.map { String(format: "%02x", $0) }.joined()
        let body = (try? JSONSerialization.data(withJSONObject: ["proof": proof])) ?? Data()
        return LocalHTTPParser.writeResponse(
            to: fd,
            status: 200,
            reason: "OK",
            headers: [
                "Content-Type": "application/json",
                "Connection": "keep-alive",
            ],
            body: body,
            connectionClose: false
        )
    }

    private func currentAPIKey() -> String? {
        stateQueue.sync { activeAPIKey }
    }

    @objc private func handleAPIKeyChanged(_ notification: Notification) {
        guard isRunning,
              let key = notification.userInfo?["apiKey"] as? String,
              APIKeyStore.isValidAPIKey(key),
              let port = boundPort else { return }
        stateQueue.sync { activeAPIKey = key }
        guard publishDiscovery(port: port, apiKey: key) else {
            NSLog("Shadowtype: API key rotated but endpoint discovery update failed; stopping local API")
            stop()
            return
        }
    }

    var udsIsAvailable: Bool { udsFD >= 0 }
    var admittedConnectionCount: Int { stateQueue.sync { pendingDepth } }

    func boundTCPIPv4Address() -> String? {
        guard tcpFD >= 0 else { return nil }
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(tcpFD, $0, &len) }
        }
        guard result == 0 else { return nil }
        var copied = addr.sin_addr
        var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &copied, &output, socklen_t(output.count)) != nil else { return nil }
        return String(cString: output)
    }

    // --- Sleep/wake re-bind -------------------------------------------------------------------

    // After system sleep the listener fd is sometimes closed by the kernel (varies by Mac
    // generation + power state). Tear down + restart on wake so the server stays up.
    private func observeSleepWake() {
        NotificationCenter.default.removeObserver(self,
            name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(handleDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func handleDidWake() {
        guard isRunning else { return }
        NSLog("Shadowtype: LocalAPIServer re-binding after wake")
        let wasPort = boundPort
        stop()
        let newPort = start()
        if newPort != wasPort {
            NotificationCenter.default.post(name: .shadowtypeLocalAPIDidChange, object: nil)
        }
    }

    // --- Helpers ------------------------------------------------------------------------------

    // Length-independent constant-time string compare for the Bearer check. `==`/`!=` short-circuit on
    // the first mismatching byte, leaking the key prefix byte-by-byte via response timing to a local
    // process that can reach 127.0.0.1 but can't read the Keychain. Folds the length difference into the
    // result and always scans the longer input, so timing reveals neither length nor match position.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        let n = max(ab.count, bb.count)
        var diff: UInt8 = ab.count == bb.count ? 0 : 1
        var i = 0
        while i < n {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= x ^ y
            i += 1
        }
        return diff == 0
    }

    func errorJSON(_ message: String) -> Data {
        // OpenAI-shape error body so clients with their built-in error handling display
        // something sensible rather than "unknown error".
        let body: [String: Any] = [
            "error": [
                "message": message,
                "type": "invalid_request_error",
                "code": NSNull(),
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{\"error\":{\"message\":\"\(message)\"}}".utf8)
    }
}

extension Notification.Name {
    // Posted when the server's binding (port / running state) changes — settings panel + menu bar
    // observe to refresh their displays.
    static let shadowtypeLocalAPIDidChange = Notification.Name("ShadowtypeLocalAPIDidChange")
    static let shadowtypeToggleLocalAPI = Notification.Name("ShadowtypeToggleLocalAPI")
}
