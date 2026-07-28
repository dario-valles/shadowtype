// LocalHTTPParser — minimal HTTP/1.1 request parser + response writer for the local API server.
// Read-only-from-the-socket parser: header block up to `\r\n\r\n`, then Content-Length bytes of
// body. POST/GET only; no chunked request bodies (clients invariably send Content-Length for
// JSON), no pipelining (one request per connection, close on response). SSE responses are
// emitted by `streamSSE(...)` which keeps the socket open and writes `data:` frames until the
// caller is done.
//
// This module is socket-agnostic: it operates on a `(Data) -> Bool` write closure and a
// blocking-style read function the transport provides. That lets the same parser drive both TCP
// (127.0.0.1) and Unix-Domain-Socket (~/Library/Application Support/Shadowtype/api.sock)
// connections from `LocalAPIServer`.
import Foundation
import Darwin

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // header names lowercased
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

enum LocalHTTPError: Error {
    case clientClosed
    case malformedRequest
    case headersTooLarge
    case bodyTooLarge
    case deadlineExceeded
    case ioFailed(Int32)
}

enum LocalHTTPParser {

    // Deadlines are absolute monotonic times. Unlike SO_RCVTIMEO, they bound the whole header or
    // body phase and therefore cannot be extended indefinitely by a peer sending one byte at a
    // time. A nil deadline preserves the blocking behavior used by parser-only callers.
    static func read(from fd: Int32,
                     maxHeaderBytes: Int = 8 * 1024,
                     maxBodyBytes: Int = 1024 * 1024,
                     headerDeadline: DispatchTime? = nil,
                     bodyDeadline: DispatchTime? = nil) throws -> HTTPRequest? {
        guard maxHeaderBytes >= 4, maxBodyBytes >= 0 else {
            throw LocalHTTPError.malformedRequest
        }

        // --- Read header bytes until "\r\n\r\n" ---------------------------------------------
        var buf = Data()
        var sawAny = false
        while true {
            if let range = buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerEnd = range.upperBound
                guard headerEnd <= maxHeaderBytes else {
                    throw LocalHTTPError.headersTooLarge
                }

                let headerData = buf[..<range.lowerBound]
                let bodyHead = Data(buf[headerEnd...])
                guard let headerStr = String(data: headerData, encoding: .utf8) else {
                    throw LocalHTTPError.malformedRequest
                }
                let (method, path, query, headers, contentLength) = try parseHead(headerStr)
                if contentLength > maxBodyBytes { throw LocalHTTPError.bodyTooLarge }
                if bodyHead.count > contentLength { throw LocalHTTPError.malformedRequest }

                var body = bodyHead
                while body.count < contentLength {
                    var chunk = [UInt8](repeating: 0,
                                        count: min(4096, contentLength - body.count))
                    let n = try receive(fd: fd, into: &chunk, deadline: bodyDeadline)
                    if n == 0 { throw LocalHTTPError.clientClosed }
                    body.append(chunk, count: n)
                }
                if try hasImmediatelyAvailableByte(fd: fd) {
                    throw LocalHTTPError.malformedRequest
                }
                return HTTPRequest(method: method, path: path, query: query,
                                   headers: headers, body: body)
            }

            // The full header section includes the terminating CRLFCRLF. If the cap is already
            // occupied without a terminator, no valid request can still fit.
            if buf.count >= maxHeaderBytes { throw LocalHTTPError.headersTooLarge }
            let readCount = min(1024, maxHeaderBytes - buf.count)
            var chunk = [UInt8](repeating: 0, count: readCount)
            let n = try receive(fd: fd, into: &chunk, deadline: headerDeadline)
            if n == 0 {
                if sawAny { throw LocalHTTPError.clientClosed }
                return nil
            }
            sawAny = true
            buf.append(chunk, count: n)
        }
    }

    private static func parseHead(_ s: String) throws
        -> (method: String, path: String, query: [String: String],
            headers: [String: String], contentLength: Int) {
        let lines = s.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty,
              !containsControl(requestLine) else {
            throw LocalHTTPError.malformedRequest
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty, isHTTPToken(parts[0]),
              !parts[1].isEmpty,
              parts[2] == "HTTP/1.1" else {
            throw LocalHTTPError.malformedRequest
        }
        let method = String(parts[0])
        let rawTarget = String(parts[1])
        let (path, query) = splitQuery(rawTarget)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, !containsControl(line),
                  let colon = line.firstIndex(of: ":") else {
                throw LocalHTTPError.malformedRequest
            }
            let rawName = line[..<colon]
            guard !rawName.isEmpty, isHTTPToken(rawName) else {
                throw LocalHTTPError.malformedRequest
            }
            let name = rawName.lowercased()
            guard headers[name] == nil else {
                // All headers used by this local API are singletons. Rejecting duplicates avoids
                // downstream Host/Origin/Authorization ambiguity as well as duplicate CL.
                throw LocalHTTPError.malformedRequest
            }
            let rawValue = line[line.index(after: colon)...]
            let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: " "))
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil {
            // Chunked and other transfer codings are deliberately unsupported. This also rejects
            // every TE/CL conflict instead of guessing which framing wins.
            throw LocalHTTPError.malformedRequest
        }

        var contentLength = 0
        if let rawLength = headers["content-length"] {
            guard !rawLength.isEmpty,
                  rawLength.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let parsed = Int(rawLength) else {
                throw LocalHTTPError.malformedRequest
            }
            contentLength = parsed
        }
        return (method, path, query, headers, contentLength)
    }

    private static func isHTTPToken<S: StringProtocol>(_ value: S) -> Bool {
        value.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                return true
            case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E,
                 0x5E, 0x5F, 0x60, 0x7C, 0x7E:
                return true
            default:
                return false
            }
        }
    }

    private static func containsControl<S: StringProtocol>(_ value: S) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    private static func receive(fd: Int32,
                                into buffer: inout [UInt8],
                                deadline: DispatchTime?) throws -> Int {
        while true {
            if let deadline {
                try waitUntilReadable(fd: fd, deadline: deadline)
            }
            let count = buffer.count
            let received = recv(fd, &buffer, count, 0)
            if received >= 0 { return received }
            if errno == EINTR { continue }
            throw LocalHTTPError.ioFailed(errno)
        }
    }

    private static func waitUntilReadable(fd: Int32, deadline: DispatchTime) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            let end = deadline.uptimeNanoseconds
            guard now < end else { throw LocalHTTPError.deadlineExceeded }
            let remaining = end - now
            let roundedMilliseconds = remaining / 1_000_000
                + (remaining % 1_000_000 == 0 ? 0 : 1)
            let milliseconds = min(
                UInt64(Int32.max),
                roundedMilliseconds
            )
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, Int32(milliseconds))
            if result > 0 {
                if descriptor.revents & Int16(POLLNVAL) != 0 {
                    throw LocalHTTPError.ioFailed(EBADF)
                }
                return
            }
            if result == 0 { throw LocalHTTPError.deadlineExceeded }
            if errno == EINTR { continue }
            throw LocalHTTPError.ioFailed(errno)
        }
    }

    private static func hasImmediatelyAvailableByte(fd: Int32) throws -> Bool {
        var byte: UInt8 = 0
        while true {
            let result = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if result > 0 { return true }
            if result == 0 { return false }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            throw LocalHTTPError.ioFailed(errno)
        }
    }

    private static func splitQuery(_ target: String) -> (path: String, query: [String: String]) {
        guard let qIdx = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<qIdx])
        let qs = target[target.index(after: qIdx)...]
        var dict: [String: String] = [:]
        // Review #3: a query pair literally `=` (or `=value`) used to crash here — the default
        // `split(separator:)` omits empty subsequences, so `"=".split(separator: "=", maxSplits: 1)`
        // returns []. Pass omittingEmptySubsequences: false and guard kv.first explicitly so
        // /v1/models?= no longer DoSes the worker thread.
        for pair in qs.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let kRaw = kv.first else { continue }
            let k = String(kRaw)
            let v = kv.count > 1 ? String(kv[1]) : ""
            guard !k.isEmpty else { continue }   // ignore `=value` (no key)
            dict[k.removingPercentEncoding ?? k] = v.removingPercentEncoding ?? v
        }
        return (path, dict)
    }

    // --- Response writers ---------------------------------------------------------------------

    // Write one complete HTTP/1.1 response and close the connection. JSON payloads emit
    // `application/json; charset=utf-8`. Empty body is allowed (e.g. 204).
    @discardableResult
    static func writeResponse(to fd: Int32,
                              status: Int,
                              reason: String,
                              headers: [String: String] = [:],
                              body: Data = Data(),
                              connectionClose: Bool = true) -> Bool {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var hdrs = headers
        // Required + sensible defaults. CORS headers added separately by the dispatcher.
        if hdrs["Content-Length"] == nil { hdrs["Content-Length"] = String(body.count) }
        if connectionClose { hdrs["Connection"] = "close" }
        for (k, v) in hdrs { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        guard writeAll(fd: fd, data: Data(head.utf8)) else { return false }
        if !body.isEmpty {
            return writeAll(fd: fd, data: body)
        }
        return true
    }

    // Write the SSE headers + opens the event stream. The caller then sends `data:` frames via
    // `sseEvent(to:json:)` until the stream ends, at which point they should `sseEnd(to:)` to
    // emit the OpenAI sentinel `data: [DONE]\n\n`.
    @discardableResult
    static func writeSSEHead(to fd: Int32,
                             extraHeaders: [String: String] = [:]) -> Bool {
        var hdrs: [String: String] = [
            "Content-Type": "text/event-stream; charset=utf-8",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        ]
        for (k, v) in extraHeaders { hdrs[k] = v }
        var head = "HTTP/1.1 200 OK\r\n"
        for (k, v) in hdrs { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return writeAll(fd: fd, data: Data(head.utf8))
    }

    @discardableResult
    static func sseEvent(to fd: Int32, json: Data) -> Bool {
        var frame = Data("data: ".utf8)
        frame.append(json)
        frame.append(contentsOf: [0x0A, 0x0A])   // \n\n
        return writeAll(fd: fd, data: frame)
    }

    @discardableResult
    static func sseDone(to fd: Int32) -> Bool {
        let frame = Data("data: [DONE]\n\n".utf8)
        return writeAll(fd: fd, data: frame)
    }

    // Robust write-all with EINTR/EAGAIN retry. Returns false on a hard error or peer close.
    @discardableResult
    static func writeAll(fd: Int32, data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return send(fd, base, remaining.count, 0)
            }
            if n > 0 { remaining = remaining.dropFirst(n); continue }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // Tiny back-off so a temporarily-full socket buffer recovers without spinning.
                    usleep(1_000)
                    continue
                }
                return false   // EPIPE, ECONNRESET, etc.
            }
            return false   // n == 0 on send means peer gone
        }
        return true
    }
}
