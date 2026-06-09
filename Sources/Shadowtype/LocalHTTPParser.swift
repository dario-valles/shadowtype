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
    case ioFailed(Int32)
}

enum LocalHTTPParser {

    // Read one HTTP/1.1 request from `fd`. Reads up to `maxHeaderBytes` for the head, then up to
    // `maxBodyBytes` for the body (rejects with .bodyTooLarge if Content-Length exceeds it).
    // Returns nil for a clean EOF before any bytes (peer closed without sending).
    static func read(from fd: Int32,
                     maxHeaderBytes: Int = 8 * 1024,
                     maxBodyBytes: Int = 1024 * 1024) throws -> HTTPRequest? {

        // --- Read header bytes until "\r\n\r\n" ---------------------------------------------
        var buf = Data()
        var sawAny = false
        while true {
            if buf.count > maxHeaderBytes { throw LocalHTTPError.headersTooLarge }
            var chunk = [UInt8](repeating: 0, count: 1024)
            let n = recv(fd, &chunk, chunk.count, 0)
            if n == 0 {
                if sawAny { throw LocalHTTPError.clientClosed }
                return nil
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw LocalHTTPError.ioFailed(errno)
            }
            sawAny = true
            buf.append(chunk, count: n)
            if let range = buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {  // \r\n\r\n
                // Split headers from any leading body bytes we read past the boundary.
                let headerData = buf[..<range.lowerBound]
                var bodyHead = buf[range.upperBound...]
                guard let headerStr = String(data: headerData, encoding: .utf8) else {
                    throw LocalHTTPError.malformedRequest
                }
                let (method, path, query, headers) = try parseHead(headerStr)
                // --- Read remaining body ----------------------------------------------------
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                if contentLength < 0 { throw LocalHTTPError.malformedRequest }
                if contentLength > maxBodyBytes { throw LocalHTTPError.bodyTooLarge }
                var body = Data(bodyHead)
                bodyHead.removeAll()
                while body.count < contentLength {
                    var c = [UInt8](repeating: 0, count: min(4096, contentLength - body.count))
                    let m = recv(fd, &c, c.count, 0)
                    if m == 0 { throw LocalHTTPError.clientClosed }
                    if m < 0 {
                        if errno == EINTR { continue }
                        throw LocalHTTPError.ioFailed(errno)
                    }
                    body.append(c, count: m)
                }
                return HTTPRequest(method: method, path: path, query: query,
                                   headers: headers, body: body)
            }
        }
    }

    private static func parseHead(_ s: String) throws
        -> (method: String, path: String, query: [String: String], headers: [String: String]) {
        let lines = s.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { throw LocalHTTPError.malformedRequest }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw LocalHTTPError.malformedRequest }
        let method = String(parts[0])
        let rawTarget = String(parts[1])
        let (path, query) = splitQuery(rawTarget)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        return (method, path, query, headers)
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
