import Cocoa

@MainActor
final class ScreenOCROptInPrompter {
    private static let offeredFlagKey = "shadowtype.ocrAutoEnabledForScreenRecording"
    private static let enabledKey = "shadowtype.useScreenOCR"

    private let defaults: UserDefaults
    private let shouldEnable: @MainActor () -> Bool

    init(
        defaults: UserDefaults = .standard,
        shouldEnable: @escaping @MainActor () -> Bool = ScreenOCROptInPrompter.presentPrompt
    ) {
        self.defaults = defaults
        self.shouldEnable = shouldEnable
    }

    func permissionStateChanged(isGranted: Bool) {
        if isGranted {
            guard !defaults.bool(forKey: Self.offeredFlagKey) else { return }
            defaults.set(true, forKey: Self.offeredFlagKey)
            guard !defaults.bool(forKey: Self.enabledKey) else { return }
            if shouldEnable() {
                defaults.set(true, forKey: Self.enabledKey)
            }
        } else {
            defaults.set(false, forKey: Self.offeredFlagKey)
        }
    }

    private static func presentPrompt() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Use screen text for context?"
        alert.informativeText = "Screen Recording is now granted. Shadowtype can read on-screen text near where you type to improve suggestions — entirely on-device, nothing leaves your Mac. You can change this anytime in Settings → Context."
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
