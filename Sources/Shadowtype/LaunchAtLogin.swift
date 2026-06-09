// FR-LL-1: launch-at-login via SMAppService (macOS 13+). Read live .status; never cache.
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Diag.log("LaunchAtLogin.setEnabled(\(on)) failed: \(error.localizedDescription)")
        }
    }
}
