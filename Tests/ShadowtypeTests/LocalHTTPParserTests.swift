// Unit tests for the M1 HTTP/1.1 parser. Uses an in-process pipe(2) pair as the "socket" so the
// parser exercises its real `recv` codepath. No network, no model.
import XCTest
import Darwin
@testable import Shadowtype

final class LocalHTTPParserTests: XCTestCase {

    // Build a socketpair (UDS, stream), send the bytes through the write end, close it, return
    // the read fd. We use socketpair instead of pipe so that send(2)/recv(2) — which the parser
    // uses — succeed. (pipe fds reject recv with ENOTSOCK errno 38.) Test must close the read fd.
    private func pipeWith(_ bytes: String) -> Int32 {
        var fds: [Int32] = [0, 0]
        let rc = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        XCTAssertEqual(rc, 0, "socketpair failed errno=\(errno)")
        let writeEnd = fds[1]
        let data = Array(bytes.utf8)
        _ = data.withUnsafeBufferPointer { buf in
            send(writeEnd, buf.baseAddress, buf.count, 0)
        }
        close(writeEnd)
        return fds[0]
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
        // Sized just over the parser's default 8 KiB cap, but small enough to fit in a single
        // socketpair send buffer (default ~8KiB on macOS but typically grows on first write). The
        // parser checks the accumulated buffer length BEFORE recv'ing the next chunk, so on the
        // second iteration after the initial chunk it trips the cap. We use a much smaller cap
        // by passing maxHeaderBytes explicitly so the test stays under socket buffer limits.
        let head = "GET / HTTP/1.1\r\n" + String(repeating: "X-Junk: pad\r\n", count: 100)
        let fd = pipeWith(head); defer { close(fd) }
        XCTAssertThrowsError(try LocalHTTPParser.read(from: fd, maxHeaderBytes: 256)) { err in
            guard case LocalHTTPError.headersTooLarge = err else {
                XCTFail("expected headersTooLarge, got \(err)")
                return
            }
        }
    }
}
