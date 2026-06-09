// AccessibilityNudge — the per-app "we can't read this app" nudge (Cotypist-parity).
//
// Some web editors render their text to a canvas that macOS Accessibility can't read until the user
// turns on that app's OWN screen-reader support (Google Docs is the canonical case). When the prefix
// read fails repeatedly in such an app, our completions would otherwise just go silent with no
// explanation. Instead we surface a single, dismissable banner pointing the user at the in-app
// setting we can't toggle for them.
//
// Honest scope: unlike `ElectronAccessibility` (which forces Chromium's AX tree via the private
// AXManualAccessibility attribute), there is NO programmatic switch for the Docs canvas editor — the
// "Turn on screen reader support" toggle lives inside the page. So the nudge is informational
// (steps + a help link) plus "Don't show again", never a one-click enable.
//
// Gating uses plain UserDefaults (faking it buys the user nothing — it only triggers an ask), a
// shared live instance, an injectable-defaults seam for tests, and pure decision logic.
import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by the coordinator when a hostile-host prefix read has missed enough times; AppDelegate
    /// observes it and shows the banner. userInfo["host"] carries the bare lowercased host.
    static let shadowtypeShowAXNudge = Notification.Name("shadowtype.showAXNudge")

    /// Posted by the coordinator when Gmail's Smart Compose has been observed coexisting with our ghost
    /// for N consecutive completions on mail.google.com; AppDelegate shows the Smart Compose banner.
    static let shadowtypeShowSmartComposeNudge = Notification.Name("shadowtype.showSmartComposeNudge")
}

enum AXNudge {
    /// Web hosts whose editable surface macOS AX can't read until the user enables that app's own
    /// screen-reader support. Bare, lowercased hosts (matched against EditContextTracker's host).
    static let hostileHosts: Set<String> = ["docs.google.com"]

    /// Pure (testable): is this host one we know macOS AX can't read without the app's a11y mode?
    static func isHostile(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return hostileHosts.contains(host)
    }

    /// Consecutive prefix misses on a hostile host before the banner shows — high enough that a field
    /// the user merely focused (nothing typed yet) never trips it.
    static let missThreshold = 4

    /// Human label for the banner/help copy.
    static func appLabel(forHost host: String) -> String {
        host.lowercased() == "docs.google.com" ? "Google Docs" : host
    }

    /// The in-app accessibility help page for "How to enable" (the setting we can't toggle for them).
    static func helpURL(forHost host: String) -> URL? {
        let s = host.lowercased() == "docs.google.com"
            ? "https://support.google.com/docs/answer/6282736"
            : "https://" + host
        return URL(string: s)
    }
}

/// Per-host nudge state: a persisted "don't show again" set plus an in-memory per-session miss streak
/// so the banner fires at most once per host per launch and never again once dismissed.
final class AXNudgeStore {
    private enum Key { static let dismissed = "shadowtype.axNudge.dismissedHosts" }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var sessionMisses: [String: Int] = [:]
    private var promptedThisSession: Set<String> = []

    static let shared = AXNudgeStore()
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// True once the user chose "Don't show again" for this host.
    func isDismissed(host: String) -> Bool {
        Set(defaults.stringArray(forKey: Key.dismissed) ?? []).contains(host.lowercased())
    }

    /// Cheap hot-path pre-gate: false once every hostile host has already been prompted this session
    /// or permanently dismissed. Lets `fire()` skip the per-keystroke AX host read entirely in the
    /// steady state — in Google Docs every keystroke yields a nil prefix, so without this the nudge
    /// path would walk the AX tree on every keystroke forever, even after the banner was dismissed.
    func mayStillPrompt() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let dismissed = Set(defaults.stringArray(forKey: Key.dismissed) ?? [])
        return AXNudge.hostileHosts.contains {
            !promptedThisSession.contains($0) && !dismissed.contains($0)
        }
    }

    /// Permanently silence the nudge for this host.
    func dismiss(host: String) {
        lock.lock(); defer { lock.unlock() }
        var d = Set(defaults.stringArray(forKey: Key.dismissed) ?? [])
        d.insert(host.lowercased())
        defaults.set(Array(d), forKey: Key.dismissed)
    }

    /// Record one prefix-miss on a hostile host. Returns true EXACTLY once per session per host — when
    /// the consecutive-miss count first crosses the threshold and the host isn't already dismissed or
    /// already prompted this session. The caller posts the banner notification only on a true return.
    func notePrefixMiss(host: String) -> Bool {
        let h = host.lowercased()
        guard !isDismissed(host: h) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !promptedThisSession.contains(h) else { return false }
        let n = (sessionMisses[h] ?? 0) + 1
        sessionMisses[h] = n
        guard n >= AXNudge.missThreshold else { return false }
        promptedThisSession.insert(h)
        return true
    }
}

