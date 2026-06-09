// RewriteKeyTap — short-lived active CGEventTap live ONLY while the rewrite preview HUD is up. It
// intercepts the three control keys the HUD offers so they don't reach the host app, and treats any
// other key as "commit and get out of the way":
//   • Return / Enter   → onKeep      (swallowed — Return would otherwise send the Slack/Mail message)
//   • ⌘R               → onRegenerate (swallowed)
//   • Escape           → onUndo      (swallowed)
//   • anything else     → onOtherKey (passed through so the user's typing isn't lost) then teardown
// Modeled on TabSwallowTap (active .defaultTap at the head of the session tap; returning nil deletes the
// event). The tap exists only between arm()/disarm(), bounding any freeze risk. Callbacks fire on the
// run loop the tap source was added to (main, since arm() is called on main) — same as TabSwallowTap.
import Cocoa

final class RewriteKeyTap {
    var onKeep: (() -> Void)?
    var onRegenerate: (() -> Void)?
    var onUndo: (() -> Void)?
    var onOtherKey: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let kReturn: Int64 = 36
    private static let kEnter: Int64 = 76     // keypad enter
    private static let kEscape: Int64 = 53
    private static let kR: Int64 = 15

    func arm() {
        guard tap == nil else {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<RewriteKeyTap>.fromOpaque(refcon!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let cmd = event.flags.contains(.maskCommand)

                if code == RewriteKeyTap.kReturn || code == RewriteKeyTap.kEnter {
                    me.onKeep?()
                    return nil
                }
                if code == RewriteKeyTap.kEscape {
                    me.onUndo?()
                    return nil
                }
                if cmd && code == RewriteKeyTap.kR {
                    me.onRegenerate?()
                    return nil
                }
                // Any other key commits the rewrite and dismisses; pass the key through to the app.
                me.onOtherKey?()
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            NSLog("RewriteKeyTap: could not create active tap — grant Accessibility permission.")
            return
        }

        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func disarm() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        if let t = tap { CFMachPortInvalidate(t) }
        runLoopSource = nil
        tap = nil
    }
}
