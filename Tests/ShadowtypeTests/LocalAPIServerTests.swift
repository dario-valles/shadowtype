// LocalAPIServerTests — coverage for the all-ports-busy failure surface and the Bearer-auth
// constant-time compare. The TCP transport
// requires a Bearer token; comparing it with `==`/`!=` would short-circuit on the first mismatching
// byte and leak the key prefix-by-prefix via response timing to a local process that can reach
// 127.0.0.1 but can't read the Keychain. These lock the helper's correctness (timing is not asserted
// here — only that the result is right for matches, mismatches, and length differences).
import XCTest
@testable import Shadowtype

final class LocalAPIServerTests: XCTestCase {

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
        let server = LocalAPIServer()
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
}
