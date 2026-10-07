// ElectronAccessibility — per-pid "force once" bookkeeping. The AX side effect is live-only, but the
// idempotence (one attempt per pid, re-armed by reset) is the contract the focus path relies on to
// stay cheap, and that is pure + testable.
import XCTest
import ApplicationServices
@testable import Shadowtype

final class ElectronAccessibilityTests: XCTestCase {
    func testForcesOncePerPid() {
        let ea = ElectronAccessibility()
        XCTAssertTrue(ea.forceIfNeeded(pid: 4242))   // first attempt
        XCTAssertFalse(ea.forceIfNeeded(pid: 4242))  // already attempted
        XCTAssertFalse(ea.forceIfNeeded(pid: 4242))
    }

    func testDistinctPidsEachForcedOnce() {
        let ea = ElectronAccessibility()
        XCTAssertTrue(ea.forceIfNeeded(pid: 1))
        XCTAssertTrue(ea.forceIfNeeded(pid: 2))
        XCTAssertFalse(ea.forceIfNeeded(pid: 1))
    }

    func testInvalidPidIsNotForced() {
        let ea = ElectronAccessibility()
        XCTAssertFalse(ea.forceIfNeeded(pid: 0))
        XCTAssertFalse(ea.forceIfNeeded(pid: -1))
    }
}

// The AXManualAccessibility verdict (issue #8). Stock-Electron hosts (Slack, VS Code, Discord,
// Obsidian, Linear) implement the private attribute; Chrome-style Chromium builds — Google Chrome,
// and the OpenAI Codex/ChatGPT desktop app with its rebranded `Codex Framework` — do not, so the
// write is silently swallowed and their AX tree is never materialized. Recording the result is what
// lets a prefix-miss log tell those two cases apart.
final class ElectronAccessibilitySupportTests: XCTestCase {
    /// An `ElectronAccessibility` whose AX write is stubbed, plus the pids it was asked to write to.
    private func makeStub(
        _ result: @escaping (pid_t) -> AXError
    ) -> (ElectronAccessibility, () -> [pid_t]) {
        var writes: [pid_t] = []
        let ea = ElectronAccessibility(write: { pid in
            writes.append(pid)
            return result(pid)
        })
        return (ea, { writes })
    }

    // MARK: - classify (pure)

    func testSuccessMeansHostImplementsTheAttribute() {
        XCTAssertEqual(ElectronAccessibility.classify(.success), .supported)
    }

    func testAttributeUnsupportedIsTheDefiniteRefusal() {
        XCTAssertEqual(
            ElectronAccessibility.classify(.attributeUnsupported), .unsupported)
    }

    func testTransientErrorsNeverClaimAVerdict() {
        // A launching app, a stale element or AX being off says nothing about the host — claiming
        // `.unsupported` here would libel an app that works fine a moment later.
        for error: AXError in [.cannotComplete, .invalidUIElement, .apiDisabled,
                               .notImplemented, .failure, .illegalArgument] {
            XCTAssertEqual(ElectronAccessibility.classify(error), .unknown,
                           "\(error) must not be read as a verdict about the host")
        }
    }

    // MARK: - recording

    func testStockElectronHostIsRecordedAsSupported() {
        let (ea, writes) = makeStub { _ in .success }
        XCTAssertTrue(ea.forceIfNeeded(pid: 501))

        XCTAssertEqual(ea.support(pid: 501), .supported)
        XCTAssertEqual(writes(), [501])
    }

    func testChromeStyleHostIsRecordedAsUnsupported() {
        // The issue-#8 shape: the write is accepted by the AX layer but the app implements no
        // handler, so its AX tree is never built and every later text read returns nil.
        let (ea, _) = makeStub { _ in .attributeUnsupported }
        XCTAssertTrue(ea.forceIfNeeded(pid: 909))

        XCTAssertEqual(ea.support(pid: 909), .unsupported)
        XCTAssertEqual(ea.support(pid: 909).diagLabel, "unsupported")
    }