// MARK: - Banner UI (non-modal floating panel)

final class AccessibilityNudgeController {
    private var panel: NSPanel?

    // Always invoked on the main thread (the AppDelegate observer uses queue:.main).
    func show(host: String) {
        dismissPanel()
        let appName = AXNudge.appLabel(forHost: host)
        let banner = AXNudgeBanner(
            appName: appName,
            onHowTo: { [weak self] in
                if let url = AXNudge.helpURL(forHost: host) { NSWorkspace.shared.open(url) }
                self?.dismissPanel()
            },
            onDismiss: { [weak self] in
                AXNudgeStore.shared.dismiss(host: host)
                self?.dismissPanel()
            },
            onClose: { [weak self] in self?.dismissPanel() })

        let hosting = NSHostingView(rootView: banner)
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        positionTopCenter(panel, size: size)
        panel.orderFrontRegardless()
        self.panel = panel

        // Auto-dismiss so a stale banner doesn't linger after the user moved on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { [weak self, weak panel] in
            if self?.panel === panel { self?.dismissPanel() }
        }
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func positionTopCenter(_ panel: NSPanel, size: NSSize) {
        guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 14))
    }
}

// MARK: - Gmail Smart Compose coexistence nudge
//
// Gmail's Smart Compose renders a gray inline ghost in the compose body — the same UX surface as ours.
// Tab is ambiguous (both accept), and the two ghosts visually clash. Cotypist solves the analogous
// Google Docs case by pointing the user at the host's own setting; do the same here for Gmail.
//
// Detection is heuristic: when we render a suggestion on mail.google.com, read the focused field's
// full kAXValue. Smart Compose can inject its suggestion into the editable's DOM such that AX picks it
// up as text past the caret. If that tail matches our suggestion's leading run, the two are clashing.
// Probing for the `WhPmne` / "Smart Compose suggestion" sibling via AX is brittle, so we don't —
// the kAXValue heuristic, gated by a consecutive-overlap threshold, is sufficient when it triggers
// and silent (a graceful no-op) when AX doesn't expose the ghost text on a given Gmail load.
enum SmartComposeNudge {
    /// Hosts where Smart Compose runs. Bare, lowercased; matched against EditContextTracker's host.
    static let hosts: Set<String> = ["mail.google.com"]

    /// Consecutive overlaps observed (one per rendered suggestion that coexists with Smart Compose)
    /// before the banner fires. ≥2 keeps the heuristic immune to a single chance match between our
    /// suggestion and whatever happens to follow the caret in the field's AX value.
    static let consecutiveThreshold = 3

    /// Minimum-run length used by detectsOverlap so a 1–3 character coincidence (e.g. " an") doesn't
    /// trip a single overlap. Picked to be short enough that a "let's " + "let's " stub matches but
    /// long enough that incidental whitespace + a stop-word won't.
    static let minOverlapChars = 4

    /// Upper bound on the leading-run comparison — Smart Compose's ghost is typically a short phrase
    /// and we don't need to compare beyond a useful prefix to call it a match.
    static let maxOverlapChars = 24

    /// Pure (testable): is this host one where Smart Compose runs?
    static func isApplicableHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// Pure (testable): does the focused field's AX value contain a tail-fragment matching our
    /// suggestion's leading run? Detection requires:
    ///   * the field value starts with our prefix (so the tail is genuinely "past the caret")
    ///   * the tail has at least `minOverlapChars` chars in common with the suggestion's head
    /// A single leading separator space on either side is normalized so " how are" matches "how are".
    static func detectsOverlap(fieldValue: String?, prefix: String, suggestion: String) -> Bool {
        guard let value = fieldValue,
              !prefix.isEmpty, !suggestion.isEmpty,
              value.count > prefix.count,
              value.hasPrefix(prefix) else { return false }
        let tail = value.dropFirst(prefix.count).drop(while: { $0 == " " })
        let head = Substring(suggestion).drop(while: { $0 == " " })
        let overlap = min(tail.count, head.count, maxOverlapChars)
        guard overlap >= minOverlapChars else { return false }
        return tail.prefix(overlap) == head.prefix(overlap)
    }

