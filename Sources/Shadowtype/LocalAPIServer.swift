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

final class LocalAPIServer {

    // --- Configuration -----------------------------------------------------------------------

    static let portCandidates: [Int] = [5666, 5667, 5668, 5669, 5670]
    static let maxPendingDepth: Int = 4

    // Human-readable all-ports-busy reason — surfaced verbatim in Settings, so phrase it for users.
    static var allPortsBusyMessage: String {
        "Ports \(portCandidates.first!)\u{2013}\(portCandidates.last!) are all in use"
    }

    // The path matches what the MCP bridge looks for; keep them in sync.
    static var udsPath: String {
        let dir = (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? NSHomeDirectory())
        return dir + "/Shadowtype/api.sock"
    }

    // --- State ------------------------------------------------------------------------------

    private(set) var isRunning = false
    private(set) var boundPort: Int? = nil
    private(set) var lastError: String? = nil

    private var tcpFD: Int32 = -1
    private var udsFD: Int32 = -1
    private var tcpAcceptSource: DispatchSourceRead?
    private var udsAcceptSource: DispatchSourceRead?

    // Worker queue per connection — concurrent because each connection is just I/O + a single
    // inferenceQueue.async dispatch; cheap to spawn but bounded by `pendingDepth`.
    private let workerQueue = DispatchQueue(label: "com.shadowtype.localapi.worker",
                                            qos: .userInitiated, attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "com.shadowtype.localapi.state")
    private var pendingDepth: Int = 0

    // Dependencies (weak — owner is AppDelegate, lives longer than us anyway).
    weak var coordinator: CompletionCoordinator?
    weak var modelManager: ModelManager?

    // --- Public API -------------------------------------------------------------------------

    // Start TCP + UDS listeners. Idempotent — second call is a no-op while running. Returns the
    // actually bound TCP port on success.
    @discardableResult
    func start() -> Int? {
        if isRunning { return boundPort }
        lastError = nil

        // TCP — cycle through candidate ports until one binds.
        for port in Self.portCandidates {
            if let fd = bindTCP(port: port) {
                tcpFD = fd
                boundPort = port
                break
            }
        }
        guard boundPort != nil else {
            // Leave state fully stopped: isRunning stays false, no FDs were kept, no accept sources
            // started. Callers read `lastError` to tell the user why start() returned nil.
            lastError = Self.allPortsBusyMessage
            return nil
        }

        // UDS — best-effort. If the UDS bind fails (sandbox / permissions / stale path), the
        // server still serves TCP; we just log and continue. Stale paths from a previous run are
        // unlinked first.
        udsFD = bindUDS(path: Self.udsPath)
        if udsFD < 0 {
            NSLog("Shadowtype: LocalAPIServer UDS bind failed at \(Self.udsPath); TCP only")
        }

        startAccept()
        isRunning = true
        observeSleepWake()
        return boundPort
    }

    func stop() {
        isRunning = false
        tcpAcceptSource?.cancel(); tcpAcceptSource = nil
        udsAcceptSource?.cancel(); udsAcceptSource = nil
        if tcpFD >= 0 { close(tcpFD); tcpFD = -1 }
        // Only unlink the socket path if WE bound it — a server that never started (e.g. all ports
        // busy) must not delete a live instance's UDS socket from its deinit.
        if udsFD >= 0 { close(udsFD); udsFD = -1; unlink(Self.udsPath) }
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

    private func bindTCP(port: Int) -> Int32? {
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
        return fd
    }

    // --- UDS bind ---------------------------------------------------------------------------

    private func bindUDS(path: String) -> Int32 {
        // Ensure parent dir exists.
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)   // remove any stale node from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Copy path bytes into the fixed-size sun_path tuple. Truncate at 103 chars (sun_path
        // is 104 bytes including the nul) — paths longer than that are rejected by the kernel.
        let pathBytes = path.utf8.prefix(103)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                memset(cptr, 0, 104)
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
        // Restrict to owner only — the kernel uses filesystem perms for connect() auth, so this
        // IS the auth gate for UDS. 0600 = read/write for owner, nothing for group/world.
        chmod(path, 0o600)
        if Darwin.listen(fd, 16) < 0 { close(fd); return -1 }
        return fd
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

        workerQueue.async { [weak self] in
            self?.handleConnection(fd: clientFD, isUDS: isUDS)
        }
    }

    // --- Request handling ---------------------------------------------------------------------

    private func handleConnection(fd: Int32, isUDS: Bool) {
        defer { close(fd) }

        let req: HTTPRequest?
        do {
            req = try LocalHTTPParser.read(from: fd)
        } catch LocalHTTPError.clientClosed {
            return
        } catch {
            LocalHTTPParser.writeResponse(to: fd, status: 400, reason: "Bad Request",
                                          body: errorJSON("malformed request"))
            return
        }
        guard let req else { return }

        // CORS preflight short-circuit so browsers don't trip on the auth gate.
        if req.method.uppercased() == "OPTIONS" {
            LocalHTTPParser.writeResponse(to: fd, status: 204, reason: "No Content",
                                          headers: corsHeaders(req: req))
            return
        }

        // Auth: UDS bypass (filesystem perm gate); TCP requires Bearer match.
        if !isUDS {
            let configured = APIKeyStore.ensureAPIKey()
            let presented: String? = {
                guard let h = req.header("Authorization"),
                      h.lowercased().hasPrefix("bearer ") else { return nil }
                return String(h.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
            }()
            let authorized = presented.map { Self.constantTimeEquals($0, configured) } ?? false
            if !authorized {
                LocalHTTPParser.writeResponse(to: fd, status: 401, reason: "Unauthorized",
                                              headers: corsHeaders(req: req),
                                              body: errorJSON("invalid bearer token"))
                return
            }
        }

        // Backpressure: cap simultaneous queued requests so a misbehaving client can't pile up
        // minutes of work behind ghost text. 503 is the standard "try again later" signal; clients
        // (Cursor, llm-cli) handle it with automatic retry/backoff.
        let admitted: Bool = stateQueue.sync {
            if pendingDepth >= Self.maxPendingDepth { return false }
            pendingDepth += 1
            return true
        }
        if !admitted {
            LocalHTTPParser.writeResponse(to: fd, status: 503, reason: "Service Unavailable",
                                          headers: corsHeaders(req: req),
                                          body: errorJSON("server busy"))
            return
        }
        defer { stateQueue.sync { pendingDepth -= 1 } }

        // Route — pure dispatch over path. Each handler owns its own response/SSE writes; we just
        // give it the fd + request + a CORS-header bag it should include on its response.
        LocalAPIRoutes.dispatch(server: self, request: req, fd: fd, cors: corsHeaders(req: req), isUDS: isUDS)
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
        if let origin = req.header("Origin") {
            if origin.hasPrefix("http://localhost") || origin.hasPrefix("http://127.0.0.1")
                || origin == "null" || origin.hasPrefix("file://") {
                hdrs["Access-Control-Allow-Origin"] = origin
                hdrs["Vary"] = "Origin"
            }
        }
        return hdrs
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
