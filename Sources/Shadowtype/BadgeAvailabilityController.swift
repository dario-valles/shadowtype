import Cocoa

private enum DisableScope {
    case app(bundleId: String, name: String)
    case domain(String)
    case global
}

private enum DisableDuration {
    case minutes(Int)
    case hours(Int)
    case restOfDay
    case permanent
}

private final class DisableActionPayload: NSObject {
    let scope: DisableScope
    let duration: DisableDuration

    init(scope: DisableScope, duration: DisableDuration) {
        self.scope = scope
        self.duration = duration
    }
}

private final class RewriteActionPayload: NSObject {
    let action: RewriteAction
    let selection: EditContextTracker.CurrentSelection

    init(action: RewriteAction, selection: EditContextTracker.CurrentSelection) {
        self.action = action
        self.selection = selection
    }
}

final class BadgeAvailabilityController: NSObject {
    private let contextTracker: EditContextTracker
    private let rewriteController: SelectionRewriteController
    private let appRules: AppRules
    private let coordinator: CompletionCoordinator
    private let statusItem: StatusItemController
    private let settings: SettingsWindowController
    private let isEnabled: () -> Bool
    private let updateEnabled: (Bool) -> Void
    private let refreshBadge: () -> Void
    private let syncToggles: () -> Void

    private var reEnableTimer: Timer?
    private var globalSnoozeUntil: Date?

    init(
        contextTracker: EditContextTracker,
        rewriteController: SelectionRewriteController,
        appRules: AppRules,
        coordinator: CompletionCoordinator,
        statusItem: StatusItemController,
        settings: SettingsWindowController,
        isEnabled: @escaping () -> Bool,
        updateEnabled: @escaping (Bool) -> Void,
        refreshBadge: @escaping () -> Void,
        syncToggles: @escaping () -> Void
    ) {
        self.contextTracker = contextTracker
        self.rewriteController = rewriteController
        self.appRules = appRules
        self.coordinator = coordinator
        self.statusItem = statusItem
        self.settings = settings
        self.isEnabled = isEnabled
        self.updateEnabled = updateEnabled
        self.refreshBadge = refreshBadge
        self.syncToggles = syncToggles
    }

