import Cocoa

final class AppUpdateCoordinator {
    private let defaults: UserDefaults
    private let settings: SettingsWindowController?
    private var updateTimer: Timer?

    init(defaults: UserDefaults = .standard, settings: SettingsWindowController? = nil) {
        self.defaults = defaults
        self.settings = settings
    }

    var autoCheckUpdatesEnabled: Bool {
        (defaults.object(forKey: "shadowtype.autoCheckUpdates") as? Bool) ?? true
    }

    func currentUpdateChannel() -> UpdateChannel {
        ((defaults.object(forKey: "shadowtype.includeBetaBuilds") as? Bool) ?? true)
            ? .beta : .stable
    }

    func scheduleUpdateTimer() {
        let enabled = autoCheckUpdatesEnabled
        if enabled == (updateTimer != nil) { return }
        updateTimer?.invalidate()
        updateTimer = nil
        guard enabled else { return }
        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await UpdateManager.shared.checkThenStage(
                    channel: self.currentUpdateChannel(),
                    manual: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    @MainActor
    func presentMandatoryUpdateAlert(_ manifest: UpdateManifest) {
        let alert = NSAlert()
        alert.messageText = "Update required"
        alert.informativeText = "Shadowtype \(manifest.version) is a required update.\n\n\(manifest.notes)"
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Later")
        let install: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                UpdateManager.shared.installAndRelaunch()
            }
        }
        if let host = settings?.visibleWindow {
            alert.beginSheetModal(for: host, completionHandler: install)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            install(alert.runModal())
        }
    }

    func shutdown() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    var scheduledUpdateTimer: Timer? {
        updateTimer
    }
}
