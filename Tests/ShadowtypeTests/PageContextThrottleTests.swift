import XCTest
import ApplicationServices
@testable import Shadowtype

final class PageContextThrottleTests: XCTestCase {
    func testRepeatedPageWalkIsThrottledForSameFocusAndWebArea() {
        let cache = AXTextProbe.PageTextCache<String>(
            queue: DispatchQueue(label: "page-cache-test"),
            ttl: 60)
        let loaded = expectation(description: "page walk completed")
        var loadCount = 0

        XCTAssertNil(cache.request(
            key: "focus:web-area",
            load: { _ in
                loadCount += 1
                return "visible page"
            },
            completion: { _ in loaded.fulfill() }))
        XCTAssertNil(cache.request(
            key: "focus:web-area",
            load: { _ in
                loadCount += 1
                return "should not run"
            }))

        wait(for: [loaded], timeout: 1)
        XCTAssertEqual(cache.request(
            key: "focus:web-area",
            load: { _ in
                loadCount += 1
                return "should remain cached"
            }), "visible page")
        XCTAssertEqual(loadCount, 1)
    }

    func testPageWalkCapturesFramedVisibleNodeButNotOffscreenNode() {
        let root = AXUIElementCreateApplication(100)
        let visible = AXUIElementCreateApplication(101)
        let offscreen = AXUIElementCreateApplication(102)
        let children = [visible, offscreen] as CFArray
        var visibleFrame = CGRect(x: 10, y: 10, width: 200, height: 30)
        var offscreenFrame = CGRect(x: 5_000, y: 5_000, width: 200, height: 30)
        let visibleFrameValue = AXValueCreate(.cgRect, &visibleFrame)!
        let offscreenFrameValue = AXValueCreate(.cgRect, &offscreenFrame)!

        let access = AXTextProbe.Access(
            value: { element, attribute in
                if CFEqual(element, root), attribute == (kAXChildrenAttribute as String) {
                    return .init(error: .success, value: children)
                }
                if attribute == "AXFrame" {
                    if CFEqual(element, visible) {
                        return .init(error: .success, value: visibleFrameValue)
                    }
                    if CFEqual(element, offscreen) {
                        return .init(error: .success, value: offscreenFrameValue)
                    }
                }
                if attribute == (kAXValueAttribute as String) {
                    if CFEqual(element, visible) {
                        return .init(error: .success, value: "on screen" as CFString)
                    }
                    if CFEqual(element, offscreen) {
                        return .init(error: .success, value: "off screen private" as CFString)
                    }
                }
                return .init(error: .attributeUnsupported, value: nil)
            },
            parameterized: { _, _, _ in
                .init(error: .attributeUnsupported, value: nil)
            })

        let text = AXTextProbe.gatherVisibleText(
            root,
            maxChars: 1_000,
            displayBounds: [CGRect(x: 0, y: 0, width: 1_000, height: 1_000)],
            access: access,
            isCancelled: { false })

        XCTAssertEqual(text, "on screen")
    }
}
