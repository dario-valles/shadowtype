// ClipboardContextProvider — FR-CTX-2 clipboard-aware context (Paid tier).
// Hermetic: a unique-named NSPasteboard is the injected seam, so tests never read or mutate the real
// system clipboard (.general). Each test owns a fresh named pasteboard cleared up front.
import AppKit
import XCTest
@testable import Shadowtype

final class ClipboardContextTests: XCTestCase {
    // A fresh, isolated pasteboard per call — unique name avoids collisions with .general or each other.
    private func tempPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("gw-clip-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    // MARK: - Reads the current pasteboard string

    func testReturnsCurrentString() {
        let pb = tempPasteboard()
        pb.clearContents()
        pb.setString("hello world", forType: .string)

        let provider = ClipboardContextProvider(pasteboard: pb)
        XCTAssertEqual(provider.recentText(maxChars: 100), "hello world")
    }

    // MARK: - Trimming

    func testTrimsSurroundingWhitespace() {
        let pb = tempPasteboard()
        pb.clearContents()
        pb.setString("  \n padded \n  ", forType: .string)

        let provider = ClipboardContextProvider(pasteboard: pb)
        XCTAssertEqual(provider.recentText(maxChars: 100), "padded")
    }

    // MARK: - Capping to maxChars (keeps the tail)

    func testCapsToMaxCharsKeepingTail() {
        let pb = tempPasteboard()
        pb.clearContents()
        pb.setString("abcdefghij", forType: .string)

        let provider = ClipboardContextProvider(pasteboard: pb)
        XCTAssertEqual(provider.recentText(maxChars: 4), "ghij")
    }

    func testZeroMaxCharsReturnsNil() {
        let pb = tempPasteboard()
        pb.clearContents()
        pb.setString("anything", forType: .string)

        let provider = ClipboardContextProvider(pasteboard: pb)
        XCTAssertNil(provider.recentText(maxChars: 0))
    }

    // MARK: - Empty / unavailable -> nil

    func testEmptyPasteboardReturnsNil() {
        let pb = tempPasteboard() // cleared, no string written
        let provider = ClipboardContextProvider(pasteboard: pb)
        XCTAssertNil(provider.recentText(maxChars: 100))
    }

    func testWhitespaceOnlyPasteboardReturnsNil() {
        let pb = tempPasteboard()
        pb.clearContents()
        pb.setString("   \n\t  ", forType: .string)

        let provider = ClipboardContextProvider(pasteboard: pb)
        XCTAssertNil(provider.recentText(maxChars: 100))
    }

    // MARK: - changeCount tracking

    func testHasChangedDetectsNewValue() {
        let pb = tempPasteboard()
        pb.clearContents()
        pb.setString("first", forType: .string)

        let provider = ClipboardContextProvider(pasteboard: pb)
        // Sampling syncs our tracked changeCount to the current pasteboard state.
        _ = provider.recentText(maxChars: 100)
        XCTAssertFalse(provider.hasChanged)

        // A new write bumps the system changeCount -> hasChanged flips true until next sample.
        pb.clearContents()
        pb.setString("second", forType: .string)
        XCTAssertTrue(provider.hasChanged)

        // Re-sampling re-syncs and returns the fresh value.
        XCTAssertEqual(provider.recentText(maxChars: 100), "second")
        XCTAssertFalse(provider.hasChanged)
    }
}
