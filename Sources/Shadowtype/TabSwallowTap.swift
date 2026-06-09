// TabSwallowTap — active CGEventTap that swallows the accept key (Tab) while a
// suggestion is visible so the downstream app never receives it (FR-IN-4).
// Gate tap only: the listen-only observer existed solely to prove deletion and
// is not needed here.
import Cocoa

final class TabSwallowTap {
    // Right Arrow (kVK_RightArrow == 124). Read on the tap thread; gated separately from Tab so
    // cursor motion stays untouched when ghost is mid-line, modifiers are held, or per-app/global
    // toggle is off (Smart Compose / Superhuman parity — coexist instead of two-key conflict).
    static let rightArrowKeycode: Int64 = 124

    var onAccept: (() -> Void)?
    // ⌥Tab accepts the whole remaining line; bare Tab accepts the next word (FR-IN-5).
    var onAcceptLine: (() -> Void)?

    // Accept keycodes (configurable). Default: Tab (kVK_Tab == 48).
    var acceptKeycodes: Set<Int64> = [48]

    // Lock-free flag read on the tap thread (FINDINGS Spike 4 pt 3) — never a plain property.
    private var _lock = os_unfair_lock_s()
    private var _suggestionVisible = false
    // Shortcuts → "Swallow Tab when a suggestion is showing" (default ON). When off, Tab is passed
    // through to the app even while a ghost is visible (so the user accepts only via other means). Read
    // on the tap thread under the same lock; mirrored by AppDelegate.syncToggles.
    private var _enabled = true
    // Per-app "Disable Tab key" (Cotypist): when true for the frontmost app, Tab keeps its native
    // behavior (indent / field-switch) — we neither accept nor swallow it. Set off the tap thread by
    // AppDelegate on app-switch / settings change; read under the same lock in the callback.
    private var _disabledForApp = false
    // Shortcuts → "Also accept with Right Arrow" (default ON). When off, Right Arrow is never
    // swallowed and keeps its native cursor-move behavior. Resolves the global toggle merged with
    // the per-app TriState override (AppDelegate.updateRightArrowAcceptForFrontmost).
    private var _rightArrowEnabled = true
    // Snapshot of EditContextTracker.caretAtLineEnd() pushed by CompletionCoordinator at every
    // suggestion render / accept-advance. Without this gate Right Arrow would swallow mid-line
    // cursor motion when the user had mid-line completions on. Pushed false on every clear.
    private var _caretAtLineEnd = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init() {}

    func setSuggestionVisible(_ v: Bool) {
        os_unfair_lock_lock(&_lock)
        _suggestionVisible = v
        os_unfair_lock_unlock(&_lock)
    }

    private func suggestionVisible() -> Bool {
        os_unfair_lock_lock(&_lock)
        let v = _suggestionVisible
        os_unfair_lock_unlock(&_lock)
        return v
    }

    func setEnabled(_ v: Bool) {
        os_unfair_lock_lock(&_lock)
        _enabled = v
        os_unfair_lock_unlock(&_lock)
    }

    private func swallowEnabled() -> Bool {
        os_unfair_lock_lock(&_lock)
        let v = _enabled
        os_unfair_lock_unlock(&_lock)
        return v
    }

    func setDisabledForApp(_ v: Bool) {
        os_unfair_lock_lock(&_lock)
        _disabledForApp = v
        os_unfair_lock_unlock(&_lock)
    }

    private func disabledForApp() -> Bool {
        os_unfair_lock_lock(&_lock)
        let v = _disabledForApp
        os_unfair_lock_unlock(&_lock)
        return v
    }

    func setRightArrowEnabled(_ v: Bool) {
        os_unfair_lock_lock(&_lock)
        _rightArrowEnabled = v
        os_unfair_lock_unlock(&_lock)
    }

    private func rightArrowEnabled() -> Bool {
        os_unfair_lock_lock(&_lock)
        let v = _rightArrowEnabled
        os_unfair_lock_unlock(&_lock)
        return v
    }

    func setCaretAtLineEnd(_ v: Bool) {
        os_unfair_lock_lock(&_lock)
        _caretAtLineEnd = v
        os_unfair_lock_unlock(&_lock)
    }

    private func caretAtLineEnd() -> Bool {
        os_unfair_lock_lock(&_lock)
        let v = _caretAtLineEnd
        os_unfair_lock_unlock(&_lock)
        return v
    }

    // Pure decision (testable). Swallow Right Arrow only when the ghost is visible AND the caret is
    // at end-of-line AND the user has the toggle on AND no modifier keys are held. Any modifier
    // (⇧→ extends selection, ⌥→ word-jump, ⌘→ line-jump) MUST pass through — those are the cases
    // where the user clearly wants cursor motion, not an accept.
    static func shouldAcceptOnRightArrow(ghostVisible: Bool, caretAtLineEnd: Bool,
                                         enabled: Bool, hasModifier: Bool) -> Bool {
        ghostVisible && caretAtLineEnd && enabled && !hasModifier
    }

    // Enable the active tap only during the visible window to bound freeze risk (Spike 4 pt 4).
    func start() {
        guard tap == nil else {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // Active gate at HEAD of the session tap: A -> app. Returning nil deletes the event.
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                // Always re-enable on disable; pass the event through untouched.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    let me = Unmanaged<TabSwallowTap>.fromOpaque(refcon!).takeUnretainedValue()
                    if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let me = Unmanaged<TabSwallowTap>.fromOpaque(refcon!).takeUnretainedValue()
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                if me.acceptKeycodes.contains(code), me.swallowEnabled(), me.suggestionVisible(),
                   !me.disabledForApp() {
                    // ⌥Tab → accept the whole line; bare Tab → accept the next word (FR-IN-4/5).
                    if event.flags.contains(.maskAlternate) {
                        me.onAcceptLine?()
                    } else {
                        me.onAccept?()
                    }
                    return nil                              // DELETE: app never gets the Tab (FR-IN-4)
                }
                // Right Arrow accept (Smart Compose / Superhuman parity). Bare → accepts next word
                // ONLY when the ghost is visible AND the caret is at end-of-line — otherwise cursor
                // motion wins. Any modifier (⇧/⌥/⌘/⌃) is a cursor command and always passes through.
                if code == TabSwallowTap.rightArrowKeycode, me.swallowEnabled(), !me.disabledForApp() {
                    let hasMod = event.flags.contains(.maskShift)
                        || event.flags.contains(.maskAlternate)
                        || event.flags.contains(.maskCommand)
                        || event.flags.contains(.maskControl)
                    if TabSwallowTap.shouldAcceptOnRightArrow(
                            ghostVisible: me.suggestionVisible(),
                            caretAtLineEnd: me.caretAtLineEnd(),
                            enabled: me.rightArrowEnabled(),
                            hasModifier: hasMod) {
                        me.onAccept?()
                        return nil
                    }
                }
                return Unmanaged.passUnretained(event)       // passthrough
            },
            userInfo: refcon
        ) else {
            // Active taps require Accessibility permission; without it tapCreate returns nil.
            NSLog("TabSwallowTap: could not create active tap — grant Accessibility permission.")
            return
        }

        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        if let t = tap { CFMachPortInvalidate(t) }
        runLoopSource = nil
        tap = nil
    }
}
