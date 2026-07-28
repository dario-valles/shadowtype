// Shadowtype — local-first inline AI autocomplete overlay (PRD FR-1..FR-30).
// Entry point: accessory (LSUIElement) app, no dock icon.
import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()

// An LSUIElement/.accessory app does not become the active app from NSApp.activate alone on
// macOS 14+ (cooperative activation), so a Settings/Onboarding window opens NON-KEY: rows click
// but text fields never take keyboard focus ("can't edit anything"). The fix is to temporarily
// promote to .regular while such a window is open (giving a real active, editable, key window —
// and a Dock icon), then demote back to .accessory once the last one closes. Ownership is tracked by
// window identity so repeated show() calls for an already-visible window do not leak a promotion.
final class AppActivation {
    static let shared = AppActivation()
    private var visibleOwners: Set<ObjectIdentifier> = []
    private let promote: () -> Void
    private let demote: () -> Void
    private let activate: () -> Void

    init(promote: @escaping () -> Void = {
             if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
         },
         demote: @escaping () -> Void = {
             if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
         },
         activate: @escaping () -> Void = {
             NSApp.activate(ignoringOtherApps: true)
         }) {
        self.promote = promote
        self.demote = demote
        self.activate = activate
    }

    func promoteAndActivate(for owner: AnyObject) {
        let wasEmpty = visibleOwners.isEmpty
        if visibleOwners.insert(ObjectIdentifier(owner)).inserted, wasEmpty {
            promote()
        }
        activate()
    }

    func windowClosed(_ owner: AnyObject) {
        guard visibleOwners.remove(ObjectIdentifier(owner)) != nil else { return }
        if visibleOwners.isEmpty { demote() }
    }
}
