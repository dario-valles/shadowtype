// EditContextTracker.host(fromDocumentURL:) — pure host extraction for FR-PA-2 per-domain rules.
// The AXDocument attribute yields a FULL url; AppRules stores bare hosts, so the gate only matches
// once the URL is reduced to its host. These cases pin that reduction.
import XCTest
@testable import Shadowtype

final class DomainHostTests: XCTestCase {
    func testFullHttpsURLReducesToHost() {
        XCTAssertEqual(
            EditContextTracker.host(fromDocumentURL: "https://docs.google.com/document/d/abc123/edit"),
            "docs.google.com")
    }

    func testHostIsLowercased() {
        XCTAssertEqual(
            EditContextTracker.host(fromDocumentURL: "https://Docs.Google.COM/document"),
            "docs.google.com")
    }

    func testPortIsStripped() {
        XCTAssertEqual(
            EditContextTracker.host(fromDocumentURL: "http://localhost:3000/app"),
            "localhost")
    }

    func testBareHostPassesThrough() {
        XCTAssertEqual(EditContextTracker.host(fromDocumentURL: "mail.google.com"), "mail.google.com")
    }

    func testFileURLHasNoWebHost() {
        XCTAssertNil(EditContextTracker.host(fromDocumentURL: "file:///Users/x/notes.txt"))
    }

    func testEmptyAndJunkReturnNil() {
        XCTAssertNil(EditContextTracker.host(fromDocumentURL: ""))
        XCTAssertNil(EditContextTracker.host(fromDocumentURL: "   "))
        // A bare path with no host is not a domain.
        XCTAssertNil(EditContextTracker.host(fromDocumentURL: "/some/local/path"))
    }
}
