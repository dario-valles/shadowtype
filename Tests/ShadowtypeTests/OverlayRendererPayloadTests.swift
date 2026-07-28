import XCTest
@testable import Shadowtype

final class OverlayRendererPayloadTests: XCTestCase {
    func testPayloadAtCapRemainsUnchangedForDisplayAndAcceptance() {
        let text = String(repeating: "a", count: OverlayRenderer.maxRenderedPayloadCharacters)

        let payload = OverlayRenderer.normalizedPayload(text)

        XCTAssertEqual(payload, text)
    }

    func testPayloadOverCapIsTheExactSharedDisplayAndAcceptanceValue() {
        let text = String(repeating: "a", count: OverlayRenderer.maxRenderedPayloadCharacters + 1)

        let payload = OverlayRenderer.normalizedPayload(text)

        XCTAssertEqual(payload, String(text.prefix(OverlayRenderer.maxRenderedPayloadCharacters)))
        XCTAssertEqual(payload.count, OverlayRenderer.maxRenderedPayloadCharacters)
    }
}
