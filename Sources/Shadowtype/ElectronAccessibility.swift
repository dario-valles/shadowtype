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
// The attribute is NOT universal among Chromium hosts, which is why the write's result is recorded
// rather than discarded (issue #8). `AXManualAccessibility` is implemented by the stock
// `Electron Framework` that Slack / VS Code / Discord / Obsidian / Linear ship, but NOT by
// Chrome-style Chromium builds — Google Chrome doesn't have it (hence the
// `--force-renderer-accessibility` launch hint we show for Arc/Dia), and neither does the OpenAI
// Codex/ChatGPT desktop app, which ships its own rebranded `Codex Framework`. On such a host every
// read in EditContextTracker.readTextAroundCaret returns nil forever and completions go silent with
// no explanation, so the per-pid verdict below is surfaced in the prefix-miss diagnostic to tell
// "this host refuses to expose an AX tree" apart from the other ways a read can fail.
//
// Idempotent + cheap: each pid is attempted exactly once (an app switch is a single AX write).
import ApplicationServices

final class ElectronAccessibility {
    /// What one AXManualAccessibility write told us about a host.
    enum Support: Equatable {
        /// The host accepted the write: a stock-Electron app whose AX tree is now materialized.
        case supported
        /// The host does not implement the attribute. Expected and harmless for native Cocoa apps
        /// (they never needed it); for a Chromium-backed host it means we have no way to wake its
        /// AX tree and text reads there will keep returning nil.
        case unsupported
        /// A transient AX failure (app launching, not yet accepting AX messages, API disabled).
        /// Says nothing about the host, so it never overwrites a definite verdict.
        case unknown

        /// Short, stable token for the diagnostic log.
        var diagLabel: String {
            switch self {
            case .supported:   return "supported"
            case .unsupported: return "unsupported"
            case .unknown:     return "unknown"
            }
        }
    }

    /// Pure (testable): what one `AXUIElementSetAttributeValue` result says about the host. Only the
    /// two definite outcomes are claimed — a host that genuinely answered (`.success`) and one that
    /// genuinely refused the attribute (`.attributeUnsupported`). Every other AXError is
    /// environmental (the app is still launching, AX is off, the element went stale) and must stay
    /// `.unknown` so a mid-launch app is never libelled as unreadable.
    static func classify(_ error: AXError) -> Support {
        switch error {
        case .success:              return .supported
        case .attributeUnsupported: return .unsupported
        default:                    return .unknown
        }
    }

    /// The AX write itself, injectable so the bookkeeping above is testable without a live app.
    typealias AttributeWriter = (pid_t) -> AXError

    private let write: AttributeWriter

    // Pids already attempted. A relaunch gets a fresh pid, so an entry never goes stale for a live
    // process; the set only grows by one per app focused this session (bounded in practice).
    private var forced: Set<pid_t> = []
    // Best verdict seen per pid. Same growth bound as `forced`.
    private var supportByPid: [pid_t: Support] = [:]

    init(write: @escaping AttributeWriter = ElectronAccessibility.liveWrite) {
        self.write = write
    }

    /// The real AX write: set the private attribute on the app element and hand back the raw result.
    static func liveWrite(pid: pid_t) -> AXError {
        let app = AXUIElementCreateApplication(pid)
        return AXUIElementSetAttributeValue(
            app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // Attempt to enable manual accessibility on `pid` once. Returns true if this call performed the
    // first attempt for that pid, false if it was already attempted. The AX write itself is
    // best-effort (unsupported on native apps), so the return reflects bookkeeping, not AX success —
    // ask `support(pid:)` for that.
    @discardableResult
    func forceIfNeeded(pid: pid_t) -> Bool {
        guard pid > 0, !forced.contains(pid) else { return false }
        forced.insert(pid)
        apply(pid: pid)
        return true
    }

    // Apply unconditionally — same AX write, but no "first attempt" bookkeeping. Use on every browser
    // focus so that a Chrome AX tree that wasn't built when we first set the attribute (cold start,
    // tab not yet selected, web area not yet rendered) gets re-primed. Idempotent: setting it again on
    // an already-primed tree is a no-op for Chrome but harmless. Cheap (one AX message).
    @discardableResult
    func apply(pid: pid_t) -> Support {
        guard pid > 0 else { return .unknown }
        let observed = Self.classify(write(pid))
        // A definite verdict is sticky: a later transient failure (app busy, element stale) must not
        // downgrade a host we already know answers — or refuses — the attribute.
        if observed != .unknown || supportByPid[pid] == nil {
            supportByPid[pid] = observed
        }
        return supportByPid[pid] ?? observed
    }

    /// The best verdict recorded for `pid`, or `.unknown` if it was never attempted. Read by the
    /// prefix-miss diagnostic so an unreadable Chromium host is identifiable from a log alone.
    func support(pid: pid_t) -> Support {
        supportByPid[pid] ?? .unknown
    }
}
