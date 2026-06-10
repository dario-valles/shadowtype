// SelectionRewriteController — drives the local "rewrite selected text" flow end to end:
//   hotkey → read selection → action menu at the caret → generate locally → replace inline →
//   preview HUD (⏎ keep · ⌘R redo · ⎋ undo) backed by RewriteKeyTap.
// Reuses the existing primitives: EditContextTracker (selection read + caret rect + re-select),
// Injector.inject (replaces the active selection), CompletionCoordinator.rewrite (on-device model).
// Inline-preview is full-fidelity on native AX fields (settable selection range → re-select / redo /
// undo in place). On web/Electron fields the selection range isn't settable, so it degrades to
// replace + "⌘Z undo" (the user's own ⌘Z passes through and dismisses the HUD). NSObject for the
// menu's @objc target/action. Main-thread only.
import Cocoa

final class SelectionRewriteController: NSObject {
    private let context: EditContextTracker
    private let injector: Injector
    private let coordinator: CompletionCoordinator
    private let hud = RewriteHUD()
    private let keyTap = RewriteKeyTap()

    // AppDelegate vetoes by the same per-app/global enable rules the ghost path uses. Default: allow.
    var isAllowedForFrontmost: () -> Bool = { true }

    // Where the HUD/menu anchor — captured at trigger time (the host app may deactivate while the menu
    // is up, so we don't re-read the caret mid-flow).
    private var anchor: CGRect = .zero

    private struct Session {
        let original: String
        let element: AXUIElement
        let action: RewriteAction
        var insertedRange: CFRange?   // current inserted-text range on native fields; nil on web
        var native: Bool { insertedRange != nil }
    }
    private var session: Session?

    // Safety nets so `coordinator.rewriteActive` (which suppresses ALL ghost completions) can never
    // leak: a click anywhere or an app switch commits the preview, and a hard timeout backstops both
    // the HUD-hint wait and a stuck generation. Installed for the whole active flow, torn down on exit.
    private var mouseMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private static let watchdogSeconds: TimeInterval = 30

    // A menu item's payload (the chosen action + the captured selection).
    private final class ActionBox {
        let action: RewriteAction
        let selection: EditContextTracker.CurrentSelection
        init(_ action: RewriteAction, _ selection: EditContextTracker.CurrentSelection) {
            self.action = action; self.selection = selection
        }
    }

    init(context: EditContextTracker, injector: Injector, coordinator: CompletionCoordinator) {
        self.context = context
        self.injector = injector
        self.coordinator = coordinator
        super.init()
        keyTap.onKeep = { [weak self] in self?.keep() }
        keyTap.onUndo = { [weak self] in self?.undo() }
        keyTap.onRegenerate = { [weak self] in self?.regenerate() }
        keyTap.onOtherKey = { [weak self] in self?.keep() }
        // ⌘R is only OURS on native sessions (the HUD offers "⌘R redo" there). On web sessions the
        // HUD never offers redo, so swallowing ⌘R would dead-key the browser's reload — let the tap
        // treat it as "other key" (commit + pass through) instead. While generating (no session yet)
        // keep swallowing: regenerate() no-ops and Reload mid-rewrite would yank the field away.
        keyTap.shouldSwallowRegenerate = { [weak self] in self?.session?.native ?? true }
    }

    // MARK: - Entry (global hotkey)

    func trigger() {
        guard session == nil else { return }          // a HUD is already up — ignore re-trigger
        anchor = context.caretRectOnScreen()
            ?? context.focusedFieldFrameOnScreen()
            ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)

