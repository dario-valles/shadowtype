import XCTest
@testable import Shadowtype

final class AppUpdateCoordinatorTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var coordinator: AppUpdateCoordinator!

    override func setUp() {
        super.setUp()
        suiteName = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        coordinator = AppUpdateCoordinator(defaults: defaults)
    }

    override func tearDown() {
        coordinator.shutdown()
        defaults.removePersistentDomain(forName: suiteName)
        coordinator = nil
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    func testUpdateChannelDefaultsToBetaAndHonorsStablePreference() {
        XCTAssertEqual(coordinator.currentUpdateChannel().rawValue, UpdateChannel.beta.rawValue)

        defaults.set(false, forKey: "shadowtype.includeBetaBuilds")

        XCTAssertEqual(coordinator.currentUpdateChannel().rawValue, UpdateChannel.stable.rawValue)
    }

    func testAutoCheckDefaultsOnAndCanDisableTimer() {
        XCTAssertTrue(coordinator.autoCheckUpdatesEnabled)
        coordinator.scheduleUpdateTimer()
        XCTAssertNotNil(coordinator.scheduledUpdateTimer)

        defaults.set(false, forKey: "shadowtype.autoCheckUpdates")
        coordinator.scheduleUpdateTimer()

        XCTAssertNil(coordinator.scheduledUpdateTimer)
    }

    func testSchedulingIsIdempotentWhileEnabled() {
        coordinator.scheduleUpdateTimer()
        let firstTimer = coordinator.scheduledUpdateTimer

        coordinator.scheduleUpdateTimer()

        XCTAssertTrue(firstTimer === coordinator.scheduledUpdateTimer)
    }
}