    func testNeverAttemptedPidIsUnknown() {
        let (ea, writes) = makeStub { _ in .success }
        XCTAssertEqual(ea.support(pid: 777), .unknown)
        XCTAssertEqual(writes(), [], "asking for a verdict must not trigger an AX write")
    }

    func testInvalidPidIsNeverWrittenToAndStaysUnknown() {
        let (ea, writes) = makeStub { _ in .success }
        XCTAssertEqual(ea.apply(pid: 0), .unknown)
        XCTAssertEqual(ea.apply(pid: -3), .unknown)
        XCTAssertEqual(writes(), [])
    }

    func testDefiniteVerdictSurvivesALaterTransientFailure() {
        // The browser re-prime path calls apply() repeatedly; one `cannotComplete` while the app is
        // busy must not erase the fact that it answered the attribute earlier.
        var next: AXError = .success
        let (ea, _) = makeStub { _ in next }
        XCTAssertEqual(ea.apply(pid: 42), .supported)

        next = .cannotComplete
        XCTAssertEqual(ea.apply(pid: 42), .supported)
        XCTAssertEqual(ea.support(pid: 42), .supported)
    }

    func testTransientVerdictIsUpgradedOnceTheHostAnswers() {
        // Mirror image: an app probed mid-launch records `.unknown`, and the next probe must be able
        // to settle it either way rather than staying stuck.
        var next: AXError = .cannotComplete
        let (ea, _) = makeStub { _ in next }
        XCTAssertEqual(ea.apply(pid: 7), .unknown)

        next = .attributeUnsupported
        XCTAssertEqual(ea.apply(pid: 7), .unsupported)
        XCTAssertEqual(ea.support(pid: 7), .unsupported)
    }

    func testVerdictsAreKeyedPerPid() {
        let (ea, _) = makeStub { pid in pid == 1 ? .success : .attributeUnsupported }
        ea.forceIfNeeded(pid: 1)
        ea.forceIfNeeded(pid: 2)

        XCTAssertEqual(ea.support(pid: 1), .supported)
        XCTAssertEqual(ea.support(pid: 2), .unsupported)
    }

    func testForceIfNeededStillWritesExactlyOncePerPid() {
        // The verdict bookkeeping must not disturb the per-pid write budget the focus path relies on.
        let (ea, writes) = makeStub { _ in .success }
        ea.forceIfNeeded(pid: 55)
        ea.forceIfNeeded(pid: 55)
        ea.forceIfNeeded(pid: 55)

        XCTAssertEqual(writes(), [55])
    }

    // MARK: - AXEnhancedUserInterface fallback (Claude desktop app, Codex app: issue #8)

    /// Like `makeStub`, with the fallback's three collaborators injected: the AXEnhancedUserInterface writer,
    /// the user's opt-in, and the "is this a non-browser Chromium host" test. Records every enhanced write.
    private struct FallbackStub {
        let ea: ElectronAccessibility
        let manualWrites: () -> [pid_t]
        let enhancedWrites: () -> [(pid: pid_t, on: Bool)]
    }

    private func makeFallbackStub(
        manual: @escaping (pid_t) -> AXError = { _ in .attributeUnsupported },
        enhanced: @escaping (pid_t, Bool) -> AXError = { _, _ in .success },
        enabled: @escaping () -> Bool = { true },
        chromium: @escaping (pid_t) -> Bool = { _ in true }
    ) -> FallbackStub {
        var manualWrites: [pid_t] = []
        var enhancedWrites: [(pid: pid_t, on: Bool)] = []
        let ea = ElectronAccessibility(
            write: { pid in manualWrites.append(pid); return manual(pid) },
            enhancedWrite: { pid, on in enhancedWrites.append((pid, on)); return enhanced(pid, on) },
            enhancedEnabled: enabled,
            isChromiumHost: chromium)
        return FallbackStub(ea: ea, manualWrites: { manualWrites }, enhancedWrites: { enhancedWrites })
    }

