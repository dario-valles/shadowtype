// Onboarding resume — the pure step-persistence logic behind "close mid-flow, resume where you
// left off" (OnboardingWindowController.stepKey). The flow has 8 steps (welcome=0 … done=7).
import XCTest
@testable import Shadowtype

final class OnboardingResumeTests: XCTestCase {
    private let stepCount = 8   // OBStep.allCases.count (welcome … done)

    func testClampedResumeStepPassesValidValuesThrough() {
        XCTAssertEqual(OnboardingWindowController.clampedResumeStep(0, stepCount: stepCount), 0)
        XCTAssertEqual(OnboardingWindowController.clampedResumeStep(4, stepCount: stepCount), 4)
        XCTAssertEqual(OnboardingWindowController.clampedResumeStep(7, stepCount: stepCount), 7)
    }

    func testClampedResumeStepClampsOutOfRangeValues() {
        XCTAssertEqual(OnboardingWindowController.clampedResumeStep(-3, stepCount: stepCount), 0)
        XCTAssertEqual(OnboardingWindowController.clampedResumeStep(99, stepCount: stepCount), 7)
    }

    func testCloseCompletesOnboardingOnlyOnFinalStep() {
        XCTAssertFalse(OnboardingWindowController.closeCompletesOnboarding(stepRaw: 0))
        XCTAssertFalse(OnboardingWindowController.closeCompletesOnboarding(stepRaw: 6))
        XCTAssertTrue(OnboardingWindowController.closeCompletesOnboarding(stepRaw: 7))
    }

    func testRepeatedShowOwnsSingleActivationUntilClose() {
        var promotions = 0
        var demotions = 0
        var activations = 0
        let activation = AppActivation(
            promote: { promotions += 1 },
            demote: { demotions += 1 },
            activate: { activations += 1 })
        let windowIdentity = NSObject()

        activation.promoteAndActivate(for: windowIdentity)
        activation.promoteAndActivate(for: windowIdentity)
        activation.windowClosed(windowIdentity)

        XCTAssertEqual(promotions, 1)
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(demotions, 1)
    }

    func testClosingOneOfTwoVisibleWindowsDoesNotDemoteEarly() {
        var promotions = 0
        var demotions = 0
        let activation = AppActivation(
            promote: { promotions += 1 },
            demote: { demotions += 1 },
            activate: {})
        let first = NSObject()
        let second = NSObject()

        activation.promoteAndActivate(for: first)
        activation.promoteAndActivate(for: second)
        XCTAssertEqual(promotions, 1)
        activation.windowClosed(first)
        XCTAssertEqual(demotions, 0)

        activation.windowClosed(second)
        XCTAssertEqual(demotions, 1)
    }

    func testSelectingInstalledOnboardingModelActivatesIt() throws {
        let entry = try XCTUnwrap(ModelCatalog.entries.first)
        var activatedID: String?

        let didActivate = OnboardingModelActivation.activateIfInstalled(
            entry,
            isInstalled: true,
            activate: { activatedID = $0.id })

        XCTAssertTrue(didActivate)
        XCTAssertEqual(activatedID, entry.id)
    }

    func testSelectingUninstalledOnboardingModelDoesNotActivateIt() throws {
        let entry = try XCTUnwrap(ModelCatalog.entries.first)
        var didCallActivate = false

        let didActivate = OnboardingModelActivation.activateIfInstalled(
            entry,
            isInstalled: false,
            activate: { _ in didCallActivate = true })

        XCTAssertFalse(didActivate)
        XCTAssertFalse(didCallActivate)
    }
}
