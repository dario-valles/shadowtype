// Unit tests for the M1 HTTP/1.1 parser. Uses an in-process pipe(2) pair as the "socket" so the
// parser exercises its real `recv` codepath. No network, no model.
import XCTest
import Darwin
@testable import Shadowtype

final class LocalHTTPParserTests: XCTestCase {

    private func pipeWith(_ bytes: String) -> Int32 {
        pipeWith(Data(bytes.utf8))
    }

    // Build a socketpair (UDS, stream), send all bytes through the write end, close it, and
    // return the read fd. Tests must close the returned descriptor.
    private func pipeWith(_ data: Data) -> Int32 {
        var fds: [Int32] = [0, 0]
        let rc = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        XCTAssertEqual(rc, 0, "socketpair failed errno=\(errno)")
        let writeEnd = fds[1]
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return send(writeEnd, base.advanced(by: offset), data.count - offset, 0)
            }
            XCTAssertGreaterThan(written, 0, "send failed errno=\(errno)")
            guard written > 0 else { break }
            offset += written
        }
        close(writeEnd)
        return fds[0]
    }

    private func assertMalformed(_ request: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        let fd = pipeWith(request)
        defer { close(fd) }
        XCTAssertThrowsError(try LocalHTTPParser.read(from: fd), file: file, line: line) { error in
            guard case LocalHTTPError.malformedRequest = error else {
                XCTFail("expected malformedRequest, got \(error)", file: file, line: line)
                return
            }
        }
    }

    func testParsesGetRequestWithoutBody() throws {
        let req = "GET /v1/health HTTP/1.1\r\nHost: localhost:5666\r\nAccept: */*\r\n\r\n"
        let fd = pipeWith(req); defer { close(fd) }
        let parsed = try LocalHTTPParser.read(from: fd)
        XCTAssertEqual(parsed?.method, "GET")
        XCTAssertEqual(parsed?.path, "/v1/health")
        XCTAssertEqual(parsed?.body.count, 0)
        XCTAssertEqual(parsed?.header("Host"), "localhost:5666")
        XCTAssertEqual(parsed?.header("accept"), "*/*",
                       "header lookup must be case-insensitive — clients send mixed case")
    }

    func testParsesPostWithJSONBody() throws {
        let body = #"{"prompt":"hi","max_tokens":16}"#
        let head = "POST /v1/completions HTTP/1.1\r\n" +
                   "Authorization: Bearer abc123\r\n" +
                   "Content-Type: application/json\r\n" +
                   "Content-Length: \(body.utf8.count)\r\n\r\n"
        let fd = pipeWith(head + body); defer { close(fd) }
        let parsed = try LocalHTTPParser.read(from: fd)
        XCTAssertEqual(parsed?.method, "POST")
        XCTAssertEqual(parsed?.path, "/v1/completions")
        XCTAssertEqual(parsed?.header("Authorization"), "Bearer abc123")
        XCTAssertEqual(parsed?.body.count, body.utf8.count)
        if let bodyData = parsed?.body, let s = String(data: bodyData, encoding: .utf8) {
            XCTAssertEqual(s, body)   // round-trip
        } else { XCTFail("body missing") }
    }

    func testParsesQueryString() throws {
        let req = "GET /v1/models?ids=foo,bar&detail=full HTTP/1.1\r\nHost: x\r\n\r\n"
        let fd = pipeWith(req); defer { close(fd) }
        let parsed = try LocalHTTPParser.read(from: fd)
        XCTAssertEqual(parsed?.path, "/v1/models")
        XCTAssertEqual(parsed?.query["detail"], "full")
        XCTAssertEqual(parsed?.query["ids"], "foo,bar")
    }

    func testReturnsNilOnImmediateEOF() throws {
        // Closing the write end without sending anything: the parser sees recv=0 before any
        // bytes and returns nil (a clean "peer never spoke") rather than throwing.
        var fds: [Int32] = [0, 0]
        _ = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        close(fds[1])
        defer { close(fds[0]) }
        let parsed = try LocalHTTPParser.read(from: fds[0])
        XCTAssertNil(parsed, "EOF before any bytes must be returned as nil, not an error")
    }

    func testHeadersTooLargeThrows() {
        // Include a terminator beyond the limit. The old test omitted it and therefore did not
        // cover the bug where one final recv was accepted even though it crossed the cap.
        let head = "GET / HTTP/1.1\r\nX-Junk: " + String(repeating: "a", count: 300) + "\r\n\r\n"
        let fd = pipeWith(head); defer { close(fd) }
        XCTAssertThrowsError(try LocalHTTPParser.read(from: fd, maxHeaderBytes: 256)) { err in
            guard case LocalHTTPError.headersTooLarge = err else {
                XCTFail("expected headersTooLarge, got \(err)")
                return
            }
        }
    }

    func testHeaderAtExactLimitIsAcceptedAndOneByteOverIsRejected() throws {
        let prefix = "GET / HTTP/1.1\r\nX: "
        let suffix = "\r\n\r\n"
        let limit = 128
        let exact = prefix + String(repeating: "a",
                                   count: limit - prefix.utf8.count - suffix.utf8.count) + suffix
        XCTAssertEqual(exact.utf8.count, limit)

        let exactFD = pipeWith(exact)
        defer { close(exactFD) }
        XCTAssertNotNil(try LocalHTTPParser.read(from: exactFD, maxHeaderBytes: limit))

        let overFD = pipeWith(prefix + String(repeating: "a",
                                             count: limit - prefix.utf8.count - suffix.utf8.count + 1)
                              + suffix)
        defer { close(overFD) }
        XCTAssertThrowsError(try LocalHTTPParser.read(from: overFD, maxHeaderBytes: limit)) { error in
            guard case LocalHTTPError.headersTooLarge = error else {
                XCTFail("expected headersTooLarge, got \(error)")
                return
            }
        }
    }

    func testRejectsInvalidNegativeAndOverflowingContentLength() {
        for value in ["", "abc", "-1", "+1", "1x", "184467440737095516160"] {
            assertMalformed("POST / HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n")
        }
    }

    func testRejectsDuplicateContentLengthEvenWhenValuesMatch() {
        assertMalformed("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\na")
        assertMalformed("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab")
    }

    func testRejectsDuplicateSecuritySensitiveHeaders() {
        for name in ["Host", "Origin", "Authorization"] {
            assertMalformed("GET / HTTP/1.1\r\n\(name): first\r\n\(name): second\r\n\r\n")
        }
    }

    func testRejectsTransferEncodingAndTransferEncodingContentLengthConflict() {
        assertMalformed("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
        assertMalformed("POST / HTTP/1.1\r\nTransfer-Encoding: identity\r\nContent-Length: 0\r\n\r\n")
    }

    func testBodyAtExactLimitIsAccepted() throws {
        let body = "abcd"
        let fd = pipeWith("POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\n\(body)")
        defer { close(fd) }
        let request = try LocalHTTPParser.read(from: fd, maxBodyBytes: 4)
        XCTAssertEqual(request?.body, Data(body.utf8))
    }

    func testDeclaredBodyOverLimitIsRejected() {
        let fd = pipeWith("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nabcde")
        defer { close(fd) }
        XCTAssertThrowsError(try LocalHTTPParser.read(from: fd, maxBodyBytes: 4)) { error in
            guard case LocalHTTPError.bodyTooLarge = error else {
                XCTFail("expected bodyTooLarge, got \(error)")
                return
            }
        }
    }

    func testTruncatedBodyIsRejected() {
        let fd = pipeWith("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nabc")
        defer { close(fd) }
        XCTAssertThrowsError(try LocalHTTPParser.read(from: fd)) { error in
            guard case LocalHTTPError.clientClosed = error else {
                XCTFail("expected clientClosed, got \(error)")
                return
            }
        }
    }

    func testExcessBodyBytesAreRejected() {
        assertMalformed("POST / HTTP/1.1\r\nContent-Length: 3\r\n\r\nabcd")
        assertMalformed("GET / HTTP/1.1\r\n\r\nunexpected")
    }

    func testRejectsMalformedRequestLines() {
        for requestLine in [
            "GET",
            "GET /",
            "GET / HTTP/1.1 extra",
            "GET  HTTP/1.1",
            "GET\t/ HTTP/1.1",
            "G(ET / HTTP/1.1",
            "GET / HTTP/1.0",
        ] {
            assertMalformed("\(requestLine)\r\nHost: localhost\r\n\r\n")
        }
    }

    func testRejectsMalformedHeadersAndObsFold() {
        for header in [
            "Missing-Colon",
            ": value",
            "Bad Name: value",
            "Host : localhost",
            "Bad(Name: value",
            " continuation",
            "\tcontinuation",
        ] {
            assertMalformed("GET / HTTP/1.1\r\n\(header)\r\n\r\n")
        }
    }

    func testRejectsAllHeaderControlCharacters() {
        for byte in UInt8(0)...UInt8(31) {
            var data = Data("GET / HTTP/1.1\r\nX-Test: before".utf8)
            data.append(byte)
            data.append(Data("after\r\n\r\n".utf8))
            let fd = pipeWith(data)
            XCTAssertThrowsError(try LocalHTTPParser.read(from: fd),
                                 "control byte \(byte) must be rejected") { error in
                guard case LocalHTTPError.malformedRequest = error else {
                    XCTFail("expected malformedRequest for byte \(byte), got \(error)")
                    return
                }
            }
            close(fd)
        }

        var delete = Data("GET / HTTP/1.1\r\nX-Test: before".utf8)
        delete.append(127)
        delete.append(Data("after\r\n\r\n".utf8))
        let fd = pipeWith(delete)
        defer { close(fd) }
        XCTAssertThrowsError(try LocalHTTPParser.read(from: fd))
    }

    func testAbsoluteHeaderAndBodyDeadlinesExpire() {
        var headerFDs: [Int32] = [0, 0]
        XCTAssertEqual(headerFDs.withUnsafeMutableBufferPointer {
            socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress)
        }, 0)
        defer {
            close(headerFDs[0])
            close(headerFDs[1])
        }
        XCTAssertThrowsError(try LocalHTTPParser.read(
            from: headerFDs[0],
            headerDeadline: DispatchTime.now() + .milliseconds(20)
        )) { error in
            guard case LocalHTTPError.deadlineExceeded = error else {
                XCTFail("expected deadlineExceeded, got \(error)")
                return
            }
        }

        var bodyFDs: [Int32] = [0, 0]
        XCTAssertEqual(bodyFDs.withUnsafeMutableBufferPointer {
            socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress)
        }, 0)
        defer {
            close(bodyFDs[0])
            close(bodyFDs[1])
        }
        let partial = Data("POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\na".utf8)
        _ = partial.withUnsafeBytes {
            send(bodyFDs[1], $0.baseAddress, partial.count, 0)
        }
        XCTAssertThrowsError(try LocalHTTPParser.read(
            from: bodyFDs[0],
            bodyDeadline: DispatchTime.now() + .milliseconds(20)
        )) { error in
            guard case LocalHTTPError.deadlineExceeded = error else {
                XCTFail("expected deadlineExceeded, got \(error)")
                return
            }
        }
    }

    func testFuzzStyleRandomAndTruncatedInputsNeverCrash() {
        var state: UInt64 = 0x6a09e667f3bcc909
        func nextByte() -> UInt8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }

        for _ in 0..<500 {
            let length = Int(nextByte())
            let data = Data((0..<length).map { _ in nextByte() })
            let fd = pipeWith(data)
            _ = try? LocalHTTPParser.read(from: fd, maxHeaderBytes: 128, maxBodyBytes: 128)
            close(fd)
        }

        let valid = Data("POST /v1/completions HTTP/1.1\r\nContent-Length: 4\r\n\r\ntest".utf8)
        for length in 0..<valid.count {
            let fd = pipeWith(valid.prefix(length))
            _ = try? LocalHTTPParser.read(from: fd, maxHeaderBytes: 128, maxBodyBytes: 128)
            close(fd)
        }
    }
}
