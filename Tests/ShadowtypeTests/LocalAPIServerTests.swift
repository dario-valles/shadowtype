// LocalAPIServerTests — pure coverage for the Bearer-auth constant-time compare. The TCP transport
// requires a Bearer token; comparing it with `==`/`!=` would short-circuit on the first mismatching
// byte and leak the key prefix-by-prefix via response timing to a local process that can reach
// 127.0.0.1 but can't read the Keychain. These lock the helper's correctness (timing is not asserted
// here — only that the result is right for matches, mismatches, and length differences).
import XCTest
@testable import Shadowtype

final class LocalAPIServerTests: XCTestCase {

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
