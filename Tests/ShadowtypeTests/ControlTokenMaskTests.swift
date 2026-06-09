import XCTest
@testable import Shadowtype

// Tier 2b: locks the special-token masking policy so a future change can't start masking the EOG
// stop (which would hang generation) or break FIM, and can't stop masking the chat-marker leaks.
final class ControlTokenMaskTests: XCTestCase {

    func testMasksSpecialNonStopNonFIM() {
        // A chat-marker / control / user-defined token that is neither a stop nor FIM framing → mask.
        XCTAssertTrue(InferenceEngine.shouldMaskSpecial(isSpecial: true, isEOG: false, isFIM: false))
    }

    func testNeverMasksEOG() {
        // The decode loop must be able to SAMPLE an EOG token to end cleanly — masking it would hang.
        XCTAssertFalse(InferenceEngine.shouldMaskSpecial(isSpecial: true, isEOG: true, isFIM: false))
    }

    func testNeverMasksFIMFraming() {
        // FIM tokens are injected into the prompt, never re-emitted; masking them would break FIM.
        XCTAssertFalse(InferenceEngine.shouldMaskSpecial(isSpecial: true, isEOG: false, isFIM: true))
    }

    func testNeverMasksNormalTokens() {
        // A normal vocab token (e.g. the word "assistant") must stay samplable — it's real text.
        XCTAssertFalse(InferenceEngine.shouldMaskSpecial(isSpecial: false, isEOG: false, isFIM: false))
    }

    func testEOGWinsOverSpecialEvenIfAlsoFIM() {
        // Belt-and-suspenders: any stop is exempt regardless of the other flags.
        XCTAssertFalse(InferenceEngine.shouldMaskSpecial(isSpecial: true, isEOG: true, isFIM: true))
    }
}
