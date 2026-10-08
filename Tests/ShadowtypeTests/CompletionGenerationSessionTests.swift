// CompletionGenerationSession: the per-generation state that survives a rejected render.
//
// `rejectRender` hides the ghost through `clearSuggestion()`, which drops the generation's focus latch together with its caret,
// font and language state. When the FIRST streamed piece is only punctuation or a space (a low-value render), that used to make
// every later render of the same generation fail the focus guard ("render: stale focus -> discard") although focus never changed.
// The coordinator now captures `hoisted` before the hide and puts it back after; these tests pin that contract on the session.
import XCTest
import AppKit
import NaturalLanguage
@testable import Shadowtype

final class CompletionGenerationSessionTests: XCTestCase {
    private func populated() -> CompletionGenerationSession {
        let s = CompletionGenerationSession()
        s.focusSeq = 7
        s.caretRect = CGRect(x: 10, y: 20, width: 0, height: 14)
        s.font = NSFont.systemFont(ofSize: 13)
        s.prefixLanguage = .english
        s.languageConstraints = [.english, .german]
        return s
    }

    /// What `clearSuggestion()` does to the hoisted values.
    private func clearLikeTheCoordinator(_ s: CompletionGenerationSession) {
        s.caretRect = nil
        s.font = nil
        s.prefixLanguage = nil
        s.languageConstraints = []
        s.focusSeq = nil
    }

    func testHoistedStateRoundTripsThroughAClear() {
        let s = populated()
        let kept = s.hoisted
        clearLikeTheCoordinator(s)
        XCTAssertNil(s.focusSeq, "precondition: the clear really drops the focus latch")

        s.hoisted = kept
        XCTAssertEqual(s.focusSeq, 7)
        XCTAssertEqual(s.caretRect, CGRect(x: 10, y: 20, width: 0, height: 14))
        XCTAssertEqual(s.font, NSFont.systemFont(ofSize: 13))
        XCTAssertEqual(s.prefixLanguage, .english)
        XCTAssertEqual(s.languageConstraints, [.english, .german])
    }

    func testRestoringAnEmptyStateLeavesNothingBehind() {
        let s = CompletionGenerationSession()
        let kept = s.hoisted
        s.focusSeq = 3
        s.hoisted = kept
        XCTAssertNil(s.focusSeq)
        XCTAssertNil(s.caretRect)
        XCTAssertNil(s.font)
        XCTAssertNil(s.prefixLanguage)
        XCTAssertEqual(s.languageConstraints, [])
    }

    func testHoistedStateDoesNotTouchTheRestOfTheSession() {
        let s = populated()
        s.committed = true
        s.activePrefix = "hello"
        let kept = s.hoisted
        clearLikeTheCoordinator(s)
        s.hoisted = kept
        XCTAssertTrue(s.committed)
        XCTAssertEqual(s.activePrefix, "hello")
    }
}