    func makeBadgeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if let selection = contextTracker.currentSelection(),
           !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for action in RewriteAction.allCases {
                let item = NSMenuItem(
                    title: action.title,
                    action: #selector(rewritePick(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject =
                    RewriteActionPayload(action: action, selection: selection)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "this app"
        let host = contextTracker.frontmostDomainHost()

        if let host {
            if appRules.isEnabled(bundleId: nil, domain: host) {
                menu.addItem(
                    disableItem(
                        title: "Disable Completions on \(host)",
                        scope: .domain(host)))
            } else {
                menu.addItem(
                    resumeItem(
                        title: "Resume Completions on \(host)",
                        scope: .domain(host)))
            }
        }
        if let bundle = app?.bundleIdentifier {
            let scope = DisableScope.app(bundleId: bundle, name: appName)
            if appRules.isEnabled(bundleId: bundle, domain: nil) {
                menu.addItem(
                    disableItem(
                        title: "Disable Completions in \(appName)",
                        scope: scope))
            } else {
                menu.addItem(
                    resumeItem(
                        title: "Resume Completions in \(appName)",
                        scope: scope))
            }
        }
        if isEnabled() {
            menu.addItem(
                disableItem(
                    title: "Disable Completions Globally",
                    scope: .global))
        } else {
            menu.addItem(
                resumeItem(
                    title: "Enable Completions Globally",
                    scope: .global))
        }

        menu.addItem(.separator())
        let hide = NSMenuItem(
            title: "Hide this Button (restore in Settings → General)",
            action: #selector(hideBadgeButton),
            keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Shadowtype Settings…",
            action: #selector(openSettingsFromBadge),
            keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quitItem = NSMenuItem(
            title: "Quit Shadowtype",
            action: #selector(quitFromBadge),
            keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func rewritePick(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? RewriteActionPayload else {
            return
        }
        rewriteController.rewrite(
            action: payload.action,
            selection: payload.selection)
    }

    private func disableItem(title: String, scope: DisableScope) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let durations: [(String, DisableDuration)] = [
            ("For 5 minutes", .minutes(5)),
            ("For 1 hour", .hours(1)),
            ("For the rest of the day", .restOfDay),
            ("Permanently", .permanent),
        ]
        for (label, duration) in durations {
            let durationItem = NSMenuItem(
                title: label,
                action: #selector(applyDisable(_:)),
                keyEquivalent: "")
            durationItem.target = self
            durationItem.representedObject =
                DisableActionPayload(scope: scope, duration: duration)
            submenu.addItem(durationItem)
        }
        item.submenu = submenu
        return item
    }

    private func resumeItem(title: String, scope: DisableScope) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(applyResume(_:)),
            keyEquivalent: "")
        item.target = self
        item.representedObject =
            DisableActionPayload(scope: scope, duration: .permanent)
        return item
    }

    @objc private func applyDisable(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? DisableActionPayload else {
            return
        }
        let until = expiryDate(for: payload.duration)
        switch payload.scope {
        case .app(let bundle, let name):
            appRules.disable(bundleId: bundle, until: until)
            coordinator.cancel()
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle {
                statusItem.setPausedApp(name)
            }
        case .domain(let host):
            appRules.disable(domain: host, until: until)
            coordinator.cancel()
        case .global:
            setMasterEnabled(false)
            globalSnoozeUntil = until
        }
        NotificationCenter.default.post(
            name: .shadowtypeAppRulesDidChange,
            object: nil)
        refreshBadge()
        rescheduleReEnableTimer()
    }

    @objc private func applyResume(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? DisableActionPayload else {
            return
        }
        switch payload.scope {
        case .app(let bundle, _):
            appRules.setEnabled(true, bundleId: bundle)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle {
                statusItem.setPausedApp(nil)
            }
        case .domain(let host):
            appRules.setEnabled(true, domain: host)
        case .global:
            setMasterEnabled(true)
            globalSnoozeUntil = nil
        }
        NotificationCenter.default.post(
            name: .shadowtypeAppRulesDidChange,
            object: nil)
        refreshBadge()
        rescheduleReEnableTimer()
    }

    @objc private func hideBadgeButton() {
        UserDefaults.standard.set(false, forKey: "shadowtype.showActiveBadge")
        syncToggles()
    }

    @objc private func openSettingsFromBadge() {
        settings.show()
    }

    @objc private func quitFromBadge() {
        NSApp.terminate(nil)
    }

    private func setMasterEnabled(_ enabled: Bool) {
        updateEnabled(enabled)
        coordinator.isEnabled = enabled
        statusItem.setEnabled(enabled)
        if !enabled {
            coordinator.cancel()
        }
        refreshBadge()
    }

    private func expiryDate(for duration: DisableDuration) -> Date? {
        switch duration {
        case .minutes(let minutes):
            return Date().addingTimeInterval(Double(minutes) * 60)
        case .hours(let hours):
            return Date().addingTimeInterval(Double(hours) * 3600)
        case .restOfDay:
            let calendar = Calendar.current
            return calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: Date()))
        case .permanent:
            return nil
        }
    }

    func manualMasterToggleDidOccur() {
        globalSnoozeUntil = nil
        rescheduleReEnableTimer()
    }

    private func rescheduleReEnableTimer() {
        reEnableTimer?.invalidate()
        reEnableTimer = nil
        let candidates = [appRules.nextExpiry(), globalSnoozeUntil].compactMap { $0 }
        guard let soonest = candidates.min() else { return }
        let interval = max(0.5, soonest.timeIntervalSinceNow)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleReEnableTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        reEnableTimer = timer
    }

    private func handleReEnableTick() {
        if let globalSnoozeUntil, Date() >= globalSnoozeUntil {
            setMasterEnabled(true)
            self.globalSnoozeUntil = nil
        }
        if let bundle = contextTracker.frontmostBundleId,
           appRules.isEnabled(bundleId: bundle, domain: nil) {
            statusItem.setPausedApp(nil)
        }
        NotificationCenter.default.post(
            name: .shadowtypeAppRulesDidChange,
            object: nil)
        refreshBadge()
        rescheduleReEnableTimer()
    }
}
