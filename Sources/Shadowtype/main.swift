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
// and a Dock icon), then demote back to .accessory once the last one closes. Reference-counted so
// two brand windows open at once don't demote prematurely.
final class AppActivation {
    static let shared = AppActivation()
    private var openCount = 0

    func promoteAndActivate() {
        openCount += 1
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowClosed() {
        openCount = max(0, openCount - 1)
        if openCount == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}