        guard isAllowedForFrontmost() else { return }
        guard let sel = context.currentSelection(),
              !sel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toast("Select text to rewrite"); return
        }
        showActionMenu(for: sel)
    }

    // Second entry point: run `action` on an ALREADY-captured selection (chosen from the badge menu),
    // skipping the controller's own action menu. The badge captured `sel` at its menu-build time, so we
    // don't re-read it here. Mirrors trigger()'s guards + anchor capture.
    func rewrite(action: RewriteAction, selection sel: EditContextTracker.CurrentSelection) {
        guard session == nil else { return }
        anchor = context.caretRectOnScreen()
            ?? context.focusedFieldFrameOnScreen()
            ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        guard isAllowedForFrontmost() else { return }
        guard !sel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        run(action: action, selection: sel)
    }

    private func showActionMenu(for sel: EditContextTracker.CurrentSelection) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Rewrite selection", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for action in RewriteAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(menuPick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ActionBox(action, sel)
            menu.addItem(item)
        }
        // Pop just below the caret (screen coords when in: is nil); fall back to the mouse.
        let at = anchor.isEmpty ? NSEvent.mouseLocation : NSPoint(x: anchor.minX, y: anchor.minY - 2)
        menu.popUp(positioning: nil, at: at, in: nil)
    }

    @objc private func menuPick(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        run(action: box.action, selection: box.selection)
    }

    // MARK: - Generate + place

    private func run(action: RewriteAction, selection sel: EditContextTracker.CurrentSelection) {
        // A generic "Couldn't rewrite" when the model simply hasn't finished loading reads like a
        // bug; tell the user the real reason and bail before arming any flow state.
        guard coordinator.isEngineLoaded else {
            toast("Model not ready — still loading")
            return
        }
        coordinator.rewriteActive = true
        hud.showWorking(at: anchor)
        // Arm the key tap NOW, before the async decode — otherwise a Return pressed during "Rewriting…"
        // reaches the host and sends the Slack/Mail message. While generating there is no session yet, so
        // a control/other key just cancels cleanly (keep()/cleanup with a nil session). Only the watchdog
        // runs during generation; the click/app-switch guards arrive after place() (installing them now
        // would let the host re-activating after the menu dismisses instantly fire a spurious commit).
        keyTap.arm()
        startWatchdog()
        coordinator.rewrite(selection: sel.text, action: action) { [weak self] result in
            guard let self else { return }
            guard self.coordinator.rewriteActive else { return }   // dismissed/cancelled mid-generation
            guard let result else { self.fail(); return }
            self.place(result: result, selection: sel, action: action)
        }
    }

    private func place(result: String, selection sel: EditContextTracker.CurrentSelection, action: RewriteAction) {
        // Re-assert the captured selection before replacing. The action menu (a modal tracking loop) and
        // the model latency can collapse the host's LIVE selection to a caret, and inject() replaces
        // whatever is selected NOW — without this, a collapsed selection makes inject INSERT a copy
        // ("teh cat" → "teh catThe cat…") instead of replacing.
        //
        // Web/Electron nodes can expose kAXSelectedTextRange (so sel.range != nil) yet treat AX
        // selection writes as a no-op or collapse — and inject() routes them through synthesized typing
        // anyway. Force the web branch for any node that speaks the text-marker protocol, regardless of
        // range availability; otherwise the captured range is "re-asserted" silently to nothing and the
        // unicode typing inserts AT the caret while the DOM selection remains intact ("hello" + select
        // "ell" + rewrite → "hHIello" instead of "hHIo").
        var inserted: CFRange?
        let isWeb = Injector.isWebTextNode(sel.element)
        // No-op rewrite (result is byte-identical to the selection): touching the field would only risk
        // the identical-replace/append ambiguity in axInsert. Keep the selection as-is and bail.
        if result == sel.text {
            session = Session(original: sel.text, element: sel.element, action: action, insertedRange: sel.range)
            showHintForSession()
            return
        }
        if let r = sel.range, !isWeb {
            context.selectRange(r, in: sel.element)
            guard injector.inject(result, into: sel.element) else { fail(); return }
            let range = CFRange(location: r.location, length: (result as NSString).length)
            context.selectRange(range, in: sel.element)  // keep it highlighted for keep/redo/undo
            inserted = range
        } else {
            // Web/Electron: kAXSelectedTextRange isn't settable, so the native re-select above can't run.
            // Chromium/Electron hosts (Slack, Discord, VS Code, browser fields) often DROP the live DOM
            // selection when the app loses key state during the menu loop, leaving the caret at the end
            // of the original selection — synthesized Unicode typing then APPENDS the rewrite after
            // instead of replacing it. Read the live selection via the text-marker protocol; if it no
            // longer matches the captured text, splice the original out behind the caret (backspaces +
            // type) before typing. When the host kept the DOM selection live, fall through to the
            // ordinary synthesized-typing path — the host replaces the selection itself.
            let live = AXTextProbe.webSelectedText(of: sel.element) ?? ""
            if live == sel.text {
                guard injector.inject(result, into: sel.element) else { fail(); return }
            } else {
                let utf16Len = (sel.text as NSString).length
                guard injector.replaceBeforeCaret(utf16Length: utf16Len,
                                                  keystrokeCount: sel.text.count,
                                                  with: result, in: sel.element) else { fail(); return }
            }
        }
        session = Session(original: sel.text, element: sel.element, action: action, insertedRange: inserted)
        showHintForSession()   // keyTap already armed in run()
    }

    private func showHintForSession() {
        guard let s = session else { return }
        let hint = s.native ? "⏎ keep   ⌘R redo   ⎋ undo" : "⏎ keep   ⌘Z undo"
        hud.showHint(at: anchor, text: hint)
        installInteractionGuards()   // now that the result is up and app state has settled
    }

    // MARK: - HUD key actions

    private func regenerate() {
        guard let s = session, s.native else { return }   // web can't reliably re-replace; ignore ⌘R
        hud.showWorking(at: anchor)
        coordinator.rewrite(selection: s.original, action: s.action) { [weak self] result in
            guard let self, var s2 = self.session, let inserted = s2.insertedRange else { return }
            guard let result else { self.showHintForSession(); return }
            self.context.selectRange(inserted, in: s2.element)
            _ = self.injector.inject(result, into: s2.element)
            let newRange = CFRange(location: inserted.location, length: (result as NSString).length)
            self.context.selectRange(newRange, in: s2.element)
            s2.insertedRange = newRange
            self.session = s2
            self.showHintForSession()
        }
    }

    private func undo() {
        if let s = session, let inserted = s.insertedRange {
            context.selectRange(inserted, in: s.element)
            _ = injector.inject(s.original, into: s.element)
            let origRange = CFRange(location: inserted.location, length: (s.original as NSString).length)
            context.selectRange(origRange, in: s.element)
        }
        // Web (no range): leave the rewritten text; the HUD told the user to press ⌘Z themselves.
        cleanup()
    }

    private func keep() {
        if let s = session, let inserted = s.insertedRange {
            // Collapse the selection so the highlight clears, caret just after the kept text.
            let caret = CFRange(location: inserted.location + inserted.length, length: 0)
            context.selectRange(caret, in: s.element)
        }
        cleanup()
    }

    // MARK: - Teardown / transient toast

    private func cleanup() {
        keyTap.disarm()
        removeDismissGuards()
        hud.hide()
        session = nil
        coordinator.rewriteActive = false
    }

    private func fail(message: String = "Couldn't rewrite — try again") {
        keyTap.disarm()           // armed in run(); must come down on the failure path too
        removeDismissGuards()
        coordinator.rewriteActive = false
        session = nil
        hud.showHint(at: anchor, text: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.hud.hide() }
    }

    // Hard timeout backstop: started when generation begins so `rewriteActive` (which suppresses ALL
    // ghost completions) can never stay set if a decode hangs or every dismissal path is missed.
    // No session yet means generation never finished — that's an error the user should hear about,
    // not a silent keep() of nothing. With a session up (result showing), committing is correct.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogSeconds, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            if self.session == nil {
                self.fail(message: "Rewrite timed out — try again")
            } else {
                self.keep()
            }
        }
    }

    // Commit the preview on any interaction the key tap can't see — a mouse click anywhere (incl. within
    // the same app) or a switch to another app. Installed only AFTER place(), so the host re-activating
    // when the action menu dismisses can't trip an instant spurious commit. Idempotent.
    private func installInteractionGuards() {
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.keep() }
        }
        if workspaceObserver == nil {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
                    [weak self] _ in self?.keep()
                }
        }
        // A Spaces switch (Ctrl-←/→, Mission Control) moves the user away without an app activation,
        // leaving the HUD floating over the wrong Space's content. Treat it exactly like app switch.
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
                    [weak self] _ in self?.keep()
                }
        }
    }

    private func removeDismissGuards() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        if let o = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); workspaceObserver = nil }
        if let o = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); spaceObserver = nil }
        watchdog?.invalidate(); watchdog = nil
    }

    private func toast(_ message: String) {
        hud.showHint(at: anchor, text: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.hud.hide() }
    }
}
