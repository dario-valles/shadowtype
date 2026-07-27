// PowerPolicy / InferenceEngine thread sizing — the "stay invisible" pair. Shadowtype is a background
// menu-bar app that runs inference on every typing pause, so two things decide whether the user
// notices it: how many CPU threads llama spins against their foreground work, and whether anything
// backs off when the Mac is hot or in Low Power Mode. Both decisions are pure/static precisely so
// they can be pinned here, on a cool Mac of any core count.
import XCTest
@testable import Shadowtype

final class PowerPolicyTests: XCTestCase {
    // A representative "user configured the defaults" baseline: 50 ms trigger delay, the .extraLong
    // token ceiling, the default 1024-token context.
    private let base = PowerPolicy.Settings(debounce: 0.05, maxTokens: 40, maxContextTokens: 1024)

    private let allStates: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]

    // MARK: - Tier mapping

    // `.fair` is where a laptop sits whenever it is doing real work; treating it as pressure would
    // mean throttling essentially always, so only `.serious`/`.critical` (or Low Power Mode) count.
    func testTierIgnoresNominalAndFairWithoutLowPower() {
        XCTAssertEqual(PowerPolicy.tier(thermalState: .nominal, lowPower: false), .nominal)
        XCTAssertEqual(PowerPolicy.tier(thermalState: .fair, lowPower: false), .nominal)
    }

    func testTierEscalatesWithThermalState() {
        XCTAssertEqual(PowerPolicy.tier(thermalState: .serious, lowPower: false), .moderate)
        XCTAssertEqual(PowerPolicy.tier(thermalState: .critical, lowPower: false), .heavy)
    }

    // Low Power Mode is an explicit user request to spend less energy: it throttles on its own...
    func testLowPowerModeAloneThrottles() {
        XCTAssertEqual(PowerPolicy.tier(thermalState: .nominal, lowPower: true), .moderate)
        XCTAssertEqual(PowerPolicy.tier(thermalState: .fair, lowPower: true), .moderate)
    }

    // ...and never SOFTENS a hotter state (a critical Mac in Low Power Mode is still critical).
    func testLowPowerModeNeverSoftensThermalState() {
        XCTAssertEqual(PowerPolicy.tier(thermalState: .critical, lowPower: true), .heavy)
        XCTAssertEqual(PowerPolicy.tier(thermalState: .serious, lowPower: true), .moderate)
    }

    // MARK: - Adjusted values

    func testNoPressureLeavesSettingsUntouched() {
        XCTAssertEqual(PowerPolicy.adjust(base, thermalState: .nominal, lowPower: false), base)
        XCTAssertEqual(PowerPolicy.adjust(base, thermalState: .fair, lowPower: false), base)
    }

    func testModeratePressureLengthensPauseAndShortensGeneration() {
        let out = PowerPolicy.adjust(base, thermalState: .serious, lowPower: false)
        XCTAssertEqual(out.debounce, 0.10, accuracy: 1e-9)   // 2x the configured delay
        XCTAssertEqual(out.maxTokens, 12)
        XCTAssertEqual(out.maxContextTokens, 1024)           // already at/below the cap
    }

    func testHeavyPressureThrottlesFurtherThanModerate() {
        let moderate = PowerPolicy.adjust(base, thermalState: .serious, lowPower: false)
        let heavy = PowerPolicy.adjust(base, thermalState: .critical, lowPower: false)
        XCTAssertGreaterThan(heavy.debounce, moderate.debounce)
        XCTAssertLessThan(heavy.maxTokens, moderate.maxTokens)
        XCTAssertLessThan(heavy.maxContextTokens, moderate.maxContextTokens)
    }

    // MARK: - Invariants

    // The user's own settings are the CEILING: adaptation may only make the app lighter. If this ever
    // inverts, a throttle would speed the app up (or lengthen generation) behind the user's back.
    func testAdaptationIsNeverHeavierThanConfigured() {
        // A spread of plausible user settings, including a deliberately slow/small one.
        let bases = [
            base,
            PowerPolicy.Settings(debounce: 0.04, maxTokens: 8, maxContextTokens: 256),
            PowerPolicy.Settings(debounce: 0.4, maxTokens: 16, maxContextTokens: 4096),
        ]
        for b in bases {
            for state in allStates {
                for lowPower in [false, true] {
                    let out = PowerPolicy.adjust(b, thermalState: state, lowPower: lowPower)
                    XCTAssertGreaterThanOrEqual(out.debounce, b.debounce, "\(state) lowPower=\(lowPower)")
                    XCTAssertLessThanOrEqual(out.maxTokens, b.maxTokens, "\(state) lowPower=\(lowPower)")
                    XCTAssertLessThanOrEqual(out.maxContextTokens, b.maxContextTokens,
                                             "\(state) lowPower=\(lowPower)")
                }
            }
        }
    }

    // A user who already asked for a small budget keeps it — the caps clamp DOWN, they never raise.
    func testAlreadyLightSettingsAreLeftAlone() {
        let light = PowerPolicy.Settings(debounce: 0.4, maxTokens: 8, maxContextTokens: 256)
        let out = PowerPolicy.adjust(light, thermalState: .critical, lowPower: true)
        XCTAssertEqual(out.maxTokens, 8)
        XCTAssertEqual(out.maxContextTokens, 256)
    }

    // The debounce cap bounds the STRETCH, but must not shorten a longer configured delay: a user with
    // a 2 s pause stays at 2 s under critical rather than being sped up to the 1 s cap.
    func testDebounceCapNeverShortensALongConfiguredDelay() {
        let slow = PowerPolicy.Settings(debounce: 2.0, maxTokens: 40, maxContextTokens: 1024)
        XCTAssertEqual(PowerPolicy.adjust(slow, thermalState: .critical, lowPower: false).debounce,
                       2.0, accuracy: 1e-9)
    }

    // ...and it does bound the stretch for in-range settings (0.4 * 3 would be 1.2 s).
    func testDebounceStretchIsCapped() {
        let slider = PowerPolicy.Settings(debounce: 0.4, maxTokens: 40, maxContextTokens: 1024)
        XCTAssertEqual(PowerPolicy.adjust(slider, thermalState: .critical, lowPower: false).debounce,
                       1.0, accuracy: 1e-9)
    }

    // Throttling must never amount to switching suggestions off — a silently dead product is worse
    // than a slower one. Every tier still leaves a usable generation and prompt budget.
    func testThrottlingNeverDisablesSuggestions() {
        for state in allStates {
            for lowPower in [false, true] {
                let out = PowerPolicy.adjust(base, thermalState: state, lowPower: lowPower)
                XCTAssertGreaterThanOrEqual(out.maxTokens, 8, "\(state) lowPower=\(lowPower)")
                XCTAssertGreaterThanOrEqual(out.maxContextTokens, 512, "\(state) lowPower=\(lowPower)")
                XCTAssertLessThanOrEqual(out.debounce, 1.0, "\(state) lowPower=\(lowPower)")
            }
        }
    }

    // Every shipping CompletionLength preset must survive the policy: the throttled ceiling is still a
    // value the pipeline already ships (>= the .short preset's 8), so no preset can be squeezed to zero.
    func testEveryCompletionLengthPresetStaysUsableUnderPressure() {
        for length in CompletionLength.allCases {
            let configured = PowerPolicy.Settings(debounce: 0.05,
                                                  maxTokens: length.maxTokens,
                                                  maxContextTokens: 1024)
            let out = PowerPolicy.adjust(configured, thermalState: .critical, lowPower: true)
            XCTAssertGreaterThanOrEqual(out.maxTokens, min(length.maxTokens, 8), "\(length)")
        }
    }
}