    func testFallbackIsTakenOnlyWhenManualIsUnsupportedAndTheHostIsChromium() {
        let s = makeFallbackStub()
        XCTAssertEqual(s.ea.apply(pid: 10), .enhancedFallback)
        XCTAssertEqual(s.enhancedWrites().count, 1)
        XCTAssertEqual(s.enhancedWrites().first?.pid, 10)
        XCTAssertEqual(s.enhancedWrites().first?.on, true)
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10))
    }

    func testFallbackIsNeverTakenForANativeAppOrABrowser() {
        // `isChromiumHost` is false for native Cocoa apps and for browsers (liveIsChromiumHost excludes them).
        let s = makeFallbackStub(chromium: { _ in false })
        XCTAssertEqual(s.ea.apply(pid: 10), .unsupported)
        XCTAssertTrue(s.enhancedWrites().isEmpty)
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
    }

    func testFallbackIsNeverTakenWhenManualAccessibilityIsSupported() {
        let s = makeFallbackStub(manual: { _ in .success })
        XCTAssertEqual(s.ea.apply(pid: 10), .supported)
        XCTAssertTrue(s.enhancedWrites().isEmpty)
    }

    func testFallbackIsNeverTakenUnlessTheUserOptedIn() {
        let s = makeFallbackStub(enabled: { false })
        XCTAssertEqual(s.ea.apply(pid: 10), .unsupported)
        XCTAssertTrue(s.enhancedWrites().isEmpty)
    }

    func testAHostThatRefusesTheFallbackStaysUnsupported() {
        let s = makeFallbackStub(enhanced: { _, _ in .attributeUnsupported })
        XCTAssertEqual(s.ea.apply(pid: 10), .unsupported)
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
    }

    func testEnhancedFallbackVerdictIsStickyAgainstALaterUnsupported() {
        let s = makeFallbackStub()
        XCTAssertEqual(s.ea.apply(pid: 10), .enhancedFallback)
        // Manual is still unsupported on the next apply(); the verdict must not slide back to .unsupported.
        XCTAssertEqual(s.ea.apply(pid: 10), .enhancedFallback)
        XCTAssertEqual(s.ea.support(pid: 10), .enhancedFallback)
        XCTAssertEqual(s.enhancedWrites().count, 1, "the flag is already on: no second write")
    }

    func testFlagIsSwitchedOffWhenTheAppDeactivatesAndBackOnWhenItReactivates() {
        let s = makeFallbackStub()
        s.ea.applicationDidActivate(pid: 10)                        // first activation: normal attempt + fallback
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10))

        s.ea.applicationDidDeactivate(pid: 10)
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
        XCTAssertEqual(s.enhancedWrites().last?.on, false)

        s.ea.applicationDidActivate(pid: 10)                        // back in front: the host rebuilds its tree
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10))
        XCTAssertEqual(s.enhancedWrites().last?.on, true)
    }

    func testDeactivatingAnAppWeNeverTouchedWritesNothing() {
        let s = makeFallbackStub(chromium: { _ in false })
        s.ea.applicationDidActivate(pid: 10)
        s.ea.applicationDidDeactivate(pid: 10)
        XCTAssertTrue(s.enhancedWrites().isEmpty)
    }

    func testRevertAllSwitchesEveryAppOffOnQuit() {
        let s = makeFallbackStub()
        s.ea.applicationDidActivate(pid: 10)
        s.ea.applicationDidActivate(pid: 11)
        s.ea.revertAll()
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 11))
        XCTAssertEqual(s.enhancedWrites().filter { !$0.on }.map { $0.pid }.sorted(), [10, 11])
    }

    func testReactivationDoesNothingIfTheUserTurnedTheOptInOff() {
        var enabled = true
        let s = makeFallbackStub(enabled: { enabled })
        s.ea.applicationDidActivate(pid: 10)
        s.ea.applicationDidDeactivate(pid: 10)
        enabled = false
        s.ea.applicationDidActivate(pid: 10)
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
        XCTAssertEqual(s.enhancedWrites().count, 2, "on, then off; nothing after the opt-out")
    }
}
