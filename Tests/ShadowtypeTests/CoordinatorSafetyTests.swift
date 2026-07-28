import XCTest
import ApplicationServices
@testable import Shadowtype

final class CoordinatorSafetyTests: XCTestCase {
    private final class FocusState {
        let first = AXUIElementCreateApplication(101)
        let second = AXUIElementCreateApplication(202)
        var current: AXUIElement?

        init() {
            current = first
        }
    }

    private final class FakeEngine: InferenceEngineProtocol {
        private let lock = NSLock()
        private var cancelCount = 0
        private var callCount = 0

        var isLoaded = true
        var stopAtFirstSentence = false
        var maxWords = 24
        var stopAtSentenceAfterWords = 0
        var maxContextTokens = 1_024
        var modelChatTemplate: String?
        var modelArchitecture: String?
        var modelSupportsChat = false
        var supportsFIM = false
        var generateBody: (((String) -> Bool) -> Void)?

        var requestCancelCount: Int {
            lock.lock(); defer { lock.unlock() }
            return cancelCount
        }

        var generateCallCount: Int {
            lock.lock(); defer { lock.unlock() }
            return callCount
        }

        func load(modelPath: String) throws {
            isLoaded = true
        }

        func unload() {
            isLoaded = false
        }

        func requestCancel() {
            lock.lock(); cancelCount += 1; lock.unlock()
        }

        func releaseSeq(_ seqID: Int32) {}

        func generate(prompt: String, maxTokens: Int, seqID: Int32, params: SamplingParams,
                      requiredPrefix: [UInt8]?, onToken: (String) -> Bool,
                      onSample: ((Float, Bool) -> Void)?) throws {
            lock.lock(); callCount += 1; lock.unlock()
            if let generateBody {
                generateBody(onToken)
            } else {
                _ = onToken(" world")
            }
        }
    }

    @MainActor
    private func makeCoordinator(
        engine: FakeEngine,
        focus: FocusState
    ) -> CompletionCoordinator {
        let tracker = EditContextTracker(
            focusReader: { _ in (.success, focus.current) },
            frontmostPID: { 42 },
            elementPID: { _ in 42 })
        _ = tracker.focusedElement()
        let coordinator = CompletionCoordinator(
            engine: engine,
            overlay: OverlayRenderer(),
            context: tracker)
        return coordinator
    }

    @MainActor
    func testSameAppFocusChangeCancelsAndRejectsLateRenderAndInjection() async {
        let focus = FocusState()
        let engine = FakeEngine()
        let entered = expectation(description: "generation entered")
        let release = DispatchSemaphore(value: 0)
        engine.generateBody = { onToken in
            entered.fulfill()
            release.wait()
            _ = onToken(" world")
        }
        let coordinator = makeCoordinator(engine: engine, focus: focus)
        var injected: [String] = []
        coordinator.injector = Injector(unicodeTyper: {
            injected.append($0)
            return true
        })
        var rendered = false
        coordinator.onSuggestionVisibleChanged = { if $0 { rendered = true } }

        coordinator.startGeneration(prefix: "Hello")
        await fulfillment(of: [entered], timeout: 2)

        focus.current = focus.second
        coordinator.focusDidChange()
        release.signal()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertGreaterThan(engine.requestCancelCount, 0)
        XCTAssertFalse(rendered)
        XCTAssertEqual(coordinator.acceptWord(), 0)
        XCTAssertTrue(injected.isEmpty)
    }

    @MainActor
    func testVisibleSuggestionForAIsNotInjectedAfterStrictReadFindsB() async {
        let focus = FocusState()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, focus: focus)
        var injected: [String] = []
        coordinator.injector = Injector(unicodeTyper: {
            injected.append($0)
            return true
        })
        let shown = expectation(description: "suggestion shown")
        coordinator.onSuggestionVisibleChanged = { visible in
            if visible { shown.fulfill() }
        }

        coordinator.startGeneration(prefix: "Hello")
        await fulfillment(of: [shown], timeout: 2)
        focus.current = focus.second

        XCTAssertEqual(coordinator.acceptWord(), 0)
        XCTAssertTrue(injected.isEmpty)
        XCTAssertGreaterThan(engine.requestCancelCount, 0)
    }

    @MainActor
    func testDeadlineCancelsEngineAndQueuedStaleWorkNeverPrefills() async {
        let focus = FocusState()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, focus: focus)
        let blockerStarted = expectation(description: "queue blocker started")
        let release = DispatchSemaphore(value: 0)
        coordinator.inferenceQueue.async {
            blockerStarted.fulfill()
            release.wait()
        }
        await fulfillment(of: [blockerStarted], timeout: 2)

        coordinator.startGeneration(prefix: "Hello")
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(engine.requestCancelCount, 0)

        release.signal()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(engine.generateCallCount, 0)
    }

    func testHeldRefirePreservesPriorGhostForEmptyOutput() {
        XCTAssertTrue(CompletionCoordinator.shouldPreserveHeldSuggestion(
            isRefire: true, visible: true, text: "prior ghost"))
        XCTAssertEqual(
            OverlayRefireDecision.decide(visible: "prior ghost", snapshot: ""),
            .hold)
    }

    func testLeadingNewlineAndLongLineStoreExactlyWhatIsDisplayedAndAccepted() {
        XCTAssertEqual(
            CompletionCoordinator.normalizedPresentationPayload("\nhello"),
            "hello")

        let long = String(repeating: "x", count: 90)
        let payload = CompletionCoordinator.normalizedPresentationPayload(long)
        XCTAssertEqual(payload, OverlayRenderer.normalizedPayload(long))
        XCTAssertEqual(payload.count, OverlayRenderer.maxRenderedPayloadCharacters)
    }

    func testPresentationFingerprintLetsSameTextGeometryChangeDraw() {
        let first = CompletionCoordinator.presentationFingerprint(
            text: "same", caret: CGRect(x: 10, y: 20, width: 0, height: 18),
            font: nil, opacity: 1, rtl: false, showHint: false)
        let moved = CompletionCoordinator.presentationFingerprint(
            text: "same", caret: CGRect(x: 40, y: 20, width: 0, height: 18),
            font: nil, opacity: 1, rtl: false, showHint: false)
        let state = OverlayEmitDedup.State(text: first, focusSeq: 7, emittedAt: 100)

        XCTAssertNotEqual(first, moved)
        XCTAssertFalse(OverlayEmitDedup.shouldDrop(
            last: state, text: moved, focusSeq: 7, now: 100.1, presented: true))
    }

    func testDelayedCaptureForFocusACannotLandInFocusB() {
        XCTAssertFalse(CompletionCoordinator.captureLatchMatches(
            capturedGeneration: 3,
            currentGeneration: 3,
            capturedFocusSeq: 10,
            currentFocusSeq: 11,
            capturedBundleId: "com.example.Editor",
            currentBundleId: "com.example.Editor"))
        XCTAssertFalse(CompletionCoordinator.captureLatchMatches(
            capturedGeneration: 3,
            currentGeneration: 4,
            capturedFocusSeq: 10,
            currentFocusSeq: 10,
            capturedBundleId: "com.example.Editor",
            currentBundleId: "com.example.Editor"))
    }
}
