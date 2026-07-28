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

    enum LifecycleState {
        case stopped
        case starting
        case running
        case stopping
    }

    struct Runtime {
        let ensureAccess: () -> Bool
        let createTap: (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort?
        let setTapEnabled: (CFMachPort, Bool) -> Void
        let invalidateTap: (CFMachPort) -> Void
        let startupHook: () -> Void

        static let live = Runtime(
            ensureAccess: {
                if CGPreflightListenEventAccess() { return true }
                let granted = CGRequestListenEventAccess()
                if !granted {
                    NSLog("Shadowtype: Input Monitoring not granted — keystroke observation disabled until authorized.")
                }
                return granted
            },
            createTap: { mask, callback, refcon in
                CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .listenOnly,
                    eventsOfInterest: mask,
                    callback: callback,
                    userInfo: refcon
                )
            },
            setTapEnabled: { tap, enabled in
                CGEvent.tapEnable(tap: tap, enable: enabled)
            },
            invalidateTap: { CFMachPortInvalidate($0) },
            startupHook: {}
        )
    }

    private let lifecycle = NSCondition()
    private var lifecycleStateStorage: LifecycleState = .stopped
    private var startupAcknowledged = false
    private var stopRequested = false
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let runtime: Runtime

    // Bounded hand-off: the tap callback never blocks. We coalesce/forward via the
    // main queue; the bound caps in-flight events so a stalled consumer can never
    // back-pressure the tap thread (excess is dropped — keystroke observation is
    // advisory for completion triggering, not a source of truth).
    private let inFlight = NSLock()
    private var inFlightCount = 0
    private let maxInFlight = 256

    init(runtime: Runtime = .live) {
        self.runtime = runtime
    }

    var lifecycleState: LifecycleState {
        lifecycle.lock()
        let state = lifecycleStateStorage
        lifecycle.unlock()
        return state
    }

    // MARK: - Lifecycle

    func start() {
        lifecycle.lock()
        guard lifecycleStateStorage == .stopped else {
            lifecycle.unlock()
            return
        }
        lifecycleStateStorage = .starting
        startupAcknowledged = false
        stopRequested = false
        lifecycle.unlock()

        _ = runtime.ensureAccess()

        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "com.shadowtype.input-tap"
        t.qualityOfService = .userInteractive
        t.stackSize = 512 * 1024

        lifecycle.lock()
        thread = t
        t.start()
        while !startupAcknowledged {
            lifecycle.wait()
        }
        lifecycle.unlock()
    }

    func stop() {
        lifecycle.lock()
        guard lifecycleStateStorage != .stopped else {
            lifecycle.unlock()
            return
        }
        stopRequested = true
        lifecycleStateStorage = .stopping
        let rl = runLoop
        let calledOnWorker = thread === Thread.current
        lifecycle.unlock()

        if calledOnWorker {
            teardownOnThread()
            return
        }
        if let rl {
            // Tear down on the tap thread's own runloop to avoid invalidating a live source elsewhere.
            CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                self?.teardownOnThread()
            }
            CFRunLoopWakeUp(rl)
        }

        // A startup acknowledgement guarantees stop cannot return in the window before threadMain
        // publishes its run loop. threadMain observes stopRequested before enabling any newly-made tap.
        lifecycle.lock()
        while lifecycleStateStorage != .stopped {
            lifecycle.wait()
        }
        lifecycle.unlock()
    }

    // MARK: - Dedicated tap thread

    private func threadMain() {
        runtime.startupHook()
        let rl = CFRunLoopGetCurrent()

        lifecycle.lock()
        runLoop = rl
        let shouldStopBeforeCreate = stopRequested
        lifecycle.unlock()

        defer {
            teardownOnThread()
            finishThread()
        }
        guard !shouldStopBeforeCreate else { return }

        // There is no key-up consumer. Excluding key-up at the mask keeps those events out of Unicode
        // extraction, the in-flight lock, and the main-queue handoff entirely.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // listen-only, head-insert, session-level — passive observation only.
        guard let tap = runtime.createTap(mask, Self.tapCallback, refcon) else {
            NSLog("Shadowtype: failed to create listen-only event tap (permission missing?).")
            Diag.log("InputMonitor: tapCreate FAILED (Input Monitoring not granted) — no keystrokes will be observed")
            return
        }
        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            runtime.invalidateTap(tap)
            return
        }

        lifecycle.lock()
        guard !stopRequested else {
            lifecycle.unlock()
            runtime.invalidateTap(tap)
            return
        }
        eventTap = tap
        runLoopSource = src
        CFRunLoopAddSource(rl, src, .commonModes)
        runtime.setTapEnabled(tap, true)
        lifecycleStateStorage = .running
        startupAcknowledged = true
        lifecycle.broadcast()
        lifecycle.unlock()
        Diag.log("InputMonitor: listen-only tap created OK — observing keystrokes")

        CFRunLoopRun()
    }

    private func teardownOnThread() {
        lifecycle.lock()
        let tap = eventTap
        let src = runLoopSource
        let rl = runLoop
        eventTap = nil
        runLoopSource = nil
        lifecycle.unlock()

        if let tap {
            runtime.setTapEnabled(tap, false)
        }
        if let src, let rl {
            CFRunLoopRemoveSource(rl, src, .commonModes)
        }
        if let tap {
            runtime.invalidateTap(tap)
        }
        if let rl {
            CFRunLoopStop(rl)
        }
    }

    private func finishThread() {
        lifecycle.lock()
        runLoop = nil
        eventTap = nil
        runLoopSource = nil
        thread = nil
        stopRequested = false
        lifecycleStateStorage = .stopped
        startupAcknowledged = true
        lifecycle.broadcast()
        lifecycle.unlock()
    }

    private func currentEventTap() -> CFMachPort? {
        lifecycle.lock()
        let tap = eventTap
        lifecycle.unlock()
        return tap
    }

    // MARK: - Callback (MUST NOT BLOCK — FR-KC-3)

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue()

        // Re-enable if the system disabled us for timeout/user-input (FR-KC-3).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.currentEventTap() {
                monitor.runtime.setTapEnabled(tap, true)
            }
            return Unmanaged.passUnretained(event)
        }

        monitor.decodeAndForward(type: type, event: event)

        // Listen-only: always pass the event through untouched.
        return Unmanaged.passUnretained(event)
    }

    static func decode(type: CGEventType, event: CGEvent,
                       uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> InputEvent? {
        guard type == .keyDown else { return nil }
        // Skip Shadowtype's own synthetic injection (stamped with injectedEventMagic): observing it
        // would re-enter onKeystroke()→cancel() and clear the ghost remainder mid-accept. Passive tap,
        // so the event still flows to the host untouched — we just don't FORWARD it to the consumer.
        if event.getIntegerValueField(.eventSourceUserData) == InputMonitor.injectedEventMagic {
            return nil
        }

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
                                    isKeyDown: true,
                                    uptime: uptime)
        return inputEvent
    }

    func decodeAndForward(type: CGEventType, event: CGEvent,
                          uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let inputEvent = Self.decode(type: type, event: event, uptime: uptime) else { return }
        forward(inputEvent)
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
