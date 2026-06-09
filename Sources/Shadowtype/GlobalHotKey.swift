// GlobalHotKey — a single system-wide hotkey via Carbon RegisterEventHotKey.
// Used for "force-activate completions" (default ⌃`, Cotypist parity): turn suggestions on in the
// current field even where Shadowtype stays idle by default (terminals at a shell prompt, code-editor
// surfaces). RegisterEventHotKey is the right tool here — it fires even for an LSUIElement menu-bar
// app with no key window, which a local NSEvent monitor would never see. The handler hops to main
// and calls `onPress`. One hotkey, registered once; stop() unregisters (also on deinit).
import Carbon.HIToolbox
import AppKit

final class GlobalHotKey {
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    // 'SHTY' signature + a per-instance id disambiguate our hotkeys inside the shared application event
    // target. Each GlobalHotKey installs its own handler that receives ALL hot-key-pressed events, so two
    // instances (force-activate, rewrite) MUST use distinct ids or each would fire on the other's key.
    private var hotKeyID = EventHotKeyID(signature: 0x53485459, id: 1)

    // Default ⌃` (grave). keyCode/modifiers use Carbon virtual-key + modifier constants. `id` must be
    // unique across live GlobalHotKey instances. No-op (with a diagnostic) if the handler can't install or
    // the key is already claimed — never leaves a half-registered state that a later start() would double
    // up on.
    func start(keyCode: UInt32 = UInt32(kVK_ANSI_Grave), modifiers: UInt32 = UInt32(controlKey),
               id: UInt32 = 1) {
        guard hotKeyRef == nil else { return }
        hotKeyID.id = id

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handler: EventHandlerRef?
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var firedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &firedID)
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // Match BOTH signature and id — the signature is what disambiguates our hotkey from any
            // other in-process registration that happens to reuse id 1.
            if firedID.signature == me.hotKeyID.signature, firedID.id == me.hotKeyID.id {
                DispatchQueue.main.async { me.onPress?() }
            }
            return noErr
        }, 1, &spec, selfPtr, &handler)
        guard installStatus == noErr, let handler else {
            Diag.log("GlobalHotKey: InstallEventHandler failed (\(installStatus))"); return
        }

        var ref: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard regStatus == noErr, let ref else {
            Diag.log("GlobalHotKey: RegisterEventHotKey failed (\(regStatus)) — key in use?")
            RemoveEventHandler(handler)   // don't leak the handler we just installed
            return
        }
        handlerRef = handler
        hotKeyRef = ref
    }

    func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }

    deinit { stop() }
}