    /// Gmail "General" settings deeplink — Smart Compose's toggle lives at the bottom of the page.
    static func settingsURL() -> URL? {
        URL(string: "https://mail.google.com/mail/u/0/#settings/general")
    }
}

/// Smart Compose nudge state: a persisted "don't show again" flag plus an in-memory consecutive-overlap
/// counter so the banner fires at most once per session and never again once dismissed.
final class SmartComposeNudgeStore {
    private enum Key { static let dismissed = "shadowtype.smartCompose.dismissed" }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var consecutiveOverlaps = 0
    private var promptedThisSession = false

    static let shared = SmartComposeNudgeStore()
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// True once the user chose "Don't show again".
    func isDismissed() -> Bool { defaults.bool(forKey: Key.dismissed) }

    /// Permanently silence the nudge.
    func dismiss() { defaults.set(true, forKey: Key.dismissed) }

    /// Cheap pre-gate: false once we've already prompted this session or been permanently dismissed.
    func mayStillPrompt() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !promptedThisSession && !isDismissed()
    }

    /// Record one observed overlap. Returns true EXACTLY once per session — when the consecutive
    /// count first crosses the threshold and we haven't been dismissed or already prompted.
    /// "Consecutive" means: a render WITHOUT overlap resets the streak (see noteNoOverlap), so a
    /// single happenstance match in the middle of a clean session doesn't accumulate.
    func noteOverlap() -> Bool {
        guard !isDismissed() else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !promptedThisSession else { return false }
        consecutiveOverlaps += 1
        guard consecutiveOverlaps >= SmartComposeNudge.consecutiveThreshold else { return false }
        promptedThisSession = true
        return true
    }

    /// A render that did NOT overlap with Smart Compose — resets the consecutive streak so the
    /// threshold reflects a real pattern, not isolated noise.
    func noteNoOverlap() {
        lock.lock(); defer { lock.unlock() }
        consecutiveOverlaps = 0
    }
}

final class SmartComposeNudgeController {
    private var panel: NSPanel?

    // Always invoked on the main thread (the AppDelegate observer uses queue:.main).
    func show() {
        dismissPanel()
        let banner = SmartComposeNudgeBanner(
            onOpenSettings: { [weak self] in
                if let url = SmartComposeNudge.settingsURL() { NSWorkspace.shared.open(url) }
                self?.dismissPanel()
            },
            onDismiss: { [weak self] in
                SmartComposeNudgeStore.shared.dismiss()
                self?.dismissPanel()
            },
            onClose: { [weak self] in self?.dismissPanel() })

        let hosting = NSHostingView(rootView: banner)
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        positionTopCenter(panel, size: size)
        panel.orderFrontRegardless()
        self.panel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { [weak self, weak panel] in
            if self?.panel === panel { self?.dismissPanel() }
        }
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func positionTopCenter(_ panel: NSPanel, size: NSSize) {
        guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 14))
    }
}

private struct SmartComposeNudgeBanner: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 0.65, green: 0.74, blue: 1.0))
            VStack(alignment: .leading, spacing: 8) {
                Text("Gmail's Smart Compose is on")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                Text("Turn it off so Shadowtype's suggestions don't clash. Open Gmail → Settings → General → Smart Compose: off.")
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open Gmail settings", action: onOpenSettings)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Don't show again", action: onDismiss)
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.borderless).foregroundStyle(.white.opacity(0.5))
        }
        .padding(14)
        .frame(width: 460, alignment: .leading)
        .background(Color(red: 0.07, green: 0.07, blue: 0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

private struct AXNudgeBanner: View {
    let appName: String
    let onHowTo: () -> Void
    let onDismiss: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 0.65, green: 0.74, blue: 1.0))
            VStack(alignment: .leading, spacing: 8) {
                Text("Shadowtype can't read \(appName) yet")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                Text("\(appName) hides its text from macOS until you turn on its built-in screen-reader support. Enable it (Tools → Accessibility) to get suggestions here.")
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("How to enable", action: onHowTo)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Don't show again", action: onDismiss)
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.borderless).foregroundStyle(.white.opacity(0.5))
        }
        .padding(14)
        .frame(width: 460, alignment: .leading)
        .background(Color(red: 0.07, green: 0.07, blue: 0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}
