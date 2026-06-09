// ElectronAccessibility — force lazy Chromium/Electron AX trees to materialize (PRD R2 hosts).
// Electron/Chromium only build their accessibility tree when assistive technology is detected, so
// without a nudge our text-marker reads (AXTextProbe) return nothing in VS Code / Cursor / Windsurf /
// Slack / Discord and Chromium browsers (Arc, Dia). Setting the PRIVATE `AXManualAccessibility`
// attribute on the app element is the documented third-party way to trigger that tree, so the user
// doesn't have to run VoiceOver. Native Cocoa apps don't implement the attribute and return
// kAXErrorAttributeUnsupported — a harmless no-op — so we attempt it GENERICALLY per app rather than
// maintain a bundle-id allowlist (this also covers Electron apps we've never heard of).
//
// We deliberately set ONLY AXManualAccessibility, NOT AXEnhancedUserInterface: the latter is the
// broad "assistive tech is active" flag some apps respond to by reflowing their UI, which we don't
// want to provoke. Manual-accessibility is the narrow, Electron-specific switch.
//
// Idempotent + cheap: each pid is attempted exactly once (an app switch is a single AX write).
import ApplicationServices

final class ElectronAccessibility {
    // Pids already attempted. A relaunch gets a fresh pid, so an entry never goes stale for a live
    // process; the set only grows by one per app focused this session (bounded in practice).
    private var forced: Set<pid_t> = []

    // Attempt to enable manual accessibility on `pid` once. Returns true if this call performed the
    // first attempt for that pid, false if it was already attempted. The AX write itself is
    // best-effort (unsupported on native apps), so the return reflects bookkeeping, not AX success.
    @discardableResult
    func forceIfNeeded(pid: pid_t) -> Bool {
        guard pid > 0, !forced.contains(pid) else { return false }
        forced.insert(pid)
        apply(pid: pid)
        return true
    }

    // Apply unconditionally — same AX write, but no bookkeeping. Use on every browser focus so that a
    // Chrome AX tree that wasn't built when we first set the attribute (cold start, tab not yet
    // selected, web area not yet rendered) gets re-primed. Idempotent: setting it again on an
    // already-primed tree is a no-op for Chrome but harmless. Cheap (one AX message).
    func apply(pid: pid_t) {
        guard pid > 0 else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
