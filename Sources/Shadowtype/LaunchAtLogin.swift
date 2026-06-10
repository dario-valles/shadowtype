// FR-LL-1: launch-at-login via SMAppService (macOS 13+). Read live .status; never cache.
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Human-readable description of the last setEnabled failure; nil after a success.
    private(set) static var lastError: String?

    /// Returns the SMAppService outcome so callers can surface a failure (the system can refuse —
    /// e.g. Login Items restrictions) instead of silently leaving the toggle out of sync.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Result<Void, Error> {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
            return .success(())
        } catch {
            lastError = error.localizedDescription
            Diag.log("LaunchAtLogin.setEnabled(\(on)) failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }
}
