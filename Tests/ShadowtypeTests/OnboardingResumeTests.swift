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
}
