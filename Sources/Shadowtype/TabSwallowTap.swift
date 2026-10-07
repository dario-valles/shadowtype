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
    var acceptKeycodes: Set<Int64> {
        get {
            os_unfair_lock_lock(&_lock)
            let keycodes = _acceptKeycodes
            os_unfair_lock_unlock(&_lock)
            return keycodes
        }
        set {
            os_unfair_lock_lock(&_lock)
            _acceptKeycodes = newValue
            os_unfair_lock_unlock(&_lock)
        }
    }

    private enum Acceptance {
        case word
        case line
    }

    private var _lock = os_unfair_lock_s()
    private var _acceptKeycodes: Set<Int64> = [48]
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
    // Set on the tap thread before the event is swallowed and cleared only after the main-queue
    // acceptance finishes. A key-repeat arriving while main is busy is swallowed but cannot enqueue
    // a second acceptance against the same visible suggestion.
    private var _acceptancePending = false

    struct Runtime {
        let createTap: (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort?
        let setTapEnabled: (CFMachPort, Bool) -> Void
        let invalidateTap: (CFMachPort) -> Void

        static let live = Runtime(
            createTap: { mask, callback, refcon in
                CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .defaultTap,
                    eventsOfInterest: mask,
                    callback: callback,
                    userInfo: refcon
                )
            },
            setTapEnabled: { tap, enabled in
                CGEvent.tapEnable(tap: tap, enable: enabled)
            },
            invalidateTap: { CFMachPortInvalidate($0) }
        )
    }

    // Lifecycle state, guarded by `lifecycle`. `tap` itself is confined to the tap thread.
    private let lifecycle = NSCondition()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var startupAcknowledged = false
    private var tap: CFMachPort?
    private let runtime: Runtime
    private let scheduleAcceptance: (@escaping () -> Void) -> Void

    init(runtime: Runtime = .live,
         scheduleAcceptance: @escaping (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.async(execute: work)
    }) {
        self.runtime = runtime
        self.scheduleAcceptance = scheduleAcceptance
    }

    var isRunning: Bool {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        return runLoop != nil
    }

    func setSuggestionVisible(_ v: Bool) {
        os_unfair_lock_lock(&_lock)
        _suggestionVisible = v
        os_unfair_lock_unlock(&_lock)
    }

    func setEnabled(_ v: Bool) {
        os_unfair_lock_lock(&_lock)
        _enabled = v
        os_unfair_lock_unlock(&_lock)
    }

    func setDisabledForApp(_ v: Bool) {
        os_unfair_lock_lock(&_lock)
        _disabledForApp = v
        os_unfair_lock_unlock(&_lock)
    }

    func setRightArrowEnabled(_ v: Bool) {
        os_unfair_lock_lock(&_lock)
        _rightArrowEnabled = v
        os_unfair_lock_unlock(&_lock)
    }

    func setCaretAtLineEnd(_ v: Bool) {
        os_unfair_lock_lock(&_lock)
        _caretAtLineEnd = v
        os_unfair_lock_unlock(&_lock)
    }

    // Pure decision (testable). Swallow Right Arrow only when the ghost is visible AND the caret is
    // at end-of-line AND the user has the toggle on AND no modifier keys are held. Any modifier
    // (⇧→ extends selection, ⌥→ word-jump, ⌘→ line-jump) MUST pass through — those are the cases
    // where the user clearly wants cursor motion, not an accept.
    static func shouldAcceptOnRightArrow(ghostVisible: Bool, caretAtLineEnd: Bool,
                                         enabled: Bool, hasModifier: Bool) -> Bool {
        ghostVisible && caretAtLineEnd && enabled && !hasModifier
    }

    // The active-tap callback does only this bounded decision + enqueue. The returned Bool tells the
    // callback whether to swallow the physical key. All AX, overlay, metrics, and injection work stays
    // inside onAccept/onAcceptLine and therefore begins only after the callback returns.
    @discardableResult
    func handleKeyDown(keycode: Int64, flags: CGEventFlags) -> Bool {
        let acceptance: Acceptance?

        os_unfair_lock_lock(&_lock)
        let isTabAccept = _acceptKeycodes.contains(keycode)
            && _enabled
            && _suggestionVisible
            && !_disabledForApp
        let hasModifier = flags.contains(.maskShift)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskCommand)
            || flags.contains(.maskControl)
        let isRightArrowAccept = keycode == Self.rightArrowKeycode
            && _enabled
            && !_disabledForApp
            && Self.shouldAcceptOnRightArrow(
                ghostVisible: _suggestionVisible,
                caretAtLineEnd: _caretAtLineEnd,
                enabled: _rightArrowEnabled,
                hasModifier: hasModifier
            )

        if isTabAccept {
            acceptance = flags.contains(.maskAlternate) ? .line : .word
        } else if isRightArrowAccept {
            acceptance = .word
        } else {
            acceptance = nil
        }

        let shouldSchedule = acceptance != nil && !_acceptancePending
        if shouldSchedule {
            _acceptancePending = true
        }
        os_unfair_lock_unlock(&_lock)

        guard let acceptance else { return false }
        guard shouldSchedule else { return true }

        scheduleAcceptance { [weak self] in
            guard let self else { return }
            defer {
                os_unfair_lock_lock(&self._lock)
                self._acceptancePending = false
                os_unfair_lock_unlock(&self._lock)
            }
            switch acceptance {
            case .word:
                self.onAccept?()
            case .line:
                self.onAcceptLine?()
            }
        }
        return true
    }

    // MARK: - Lifecycle

    // The tap is ACTIVE: every keyDown on the system waits for this callback before reaching the
    // focused app. It therefore runs on its own run loop — never main, where synchronous AX reads,
    // overlay drawing and model bookkeeping would otherwise delay every keystroke system-wide. The
    // callback only takes `_lock` and enqueues; it stays enabled for the pipeline's lifetime because
    // that decision is cheaper than racing an enable against the first Tab after a ghost appears.
    // start()/stop() are called from main and block until the tap thread has finished setting up /
    // tearing down, so a stop can never race a half-created tap.
    func start() {
        lifecycle.lock()
        guard thread == nil else {
            lifecycle.unlock()
            return
        }
        startupAcknowledged = false
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "com.shadowtype.accept-tap"
        t.qualityOfService = .userInteractive
        t.stackSize = 512 * 1024
        thread = t
        t.start()
        while !startupAcknowledged {
            lifecycle.wait()
        }
        lifecycle.unlock()
    }

    func stop() {
        lifecycle.lock()
        guard thread != nil else {
            lifecycle.unlock()
            return
        }
        if let rl = runLoop {
            // Queued as a block rather than a bare CFRunLoopStop: a stop flag set before the thread
            // enters CFRunLoopRun would be discarded, while a performed block runs once it does.
            CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(rl)
        }
        while thread != nil {
            lifecycle.wait()
        }
        lifecycle.unlock()
    }

    // MARK: - Dedicated tap thread

    private func threadMain() {
        let rl = CFRunLoopGetCurrent()
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // Active gate at HEAD of the session tap: A -> app. Returning nil deletes the event.
        guard let t = runtime.createTap(CGEventMask(1 << CGEventType.keyDown.rawValue),
                                        Self.tapCallback, refcon),
              let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0) else {
            // Active taps require Accessibility permission; without it tapCreate returns nil. Not
            // latched: the permission pipeline calls start() again once the grant arrives.
            NSLog("TabSwallowTap: could not create active tap — grant Accessibility permission.")
            finishThread()
            return
        }

        tap = t
        CFRunLoopAddSource(rl, src, .commonModes)
        runtime.setTapEnabled(t, true)

        lifecycle.lock()
        runLoop = rl
        startupAcknowledged = true
        lifecycle.broadcast()
        lifecycle.unlock()

        CFRunLoopRun()

        runtime.setTapEnabled(t, false)
        CFRunLoopRemoveSource(rl, src, .commonModes)
        runtime.invalidateTap(t)
        tap = nil
        finishThread()
    }

    private func finishThread() {
        lifecycle.lock()
        runLoop = nil
        thread = nil
        startupAcknowledged = true
        lifecycle.broadcast()
        lifecycle.unlock()
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<TabSwallowTap>.fromOpaque(refcon).takeUnretainedValue()
        // Always re-enable on disable; pass the event through untouched. `tap` is only written on
        // this thread, before the run loop starts and after it stops.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = me.tap { me.runtime.setTapEnabled(tap, true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if me.handleKeyDown(keycode: code, flags: event.flags) {
            return nil                              // DELETE: app never gets the accept key
        }
        return Unmanaged.passUnretained(event)       // passthrough
    }
}
