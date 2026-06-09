// InputMonitor — passive, system-wide keystroke observation (FR-KC-1, FR-KC-3).
// A LISTEN-ONLY CGEventTap (kCGHeadInsertEventTap, .listenOnly) on a dedicated
// high-priority thread running its own CFRunLoop — NOT a Swift Task/actor, to
// avoid actor-hop latency and priority inversion. The tap callback must NEVER
// block: it cheaply converts each CGEvent to an InputEvent and hands it off over
// a bounded queue to the engine side via onEvent. Observation only — it cannot
// alter or delay typing (active swallowing lives in TabSwallowTap).
import Cocoa

struct InputEvent {
    let keycode: UInt16
    let chars: String
    let isKeyDown: Bool
    // Monotonic press time (ProcessInfo.systemUptime) captured on the tap thread, BEFORE the main-queue
    // hand-off. Consumers measuring typing cadence must use this, not the time onEvent arrives on main —
    // main-queue scheduling latency (token renders, overlay draws) would otherwise inflate the interval.
    let uptime: TimeInterval
}

final class InputMonitor {
    // Magic stamp the Injector writes into `.eventSourceUserData` on every synthetic event it posts
    // (accept-injection typing, backspaces, Cmd-V paste). The listen-only tap below skips any event
    // carrying it — otherwise Shadowtype's OWN injected keystrokes loop back through onKeystroke()→
    // cancel() and wipe the ghost remainder after the first accept on web/Electron fields (where
    // injection is synthetic, not atomic AX). 0 is the default for real hardware events.
    static let injectedEventMagic: Int64 = 0x53_54_49_4E_4A   // "STINJ"

    // INTEGRATOR-NOTE: onEvent is invoked on the MAIN queue (see hand-off below),
    // so coordinator.onKeystroke() / UI access stays main-thread-safe. The tap
    // itself runs off-thread; do not assume onEvent fires synchronously with the
    // keystroke. If you need the raw tap-thread callback for lower latency, read
    // a // INTEGRATOR-NOTE at the dispatch site.
    var onEvent: ((InputEvent) -> Void)?

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Bounded hand-off: the tap callback never blocks. We coalesce/forward via the
    // main queue; the bound caps in-flight events so a stalled consumer can never
    // back-pressure the tap thread (excess is dropped — keystroke observation is
    // advisory for completion triggering, not a source of truth).
    private let inFlight = NSLock()
    private var inFlightCount = 0
    private let maxInFlight = 256

    init() {}

    // MARK: - Permission gate (FR-KC-1)

    /// Ensures listen-event access. Returns true if access is (already) granted.
    /// CGRequestListenEventAccess shows the system prompt on first denial.
    @discardableResult
    private func ensureAccess() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        // Triggers the TCC prompt; returns current (likely false-first-time) state.
        let granted = CGRequestListenEventAccess()
        if !granted {
            NSLog("Shadowtype: Input Monitoring not granted — keystroke observation disabled until authorized.")
        }
        return granted
    }

    // MARK: - Lifecycle

    func start() {
        guard thread == nil else { return }
        ensureAccess()

        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "com.shadowtype.input-tap"
        t.qualityOfService = .userInteractive
        t.stackSize = 512 * 1024
        thread = t
        t.start()
    }

    func stop() {
        guard let rl = runLoop else {
            // Thread may not have spun up its runloop yet; mark for teardown.
            thread = nil
            return
        }
        // Tear down on the tap thread's own runloop to avoid cross-thread races.
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.teardownOnThread()
        }
        CFRunLoopWakeUp(rl)
        thread = nil
    }

    // MARK: - Dedicated tap thread

    private func threadMain() {
        let rl = CFRunLoopGetCurrent()
        runLoop = rl

        // We only care about key events. (Flags-changed could be added later if
        // modifier state ever matters for completion gating.)
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // listen-only, head-insert, session-level — passive observation only.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: refcon
        ) else {
            NSLog("Shadowtype: failed to create listen-only event tap (permission missing?).")
            Diag.log("InputMonitor: tapCreate FAILED (Input Monitoring not granted) — no keystrokes will be observed")
            runLoop = nil
            return
        }
        eventTap = tap
        Diag.log("InputMonitor: listen-only tap created OK — observing keystrokes")

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(rl, src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Run until stop() tears down the source and exits this loop.
        while runLoop != nil, CFRunLoopRunInMode(.defaultMode, 1.0e10, false) != .stopped {
            // CFRunLoopRunInMode returns when the source is removed / loop is empty.
            if runLoopSource == nil { break }
        }
        runLoop = nil
    }

    private func teardownOnThread() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource, let rl = runLoop {
            CFRunLoopRemoveSource(rl, src, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        if let rl = runLoop {
            CFRunLoopStop(rl)
        }
    }

    // MARK: - Callback (MUST NOT BLOCK — FR-KC-3)

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue()

        // Re-enable if the system disabled us for timeout/user-input (FR-KC-3).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        // Skip Shadowtype's own synthetic injection (stamped with injectedEventMagic): observing it
        // would re-enter onKeystroke()→cancel() and clear the ghost remainder mid-accept. Passive tap,
        // so the event still flows to the host untouched — we just don't FORWARD it to the consumer.
        if event.getIntegerValueField(.eventSourceUserData) == InputMonitor.injectedEventMagic {
            return Unmanaged.passUnretained(event)
        }

        // Press time, sampled here on the tap thread (the closest we get to the hardware event) so
        // cadence isn't polluted by the later main-queue hop.
        let uptime = ProcessInfo.processInfo.systemUptime
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Read the produced unicode (cheap, fixed small buffer) without blocking.
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count,
                                       actualStringLength: &length,
                                       unicodeString: &buffer)
        let chars = length > 0 ? String(utf16CodeUnits: buffer, count: length) : ""

        let inputEvent = InputEvent(keycode: keycode,
                                    chars: chars,
                                    isKeyDown: type == .keyDown,
                                    uptime: uptime)

        monitor.forward(inputEvent)

        // Listen-only: always pass the event through untouched.
        return Unmanaged.passUnretained(event)
    }

    // Bounded, non-blocking hand-off to the consumer on the main queue.
    private func forward(_ event: InputEvent) {
        inFlight.lock()
        if inFlightCount >= maxInFlight {
            inFlight.unlock()
            return // drop — never stall the tap thread on a slow consumer.
        }
        inFlightCount += 1
        inFlight.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.inFlight.lock()
            self.inFlightCount -= 1
            self.inFlight.unlock()
            self.onEvent?(event)
        }
    }
}
