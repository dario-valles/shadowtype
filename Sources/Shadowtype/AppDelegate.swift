// AppDelegate — the ONLY glue/wiring file (INTEGRATOR owns this).
// Pre-instantiates every component so filling a stub body activates it without touching shared files.
import Cocoa
import ApplicationServices
import Carbon.HIToolbox

// What a badge-menu disable item acts on, and for how long. Wrapped in an NSObject payload because
// NSMenuItem.representedObject is `Any?` and Swift enums with associated values don't bridge to ObjC.
private enum DisableScope {
    case app(bundleId: String, name: String)
    case domain(String)
    case global
}
private enum DisableDuration { case minutes(Int), hours(Int), restOfDay, permanent }
private final class DisableActionPayload: NSObject {
    let scope: DisableScope
    let duration: DisableDuration
    init(scope: DisableScope, duration: DisableDuration) { self.scope = scope; self.duration = duration }
}
// A badge-menu rewrite item's payload: the chosen action + the selection captured when the menu was
// built (NSMenuItem.representedObject is `Any?`; box it so the AXUIElement-bearing struct can ride along).
private final class RewriteActionPayload: NSObject {
    let action: RewriteAction
    let selection: EditContextTracker.CurrentSelection
    init(action: RewriteAction, selection: EditContextTracker.CurrentSelection) {
        self.action = action; self.selection = selection
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // P0
    let engine = InferenceEngine()
    let modelManager = ModelManager()
    let statusItem = StatusItemController()
    let settings = SettingsWindowController()
    let onboarding = OnboardingWindowController()

    // P1
    let inputMonitor = InputMonitor()
    let contextTracker = EditContextTracker()
    let overlay = OverlayRenderer()
    // Passive "active field" chip pinned left of the focused field (driven by contextTracker focus).
    let badge = BadgeRenderer()

    // P2
    lazy var coordinator = CompletionCoordinator(engine: engine, overlay: overlay, context: contextTracker)
    // Force-activate completions in the focused field (default ⌃`), even where Shadowtype is idle by
    // default (terminals/editor surfaces). Mirrors the menu's "Force suggestions here".
    let forceHotKey = GlobalHotKey()
    // Local "rewrite selected text" (default ⌥⌘K): read the selection, pick an action, rewrite it
    // on-device, preview inline. Distinct hotkey id from forceHotKey (id 2 vs 1).
    let rewriteHotKey = GlobalHotKey()
    lazy var rewriteController = SelectionRewriteController(context: contextTracker,
                                                            injector: injector,
                                                            coordinator: coordinator)
    let tabSwallow = TabSwallowTap()
    let injector = Injector()
    // Shared single instance: the live counter here, the menu meter, and the Settings panes must
    // read/write the SAME record (see WordMeter.shared) or they disagree.
    let wordMeter = WordMeter.shared

    // P2 free features. AppRules is the single shared instance the coordinator queries and the menu
    // "Pause for this app" toggles (Settings reads the same file-backed JSON). Emoji + TypoGuard +
    // OCR are wired into the coordinator's hot path (emoji shortcodes, typo hold-back, gated OCR).
    let appRules = AppRules.shared
    let emoji = EmojiCompletion()
    let typoGuard = TypoGuard()
    let screenContext = ScreenContextProvider()
    private var ocrSettingObserver: NSObjectProtocol?
    private var appSettingsObserver: NSObjectProtocol?
    // Per-app "we can't read this app" banner (Google Docs et al). Coordinator posts the trigger; this
    // owns the floating panel + persisted "don't show again" state (AXNudgeStore).
    private let axNudge = AccessibilityNudgeController()
    // Gmail Smart Compose coexistence banner. Same lifecycle as axNudge — coordinator decides when to
    // fire, AppDelegate just presents. SmartComposeNudgeStore gates dismiss/once-per-session itself.
    private let smartComposeNudge = SmartComposeNudgeController()

    // Context/edit providers wired into the coordinator. Shadowtype is free, so these are always on.
    // Autocorrect / StyleProfile / ClipboardContextProvider / InstructionStore feed the coordinator;
    // ModelCatalog drives the Models pane + the live model-swap observer.
    let autocorrect = Autocorrect()
    let styleProfile = StyleProfile.shared
    let clipboard = ClipboardContextProvider()
    let instructionStore = InstructionStore.shared
    private var lengthObserver: NSObjectProtocol?
    private var selectModelObserver: NSObjectProtocol?
    // FR-LM-1: the currently-loaded model, tracked so a failed live swap can fall back to it.
    private var currentModelURL: URL?

    // M1: local OpenAI-compatible HTTP + MCP API server. Pre-instantiated so the settings panel +
    // status menu can read its state; started lazily when the user enables it. Coordinator +
    // ModelManager are wired in `wireCoordinator()` (where their lifetimes are already established).
    // Auto-restarts on sleep/wake; observes .shadowtypeToggleLocalAPI for menu-driven on/off.
    let localAPI = LocalAPIServer()
    private var localAPIToggleObserver: NSObjectProtocol?

    // M2: the CompletionCoordinator owns the overlay end-to-end (keystroke -> inference -> ghost).
    // `enabled` mirrors the menu-bar toggle (FR-MB-1) and gates the whole loop.
    private var enabled = true
    // Mirrors the Settings "Show active-field indicator" toggle (default on). Gates the badge only.
    private var showBadge = true
    private var focusObserver: NSObjectProtocol?

    // Cotypist-parity timed disables (badge menu "for 5 min / 1 hour / rest of day"). App/domain rules
    // store their own expiry in AppRules and prune lazily; the master "Disable Globally" reuses `enabled`
    // and re-enables at `globalSnoozeUntil`. A single re-arming timer drives UI refresh + global restore.
    private var reEnableTimer: Timer?
    private var globalSnoozeUntil: Date?

    // Models → "Unload model when idle". `idleUnloadMinutes` (0 == Never) is mirrored by syncToggles; a
    // periodic timer unloads the resident model after that much keyboard/focus inactivity, and the next
    // input lazily reloads it (currentModelURL). The flags are only touched on the main thread.
    private var idleUnloadMinutes = 0
    private var lastInputAt = Date()
    private var idleTimer: Timer?
    private var modelIdleUnloaded = false

    // Auto-update (UpdateManager): a once-a-day check timer, rescheduled by syncToggles when the
    // "Automatically check for updates" toggle flips. nil when auto-checks are off.
    private var updateTimer: Timer?
    private var modelReloadInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // M0 debug/smoke entry point: SHADOWTYPE_SMOKE=1 loads a model, generates >=20 tokens
        // from a hardcoded prompt, prints tokens + timing, confirms Metal, then exits.
        if ProcessInfo.processInfo.environment["SHADOWTYPE_SMOKE"] == "1" {
            runSmoke()
            return
        }
        // KV-reuse perf harness: SHADOWTYPE_BENCH=1 measures warm typing-loop TTFT (FR-CE-5/7).
        if ProcessInfo.processInfo.environment["SHADOWTYPE_BENCH"] == "1" {
            runBench()
            return
        }

        installMainMenu()
        statusItem.install()
        wireStatusItemMenu()

        Diag.reset()
        Diag.log("launch: AXIsProcessTrusted=\(AXIsProcessTrusted()) preflightListenEvent=\(CGPreflightListenEventAccess())")

        // FR-KC-1 / PRD §9 onboarding step 1: gate the capture+overlay pipeline behind the
        // Accessibility TCC grant. AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt)
        // shows the system prompt on first launch; until granted, AX caret/text reads are inert
        // (EditContextTracker also re-validates live state to dodge the stale-cache bug).
        if !ensureAccessibilityTrust() {
            NSLog("Shadowtype: Accessibility not yet granted — grant in System Settings ▸ Privacy & Security ▸ Accessibility, then relaunch. Capture/overlay inert until then.")
        }

        // Load model (P0). Errors are non-fatal at scaffold stage.
        Task {
            do {
                // FR-LM-1: prefer the user's persisted model when it's already on disk. We never kick
                // off a multi-GB download at launch — if the chosen model isn't present, fall back to
                // the small default.
                let url = try await modelManager.ensureStartupModel()
                try engine.load(modelPath: url.path)
                await MainActor.run {
                    self.currentModelURL = url   // FR-LM-1: baseline for live-swap fallback
                    self.statusItem.setModelName(url.deletingPathExtension().lastPathComponent)
                }
            } catch {
                NSLog("Shadowtype: model load failed: \(error)")
            }
        }

        wireCoordinator()

        // Auto-update: a silent launch check (gated by the "Automatically check for updates" toggle).
        // The repeating timer is set up by syncToggles (already run inside wireCoordinator above).
        if autoCheckUpdatesEnabled {
            Task { @MainActor in
                await UpdateManager.shared.checkThenStage(channel: self.currentUpdateChannel(), manual: false)
            }
        }

        // M2 hot loop: every observed keystroke feeds the coordinator, which debounces,
        // reads the prefix-before-caret, runs inference off-thread, and drives the ghost
        // overlay. Continuing to type cancels the in-flight run and dismisses the ghost
        // (CompletionCoordinator.onKeystroke -> cancel(), FR-CE-4 / FR-KC-5).
        inputMonitor.onEvent = { [weak self] event in
            guard let self, event.isKeyDown else { return }
            Diag.log("keyDown code=\(event.keycode)")
            Diag.logContent("keyDown chars=\"\(event.chars)\"")
            self.noteActivityAndReloadIfNeeded()
            self.coordinator.onKeystroke(at: event.uptime)
        }

        // Models → idle-unload: poll once a minute for inactivity past the configured window. Added on
        // .common modes so the check still fires while a menu/drag/modal tracking loop is open.
        let idle = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.unloadModelIfIdle() }
        RunLoop.main.add(idle, forMode: .common)
        idleTimer = idle

        // Focus-in / app-switch: warm the KV cache for the freshly focused field (FR-CE-8) so
        // the first real keystroke's suggestion lands faster.
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.enabled else { return }
            self.noteActivityAndReloadIfNeeded()
            self.updateTabDisableForFrontmost()   // per-app "Disable Tab key"
            self.updateRightArrowAcceptForFrontmost()   // per-app "Accept with Right Arrow"
            // App switch: dismiss any ghost still anchored to the previous app's caret (and supersede
            // any in-flight run) BEFORE warming the new focus, so a lingering suggestion can't be
            // Tab-accepted into the newly-focused app.
            self.coordinator.cancel()
            // Let AX focus settle after the activation before reading the caret.
            DispatchQueue.main.async {
                self.coordinator.warmFocus()
                self.refreshBadge()
            }
        }

        // Tab acceptance (FR-IN-4/5): the swallowed Tab injects exactly the next whole word of
        // the live suggestion and bumps the meter by the words actually injected. The literal Tab
        // never reaches the host app (TabSwallowTap returns nil to delete it).
        // Bare Tab accepts the next word; ⌥Tab accepts the whole remaining line (FR-IN-4/5, Shortcuts
        // pane). Both bump the meter by the words actually injected.
        tabSwallow.onAccept = { [weak self] in
            guard let self else { return }
            self.applyAccept(self.coordinator.acceptWord())
        }
        tabSwallow.onAcceptLine = { [weak self] in
            guard let self else { return }
            self.applyAccept(self.coordinator.acceptLine())
        }

        // A left-click on the badge opens the scoped disable/settings menu (Cotypist parity), rebuilt
        // each click so it reflects the current frontmost app + domain.
        badge.menuProvider = { [weak self] in self?.makeBadgeMenu() ?? NSMenu() }
        // Re-anchor / hide the active-field badge on every focus change (set before start()).
        contextTracker.onFocusChange = { [weak self] in self?.refreshBadge() }
        contextTracker.start()
        inputMonitor.start()
        // Global force-activate hotkey (⌃`): same effect as the menu's "Force suggestions here".
        forceHotKey.onPress = { [weak self] in self?.coordinator.forceActivate() }
        forceHotKey.start()

        // Selection-rewrite hotkey (⌥⌘K). Gated by the same global + per-app/domain enable rules as the
        // ghost path; opt-out via the Shortcuts pane toggle. Distinct hotkey id so it doesn't collide
        // with force-activate.
        rewriteController.isAllowedForFrontmost = { [weak self] in
            guard let self, self.coordinator.isEnabled,
                  (UserDefaults.standard.object(forKey: "shadowtype.rewriteEnabled") as? Bool) ?? true
            else { return false }
            return self.appRules.isEnabled(bundleId: self.contextTracker.frontmostBundleId,
                                           domain: self.contextTracker.frontmostDomainHost())
        }
        rewriteHotKey.onPress = { [weak self] in self?.rewriteController.trigger() }
        rewriteHotKey.start(keyCode: UInt32(kVK_ANSI_K),
                            modifiers: UInt32(cmdKey | optionKey), id: 2)
        // TabSwallowTap.start() registers the active tap but it only swallows while a suggestion
        // is visible (gated on setSuggestionVisible, driven by onSuggestionVisibleChanged below).
        tabSwallow.start()

        // PRD §9 / FR-KC-1: first-run onboarding. Shown once (flag persisted on finish), after the
        // pipeline is wired so the Permissions step reflects (and the Try-it/model steps drive) the
        // live subsystems. Deferred a tick so the status item + main run loop are settled first.
        if OnboardingWindowController.shouldShowOnFirstRun {
            DispatchQueue.main.async { [weak self] in self?.onboarding.show() }
        }
    }

    // A standard AppKit main menu. An LSUIElement/.accessory app ships without one (NSApp.mainMenu
    // == nil), and SwiftUI TextFields in our programmatically-created Settings/Onboarding windows then
    // refuse first-responder — the window is key and active, buttons/toggles work via mouse, but text
    // fields can't be typed into (diag: key=true, mainMenu=false, firstResponder stuck on the window).
    // Installing any main menu — crucially the Edit menu with the standard editing selectors — restores
    // the field-editor responder chain so text fields become editable. Also gives ⌘C/V/X/A and ⌘Q.
    private func installMainMenu() {
        guard NSApp.mainMenu == nil else { return }
        let appName = ProcessInfo.processInfo.processName
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    // Wire the coordinator's collaborators + visibility callback. The coordinator's init signature
    // is frozen (engine/overlay/context), so Injector + WordMeter come in via setters (per its
    // INTEGRATOR-NOTE). onSuggestionVisibleChanged drives the Tab swallow gate so Tab is only
    // intercepted while a ghost is on screen (FR-IN-4).
    private func wireCoordinator() {
        coordinator.injector = injector
        coordinator.wordMeter = wordMeter

        // P2 free features into the hot loop: per-app/domain rules (FR-PA-1/2), emoji shortcodes
        // (FR-EM-1), typo hold-back (FR-CE-6), and gated on-screen OCR context (FR-CTX-1, default OFF).
        coordinator.appRules = appRules
        coordinator.emoji = emoji
        coordinator.typoGuard = typoGuard
        coordinator.screenContext = screenContext

        // Context/edit collaborators into the coordinator (each still gated by its own user toggle).
        coordinator.autocorrect = autocorrect
        coordinator.styleProfile = styleProfile
        coordinator.clipboard = clipboard
        coordinator.instructionStore = instructionStore

        // FR-CTX-1: mirror the Context pane's @AppStorage toggle (default OFF). Read once at launch,
        // then keep in sync via the change notification posted below. Same UserDefaults-didChange path
        // also carries the paid toggles (autocorrect / style / clipboard), all read in syncToggles().
        syncToggles()
        // The Context pane writes the toggle via @AppStorage (UserDefaults); reflect live changes.
        ocrSettingObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncToggles()
        }
        // Per-app behavior lives in AppSettingsStore's own file (not UserDefaults), so the toggle above
        // won't fire for it. The Tab tap caches its per-app "Disable Tab" verdict, so re-push it when any
        // per-app setting changes — otherwise toggling it for the current app waits for an app-switch.
        appSettingsObserver = NotificationCenter.default.addObserver(
            forName: .shadowtypeAppSettingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateTabDisableForFrontmost()
        }

        // FR-CE-3: the Context length picker writes CompletionLength.defaultsKey then posts this.
        lengthObserver = NotificationCenter.default.addObserver(
            forName: .shadowtypeCompletionLengthChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyCompletionLength()
        }

        // FR-LM-1: live model swap. The Models pane posts .shadowtypeSelectModel with the chosen
        // ModelCatalogEntry; download+verify off the main thread, then unload/reload on the inference
        // queue and refresh the menu-bar status. (The legacy file-URL payload is ignored — the catalog
        // entry is the wiring contract.)
        selectModelObserver = NotificationCenter.default.addObserver(
            forName: .shadowtypeSelectModel, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let entry = note.userInfo?["entry"] as? ModelCatalogEntry else { return }
            self.swapModel(to: entry)
        }

        // FR-CE-3: own the engine's stop policy here (single owner, per the coordinator's
        // INTEGRATOR-NOTE). Default to the widened multi-word/clause continuation rather than the
        // legacy "first sentence only" fragment; the engine still stops early at maxWords/EOG/newline.
        engine.stopAtFirstSentence = false
        // FR-CE-3 (configurable length): drive engine.maxWords + coordinator.maxTokens from
        // CompletionLength.current() instead of hardcoded literals. Re-applied live on the
        // length-preference change (see observer above).
        applyCompletionLength()
        coordinator.onSuggestionVisibleChanged = { [weak self] visible in
            self?.tabSwallow.setSuggestionVisible(visible)
            // Re-anchor the active-field chip to the current caret line as the user types (otherwise it
            // only re-anchors on focus change and lags behind onto a new line in a tall composer).
            self?.refreshBadge()
        }
        // Right Arrow accept gate (Smart Compose / Superhuman parity). Coordinator snapshots
        // caretAtLineEnd at every show + accept-advance so the tap can decide without a sync
        // AX call from its thread.
        coordinator.onCaretAtLineEndChanged = { [weak self] atEnd in
            self?.tabSwallow.setCaretAtLineEnd(atEnd)
        }
        // todayCount() applies the local-midnight rollover; there is no daily cap (dailyCap is nil).
        statusItem.setWordCount(wordMeter.todayCount())

        // M1: local API server. Started here if the user has flipped the toggle on.
        localAPI.coordinator = coordinator
        localAPI.modelManager = modelManager
        if UserDefaults.standard.bool(forKey: "shadowtype.serverEnabled") {
            startLocalAPIIfNeeded()
        }
        refreshLocalAPIMenu()
        // Menu / settings toggle.
        localAPIToggleObserver = NotificationCenter.default.addObserver(
            forName: .shadowtypeToggleLocalAPI, object: nil, queue: .main
        ) { [weak self] _ in self?.applyLocalAPIToggle() }
    }

    // Reconcile the running server against the enabled-toggle. Used by the settings toggle + menu toggle.
    func applyLocalAPIToggle() {
        let wantOn = UserDefaults.standard.bool(forKey: "shadowtype.serverEnabled")
        if wantOn {
            startLocalAPIIfNeeded()
        } else if localAPI.isRunning {
            localAPI.stop()
            NotificationCenter.default.post(name: .shadowtypeLocalAPIDidChange, object: nil)
        }
        refreshLocalAPIMenu()
    }

    private func startLocalAPIIfNeeded() {
        guard !localAPI.isRunning else { return }
        _ = APIKeyStore.ensureAPIKey()   // create the bearer key on first enable so the UI can show it
        if localAPI.start() != nil {
            NotificationCenter.default.post(name: .shadowtypeLocalAPIDidChange, object: nil)
            Diag.log("localAPI: started on port \(localAPI.boundPort ?? -1)")
        } else {
            Diag.log("localAPI: start failed (\(localAPI.lastError ?? "unknown"))")
        }
        refreshLocalAPIMenu()
    }

    // Push current server state into the status menu. The Local API is always available (free).
    // Also stashes the live port in UserDefaults so the settings pane can read it (no direct
    // reference from a SwiftUI @State view to the AppDelegate-owned server).
    func refreshLocalAPIMenu() {
        statusItem.setLocalAPI(on: localAPI.isRunning, port: localAPI.boundPort,
                               available: true)
        if localAPI.isRunning, let p = localAPI.boundPort {
            UserDefaults.standard.set(p, forKey: "shadowtype.lastBoundPort")
        } else {
            UserDefaults.standard.removeObject(forKey: "shadowtype.lastBoundPort")
        }
    }

    // Shared post-accept bookkeeping for both word and line acceptance (FR-IN-5): bump the meter by
    // the words actually injected and refresh the menu meter / cap state.
    private func applyAccept(_ injected: Int) {
        guard injected > 0 else { return }
        wordMeter.increment(by: injected)
        statusItem.setWordCount(wordMeter.todayCount())
    }

    // Push the frontmost app's resolved "Disable Tab key" tri-state into the tap (read on its tap
    // thread). Default off — Tab keeps accepting completions unless the user turned it off for this app.
    private func updateTabDisableForFrontmost() {
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let disabled = AppSettingsStore.shared.resolve(\.disableTab, forBundleId: bundleId, globalDefault: false)
        tabSwallow.setDisabledForApp(disabled)
    }

    // Resolve the frontmost app's "Accept with Right Arrow" tri-state against the global toggle and
    // push to the tap. Mirrors updateTabDisableForFrontmost — runs on focus change + every settings
    // change. Default global is ON (Smart Compose / Superhuman parity).
    private func updateRightArrowAcceptForFrontmost() {
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let globalOn = (UserDefaults.standard.object(forKey: "shadowtype.acceptOnRightArrow") as? Bool) ?? true
        let enabled = AppSettingsStore.shared.resolve(\.rightArrowAccept,
                                                     forBundleId: bundleId, globalDefault: globalOn)
        tabSwallow.setRightArrowEnabled(enabled)
    }

    // Mirror the Settings @AppStorage toggles into the coordinator. Called at launch and on every
    // UserDefaults change. All features are free; each is gated only by its own user toggle.
    private func syncToggles() {
        coordinator.useScreenOCR = UserDefaults.standard.bool(forKey: "shadowtype.useScreenOCR")
        // #10 paste-insertion fallback: opt-in (default OFF), reachable via `defaults write … paste` —
        // the same hidden-flag pattern used for other experimental paths until it earns a Settings UI.
        injector.pasteEnabled = UserDefaults.standard.bool(forKey: "shadowtype.pasteInsertion")
        coordinator.autocorrectEnabled = UserDefaults.standard.bool(forKey: "GW.autocorrectEnabled")
        coordinator.clipboardContextEnabled = UserDefaults.standard.bool(forKey: "clipboardContextEnabled")
        // styleProfileEnabled defaults to TRUE when the key is unset (opt-out, per the component note).
        coordinator.styleProfileEnabled =
            UserDefaults.standard.object(forKey: "styleProfileEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "styleProfileEnabled")
        // General → "Suggestion trigger delay". Default 120 ms when unset; clamp to the slider range.
        // This is the adaptive-pause FLOOR (see CompletionCoordinator.adaptiveDelay).
        let delayMs = UserDefaults.standard.object(forKey: "shadowtype.triggerDelayMs") as? Double ?? 120
        coordinator.debounce = max(0.04, min(0.4, delayMs / 1000))
        // General → "Aggressiveness": scales the confirmed-pause threshold on top of the delay floor.
        coordinator.pauseMultiplier = Aggressiveness.current().pauseMultiplier
        // General → "Show active-field indicator" (default ON when unset). Re-evaluate the badge live.
        showBadge = (UserDefaults.standard.object(forKey: "shadowtype.showActiveBadge") as? Bool) ?? true
        refreshBadge()

        // General → "Show Tab hint on suggestions" (default ON when unset). Auto-retires after N accepts.
        coordinator.showTabHint =
            (UserDefaults.standard.object(forKey: "shadowtype.showTabHint") as? Bool) ?? true
        // General → "Hold back suggestions on likely typos" (default ON when unset).
        coordinator.holdBackOnTypos =
            (UserDefaults.standard.object(forKey: "shadowtype.holdBackOnTypos") as? Bool) ?? true
        coordinator.smartComposeNudgeEnabled =
            (UserDefaults.standard.object(forKey: "shadowtype.smartComposeNudge") as? Bool) ?? true
        // Shortcuts → "Emoji shortcode" (default ON when unset).
        coordinator.emojiEnabled =
            (UserDefaults.standard.object(forKey: "shadowtype.emojiShortcode") as? Bool) ?? true
        // Shortcuts → "Swallow Tab while a suggestion is showing" (default ON when unset).
        tabSwallow.setEnabled((UserDefaults.standard.object(forKey: "shadowtype.swallowTab") as? Bool) ?? true)
        updateTabDisableForFrontmost()   // a per-app "Disable Tab key" change may have just been saved
        // Shortcuts → "Also accept with Right Arrow" (default ON), merged with per-app TriState.
        updateRightArrowAcceptForFrontmost()

        // Personalization → "strength" (0...3, default 3 when unset). 0 disables the style hint.
        coordinator.personalizationStrength =
            (UserDefaults.standard.object(forKey: "shadowtype.personalizationStrength") as? Int) ?? 3
        // Context → "Context window size" (tokens; default 1024 when unset). Drives the engine prefix cap.
        engine.maxContextTokens =
            (UserDefaults.standard.object(forKey: "shadowtype.contextWindowTokens") as? Int) ?? 1024
        // Models → "Unload model when idle" (minutes; 0 == Never; default 10 matches the picker). The
        // idle timer reads this.
        idleUnloadMinutes =
            (UserDefaults.standard.object(forKey: "shadowtype.unloadIdleMinutes") as? Int) ?? 10
        // General → menu-bar presentation (count + icon style). Defaults match the General pane.
        statusItem.setShowWordCount(
            (UserDefaults.standard.object(forKey: "shadowtype.showWordCountInMenuBar") as? Bool) ?? true)
        statusItem.setIconStyle(UserDefaults.standard.string(forKey: "shadowtype.menuBarIconStyle") ?? "mono")
        // About → "Automatically check for updates" / "Include beta builds": (re)schedule the daily
        // update timer to match. No immediate network call here (syncToggles runs on every defaults
        // change); the launch check + manual "Check for Updates…" cover on-demand checking.
        scheduleUpdateTimer()
    }

    // MARK: - Auto-update scheduling (UpdateManager)

    private var autoCheckUpdatesEnabled: Bool {
        (UserDefaults.standard.object(forKey: "shadowtype.autoCheckUpdates") as? Bool) ?? true
    }

    /// Beta channel unless the "Include beta builds" toggle is explicitly off.
    private func currentUpdateChannel() -> UpdateChannel {
        ((UserDefaults.standard.object(forKey: "shadowtype.includeBetaBuilds") as? Bool) ?? true)
            ? .beta : .stable
    }

    /// (Re)create the once-a-day check timer to match the toggle. syncToggles() runs on EVERY defaults
    /// change, so this must be IDEMPOTENT: if the enabled-state hasn't changed, leave the running timer
    /// alone — otherwise an unrelated write (slider drag, icon toggle) would reset the 24h countdown each
    /// time and the daily check would effectively never fire. The channel is read fresh at fire time, so
    /// flipping the beta toggle needs no reschedule. .common so it still fires inside menu/modal loops.
    private func scheduleUpdateTimer() {
        let enabled = autoCheckUpdatesEnabled
        if enabled == (updateTimer != nil) { return }   // already in the desired state — no churn.
        updateTimer?.invalidate(); updateTimer = nil
        guard enabled else { return }
        let t = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await UpdateManager.shared.checkThenStage(channel: self.currentUpdateChannel(), manual: false)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        updateTimer = t
    }

    /// A required update (running build below the manifest's min_build) is staged — prompt to install now.
    /// This is what gives the mandatory flag teeth; optional updates only reveal the menu/About affordance.
    @MainActor
    private func presentMandatoryUpdateAlert(_ manifest: UpdateManifest) {
        let alert = NSAlert()
        alert.messageText = "Update required"
        alert.informativeText = "Shadowtype \(manifest.version) is a required update.\n\n\(manifest.notes)"
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Later")
        let install: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { UpdateManager.shared.installAndRelaunch() }
        }
        // The Settings window (where the manual "Check for Updates…" lives) is normal-level and key, so an
        // app-modal alert can come up behind it and read as nothing happening. When it's on screen, attach
        // the alert as a sheet so it always rides on top of the window the user is looking at.
        if let host = settings.visibleWindow {
            alert.beginSheetModal(for: host, completionHandler: install)
        } else {
            // No Settings window: make sure the accessory app is frontmost so the app-modal alert isn't
            // buried under another app, then run it modally.
            NSApp.activate(ignoringOtherApps: true)
            install(alert.runModal())
        }
    }

    // Evaluate whether the active-field badge should be visible and where. Same gates as completions:
    // master enable, the per-app pause rule (FR-PA-1), plus a focused non-secure editable field.
    private func refreshBadge() {
        guard enabled, showBadge else { return badge.hide() }
        if let bundle = contextTracker.frontmostBundleId,
           !appRules.isEnabled(bundleId: bundle, domain: nil) { return badge.hide() }
        guard let rect = contextTracker.focusedFieldFrameOnScreen() else { return badge.hide() }
        // Mirror the completion gate: structured/non-prose fields (browser address bar & omnibox, search
        // boxes, web-mail To/Cc/Bcc/Subject) never ghost, so the active-field chip must not anchor there
        // either — it read as Shadowtype claiming the URL bar / recipient row.
        if contextTracker.focusedFieldIsNonProse() { return badge.hide() }
        // Anchor the chip to the caret line (not the centre of a tall compose box). caretRectOnScreen
        // is best-effort; nil falls the chip back to the field centre inside badge.show.
        badge.show(at: rect, caret: contextTracker.caretRectOnScreen())
    }

    // FR-CE-3: apply the effective completion length to engine.maxWords + coordinator.maxTokens.
    // Single owner of this tunable wiring (the coordinator never reads CompletionLength).
    private func applyCompletionLength() {
        let length = CompletionLength.current()
        engine.maxWords = length.maxWords
        coordinator.maxTokens = length.maxTokens
        // Longer presets end on a sentence boundary after their grace word-count instead of truncating
        // at the hard maxWords cap (short/medium pass 0 = legacy word-cap-only behaviour).
        engine.stopAtSentenceAfterWords = length.sentenceStopAfterWords
    }

    // FR-LM-1: download+verify the chosen catalog entry, then swap the active model live on the
    // inference queue and update the menu-bar status. RAM gating is enforced in the Models pane
    // before this is posted.
    private func swapModel(to entry: ModelCatalogEntry) {
        // Mark the engine busy for the WHOLE swap (download + reload) so the idle-unload timer can't tear
        // the model down mid-swap (and a pending idle-reload won't clobber it). Reset on every exit path.
        modelReloadInFlight = true
        Task {
            do {
                let url = try await modelManager.ensureModel(entry)
                // Hand the actual unload/load to the coordinator, which serializes it on the inference
                // queue (the engine is NOT thread-safe — swapping off-queue races an in-flight decode →
                // use-after-free). Fall back to the current model if the new one fails to load.
                let fallback = self.currentModelURL?.path
                // reloadModel() starts with a synchronous cancel() that hides the ghost (NSWindow.orderOut)
                // and MUST run on main — this Task body is on a cooperative thread, so hop to main first or
                // we touch AppKit off-main (SIGTRAP: "Must only be used from the main thread").
                await MainActor.run {
                self.coordinator.reloadModel(at: url.path, fallbackPath: fallback) { [weak self] ok in
                    guard let self else { return }
                    self.modelReloadInFlight = false
                    if ok {
                        self.modelIdleUnloaded = false   // a fresh load supersedes any prior idle state
                        self.currentModelURL = url
                        self.statusItem.setModelName(url.deletingPathExtension().lastPathComponent)
                        // FR-LM-1: persist the choice so the next launch reloads it, not the default.
                        UserDefaults.standard.set(entry.id, forKey: ModelManager.selectedModelDefaultsKey)
                    } else {
                        NSLog("Shadowtype: model swap to \(entry.id) did not load; keeping previous model")
                    }
                    NotificationCenter.default.post(
                        name: .shadowtypeModelDidChange, object: nil,
                        userInfo: ["id": entry.id, "ok": ok])
                }
                }
            } catch {
                NSLog("Shadowtype: model swap to \(entry.id) failed: \(error)")
                // Reset the busy flag AND post on main, matching the success path above — the catch
                // body runs on a cooperative thread, so the off-main post would deliver to observers
                // off-main (AppKit-touching ones would SIGTRAP).
                await MainActor.run {
                    self.modelReloadInFlight = false
                    NotificationCenter.default.post(
                        name: .shadowtypeModelDidChange, object: nil,
                        userInfo: ["id": entry.id, "ok": false])
                }
            }
        }
    }

    // MARK: - Idle model unload (Models → "Unload model when idle")

    // Record keyboard/focus activity and, if a prior idle window unloaded the model, lazily reload it on
    // the inference queue so suggestions resume. The triggering input itself won't get a suggestion (the
    // load is async); subsequent keystrokes do. Main-thread only.
    private func noteActivityAndReloadIfNeeded() {
        lastInputAt = Date()
        guard modelIdleUnloaded, !modelReloadInFlight, let url = currentModelURL else { return }
        // Consume the idle intent up FRONT (not in the completion): a failed reload then can't re-fire on
        // every keystroke (no storm), and recovery doesn't wait for the async unload to flip isLoaded
        // (which lags a tick behind this main-thread call).
        modelIdleUnloaded = false
        modelReloadInFlight = true
        coordinator.reloadModel(at: url.path, fallbackPath: nil) { [weak self] ok in
            guard let self else { return }
            self.modelReloadInFlight = false
            if ok {
                self.statusItem.setModelName(url.deletingPathExtension().lastPathComponent)
            } else {
                NSLog("Shadowtype: idle reload of \(url.lastPathComponent) failed; model stays unloaded until the next model swap or relaunch")
            }
        }
    }

    // Unload the resident model after `idleUnloadMinutes` of inactivity (0 == Never). No-op while already
    // unloaded, mid-reload, or mid-swap (modelReloadInFlight covers both). Main-thread only (the timer
    // fires on main).
    private func unloadModelIfIdle() {
        guard idleUnloadMinutes > 0, !modelIdleUnloaded, !modelReloadInFlight,
              coordinator.isModelLoaded else { return }
        guard Date().timeIntervalSince(lastInputAt) >= Double(idleUnloadMinutes) * 60 else { return }
        coordinator.unloadModel()
        modelIdleUnloaded = true
        statusItem.setModelName("idle — sleeps to save memory")
        Diag.log("idle: unloaded model after \(idleUnloadMinutes) min")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Persist any coalesced stat counters (shown/accepted) before exit so they aren't lost.
        wordMeter.flush()
        if let focusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(focusObserver)
        }
        if let ocrSettingObserver {
            NotificationCenter.default.removeObserver(ocrSettingObserver)
        }
        for obs in [lengthObserver, selectModelObserver, appSettingsObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(obs)
        }
        idleTimer?.invalidate()
        idleTimer = nil
        updateTimer?.invalidate()
        updateTimer = nil
        badge.hide()
        tabSwallow.stop()
        inputMonitor.stop()
        contextTracker.stop()
        engine.unload()
    }

    // MARK: - Accessibility gate (FR-KC-1)

    @discardableResult
    private func ensureAccessibilityTrust() -> Bool {
        let opt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
    }

    // MARK: - Status-item menu wiring (FR-MB-1)

    private func wireStatusItemMenu() {
        let nc = NotificationCenter.default
        // Per-app accessibility nudge: the coordinator decides when (threshold + once-per-host); we
        // just present. AXNudgeStore already gated dismissed/prompted hosts before this fires.
        nc.addObserver(forName: .shadowtypeShowAXNudge, object: nil, queue: .main) { [weak self] note in
            guard let host = note.userInfo?["host"] as? String else { return }
            self?.axNudge.show(host: host)
        }
        nc.addObserver(forName: .shadowtypeShowSmartComposeNudge, object: nil, queue: .main) { [weak self] _ in
            self?.smartComposeNudge.show()
        }
        nc.addObserver(forName: .shadowtypeToggleEnabled, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.enabled = (note.userInfo?["enabled"] as? Bool) ?? !self.enabled
            // Mirror into the coordinator so the whole loop is gated by one switch (FR-MB-1).
            self.coordinator.isEnabled = self.enabled
            if !self.enabled { self.coordinator.cancel() }   // hide ghost + drop in-flight run
            self.globalSnoozeUntil = nil                      // a manual flip cancels any timed global snooze
            self.rescheduleReEnableTimer()
            self.refreshBadge()                               // hide/show the badge with the master switch
        }
        // Menu-bar "Disable for app ▸" list: permanently toggle the chosen (possibly non-frontmost) app.
        nc.addObserver(forName: .shadowtypeToggleAppDisabled, object: nil, queue: .main) { [weak self] note in
            guard let self, let bundle = note.userInfo?["bundleId"] as? String else { return }
            let currentlyEnabled = self.appRules.isEnabled(bundleId: bundle, domain: nil)
            self.appRules.setEnabled(!currentlyEnabled, bundleId: bundle)
            NotificationCenter.default.post(name: .shadowtypeAppRulesDidChange, object: nil)
            if currentlyEnabled { self.coordinator.cancel() }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle {
                self.statusItem.setPausedApp(currentlyEnabled
                    ? NSWorkspace.shared.frontmostApplication?.localizedName : nil)
            }
            self.refreshBadge()
        }
        nc.addObserver(forName: .shadowtypePauseForApp, object: nil, queue: .main) { [weak self] _ in
            // FR-PA-1: toggle the frontmost app's rule in the shared AppRules (coordinator reads it).
            guard let self, let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
            let currentlyEnabled = self.appRules.isEnabled(bundleId: bundle, domain: nil)
            self.appRules.setEnabled(!currentlyEnabled, bundleId: bundle)
            // Let an open Apps & Domains settings pane re-read the live rule (posted post-mutation).
            NotificationCenter.default.post(name: .shadowtypeAppRulesDidChange, object: nil)
            if currentlyEnabled {
                // Was enabled -> now disabled: drop any in-flight ghost and mark the menu.
                self.coordinator.cancel()
                self.statusItem.setPausedApp(NSWorkspace.shared.frontmostApplication?.localizedName)
            } else {
                self.statusItem.setPausedApp(nil)
            }
            self.refreshBadge()   // pausing/unpausing the current app hides/shows its badge
        }
        nc.addObserver(forName: .shadowtypeForceActivate, object: nil, queue: .main) { [weak self] _ in
            self?.coordinator.forceActivate()
        }
        nc.addObserver(forName: .shadowtypeOpenSettings, object: nil, queue: .main) { [weak self] _ in
            self?.settings.show()
        }
        nc.addObserver(forName: .shadowtypeQuit, object: nil, queue: .main) { _ in
            NSApp.terminate(nil)
        }
        // Auto-update: "Check for Updates…" (manual — bypasses the toggle). Open Settings so the About
        // pane shows live progress, then check + stage on the current channel.
        nc.addObserver(forName: .shadowtypeCheckUpdates, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.settings.show()
            Task { @MainActor in
                await UpdateManager.shared.checkThenStage(channel: self.currentUpdateChannel(), manual: true)
            }
        }
        // Auto-update: "Install Update…" — swap the staged bundle and relaunch.
        nc.addObserver(forName: .shadowtypeInstallUpdate, object: nil, queue: .main) { _ in
            Task { @MainActor in UpdateManager.shared.installAndRelaunch() }
        }
        // Auto-update: posted only once an update is STAGED + installable (object = manifest), or with a
        // nil object to hide a stale affordance. Reveal/hide the menu item; for a mandatory update, prompt.
        nc.addObserver(forName: .shadowtypeUpdateAvailable, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let manifest = note.object as? UpdateManifest
            self.statusItem.setUpdateAvailable(version: manifest?.version)
            guard let manifest else { return }
            Task { @MainActor in
                if UpdateManager.shared.isMandatory(manifest) { self.presentMandatoryUpdateAlert(manifest) }
            }
        }
    }

    // MARK: - Badge context menu (Cotypist parity)

    // Build the menu shown when the active-field chip is clicked. Scoped to the current frontmost app and
    // (in a browser) the focused field's domain; each disable item carries a duration submenu.
    private func makeBadgeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Rewrite actions lead the menu when there's a non-empty selection. The selection is captured
        // HERE (menu-build time, while the host still has it highlighted) and carried in the payload, so
        // the menu's modal loop can't invalidate a later re-read.
        if let sel = contextTracker.currentSelection(),
           !sel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for action in RewriteAction.allCases {
                let item = NSMenuItem(title: action.title, action: #selector(rewritePick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = RewriteActionPayload(action: action, selection: sel)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "this app"
        let host = contextTracker.frontmostDomainHost()

        if let host {
            if appRules.isEnabled(bundleId: nil, domain: host) {
                menu.addItem(disableItem(title: "Disable Completions on \(host)", scope: .domain(host)))
            } else {
                menu.addItem(resumeItem(title: "Resume Completions on \(host)", scope: .domain(host)))
            }
        }
        if let bundle = app?.bundleIdentifier {
            let scope = DisableScope.app(bundleId: bundle, name: appName)
            if appRules.isEnabled(bundleId: bundle, domain: nil) {
                menu.addItem(disableItem(title: "Disable Completions in \(appName)", scope: scope))
            } else {
                menu.addItem(resumeItem(title: "Resume Completions in \(appName)", scope: scope))
            }
        }
        if enabled {
            menu.addItem(disableItem(title: "Disable Completions Globally", scope: .global))
        } else {
            menu.addItem(resumeItem(title: "Enable Completions Globally", scope: .global))
        }

        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide this Button", action: #selector(hideBadgeButton), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Shadowtype Settings…", action: #selector(openSettingsFromBadge),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quitItem = NSMenuItem(title: "Quit Shadowtype", action: #selector(quitFromBadge), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    // Run the chosen rewrite action on the selection captured when the badge menu was built.
    @objc private func rewritePick(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? RewriteActionPayload else { return }
        rewriteController.rewrite(action: p.action, selection: p.selection)
    }

    // A "Disable…" row with a duration submenu (5 min / 1 hour / rest of day / permanently).
    private func disableItem(title: String, scope: DisableScope) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let durations: [(String, DisableDuration)] = [
            ("For 5 minutes", .minutes(5)),
            ("For 1 hour", .hours(1)),
            ("For the rest of the day", .restOfDay),
            ("Permanently", .permanent),
        ]
        for (label, dur) in durations {
            let di = NSMenuItem(title: label, action: #selector(applyDisable(_:)), keyEquivalent: "")
            di.target = self
            di.representedObject = DisableActionPayload(scope: scope, duration: dur)
            sub.addItem(di)
        }
        item.submenu = sub
        return item
    }

    // A single "Resume/Enable…" row that clears the scope's rule.
    private func resumeItem(title: String, scope: DisableScope) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(applyResume(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = DisableActionPayload(scope: scope, duration: .permanent)
        return item
    }

    @objc private func applyDisable(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? DisableActionPayload else { return }
        let until = expiryDate(for: payload.duration)
        switch payload.scope {
        case .app(let bundle, let name):
            appRules.disable(bundleId: bundle, until: until)
            coordinator.cancel()
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle {
                statusItem.setPausedApp(name)
            }
        case .domain(let host):
            appRules.disable(domain: host, until: until)
            coordinator.cancel()
        case .global:
            setMasterEnabled(false)
            globalSnoozeUntil = until   // nil == permanent (no auto re-enable)
        }
        NotificationCenter.default.post(name: .shadowtypeAppRulesDidChange, object: nil)
        refreshBadge()
        rescheduleReEnableTimer()
    }

    @objc private func applyResume(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? DisableActionPayload else { return }
        switch payload.scope {
        case .app(let bundle, _):
            appRules.setEnabled(true, bundleId: bundle)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle { statusItem.setPausedApp(nil) }
        case .domain(let host):
            appRules.setEnabled(true, domain: host)
        case .global:
            setMasterEnabled(true)
            globalSnoozeUntil = nil
        }
        NotificationCenter.default.post(name: .shadowtypeAppRulesDidChange, object: nil)
        refreshBadge()
        rescheduleReEnableTimer()
    }

    @objc private func hideBadgeButton() {
        UserDefaults.standard.set(false, forKey: "shadowtype.showActiveBadge")
        syncToggles()   // re-reads the key (-> showBadge=false) and calls refreshBadge()
    }

    @objc private func openSettingsFromBadge() { settings.show() }
    @objc private func quitFromBadge() { NSApp.terminate(nil) }

    // Apply the master enable/disable switch consistently (mirrors the .shadowtypeToggleEnabled path but
    // also reflects the menu-bar checkmark, since the badge — not the menu — initiated the change).
    private func setMasterEnabled(_ on: Bool) {
        enabled = on
        coordinator.isEnabled = on
        statusItem.setEnabled(on)
        if !on { coordinator.cancel() }
        refreshBadge()
    }

    private func expiryDate(for duration: DisableDuration) -> Date? {
        switch duration {
        case .minutes(let m): return Date().addingTimeInterval(Double(m) * 60)
        case .hours(let h):   return Date().addingTimeInterval(Double(h) * 3600)
        case .restOfDay:
            let cal = Calendar.current
            return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
        case .permanent:      return nil
        }
    }

    // Arm a single-shot timer at the soonest pending expiry (app/domain temp rule or the global snooze).
    private func rescheduleReEnableTimer() {
        reEnableTimer?.invalidate(); reEnableTimer = nil
        let candidates = [appRules.nextExpiry(), globalSnoozeUntil].compactMap { $0 }
        guard let soonest = candidates.min() else { return }
        let interval = max(0.5, soonest.timeIntervalSinceNow)
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleReEnableTick()
        }
        // `.common` so the tick still fires while a menu/tracking loop is open (matches idleTimer).
        RunLoop.main.add(t, forMode: .common)
        reEnableTimer = t
    }

    private func handleReEnableTick() {
        if let g = globalSnoozeUntil, Date() >= g {
            setMasterEnabled(true)
            globalSnoozeUntil = nil
        }
        // App/domain temp rules prune themselves on the next isEnabled() read; refresh UI + pause title.
        if let bundle = contextTracker.frontmostBundleId, appRules.isEnabled(bundleId: bundle, domain: nil) {
            statusItem.setPausedApp(nil)
        }
        NotificationCenter.default.post(name: .shadowtypeAppRulesDidChange, object: nil)
        refreshBadge()
        rescheduleReEnableTimer()   // arm for the next pending expiry, if any
    }

    // MARK: - M0 smoke (SHADOWTYPE_SMOKE=1)

    // Resolve a usable GGUF without forcing a multi-hundred-MB download: prefer the
    // Application Support copy, fall back to the matching Hugging Face hub cache, else
    // download via ModelManager. Keeps M0 offline-runnable when a model is already present.
    private func resolveModelForSmoke() async throws -> URL {
        let primary = modelManager.defaultModelURL()
        if FileManager.default.fileExists(atPath: primary.path) { return primary }

        // HF hub cache: ~/.cache/huggingface/hub/models--mradermacher--gemma-3-1b-pt-GGUF/snapshots/*/...
        let hubRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--mradermacher--gemma-3-1b-pt-GGUF/snapshots",
                                    isDirectory: true)
        if let snaps = try? FileManager.default.contentsOfDirectory(at: hubRoot,
                                                                    includingPropertiesForKeys: nil) {
            for snap in snaps {
                let candidate = snap.appendingPathComponent(ModelManager.defaultModelFileName)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    NSLog("Shadowtype[smoke]: using HF-cached model at \(candidate.path)")
                    return candidate
                }
            }
        }

        NSLog("Shadowtype[smoke]: no cached model — downloading default model")
        return try await modelManager.ensureDefaultModel()
    }

    private func runSmoke() {
        Task {
            // Mid-sentence prompt: generate() stops at a sentence boundary (FR-CE-3), so we want
            // a continuation that runs well past 20 tokens before hitting any '.'/'!'/'?'/newline.
            let prompt = "Here is a long list of reasons why people enjoy reading books, written as one continuous run-on clause separated only by commas: people read because"
            let maxTokens = 64
            var exitCode: Int32 = 0
            do {
                let url = try await resolveModelForSmoke()
                NSLog("Shadowtype[smoke]: loading model \(url.lastPathComponent)")
                let loadStart = Date()
                try engine.load(modelPath: url.path)
                NSLog("Shadowtype[smoke]: model loaded in \(Int(Date().timeIntervalSince(loadStart) * 1000)) ms")

                // generate() stops at a sentence boundary (FR-CE-3), so a single call yields a
                // short clause. To exercise >=20 tokens we chain calls forward-from-caret: append
                // each completion to the prompt and continue (the production prefix-growth path).
                var count = 0
                var output = ""
                let genStart = Date()
                var firstTokenMs: Double = -1
                var context = prompt
                while count < 20 {
                    var runEmitted = 0
                    try engine.generate(prompt: context, maxTokens: maxTokens) { piece in
                        if firstTokenMs < 0 {
                            firstTokenMs = Date().timeIntervalSince(genStart) * 1000
                        }
                        count += 1
                        runEmitted += 1
                        output += piece
                        context += piece
                        return true
                    }
                    if runEmitted == 0 { break }   // model produced nothing (EOG) — avoid infinite loop
                }
                let totalMs = Date().timeIntervalSince(genStart) * 1000
                let tps = count > 0 ? Double(count) / (totalMs / 1000) : 0

                NSLog("Shadowtype[smoke]: prompt=\"\(prompt)\"")
                NSLog("Shadowtype[smoke]: completion=\"\(output)\"")
                NSLog("Shadowtype[smoke]: tokens=\(count) firstTokenLatency=\(String(format: "%.1f", firstTokenMs))ms total=\(String(format: "%.1f", totalMs))ms (\(String(format: "%.1f", tps)) tok/s)")
                print("SMOKE_RESULT tokens=\(count) firstTokenMs=\(String(format: "%.1f", firstTokenMs)) totalMs=\(String(format: "%.1f", totalMs)) tps=\(String(format: "%.1f", tps))")
                print("SMOKE_COMPLETION \(output)")

                if count < 20 {
                    NSLog("Shadowtype[smoke]: FAIL — generated \(count) tokens (<20)")
                    exitCode = 2
                } else {
                    NSLog("Shadowtype[smoke]: PASS — generated \(count) tokens (>=20)")
                }
                engine.unload()
            } catch {
                NSLog("Shadowtype[smoke]: FAIL — \(error)")
                print("SMOKE_RESULT error=\(error)")
                exitCode = 1
            }
            exit(exitCode)
        }
    }

    // MARK: - KV-reuse benchmark (SHADOWTYPE_BENCH=1)

    // Reproduces Spike 1's typing loop with the real engine: prefill a ~200-token base context the
    // user "already typed" (cold), then simulate keystrokes that append a couple of words at a time
    // and measure time-to-first-token for each. With KV reuse (FR-CE-5) only the appended tokens are
    // evaluated per keystroke -> warm TTFT should sit far under the 150 ms budget (Spike 1: ~65 ms),
    // versus the cold first prefill. Prints BENCH_RESULT for at-a-glance regression checking.
    private func runBench() {
        Task {
            var exitCode: Int32 = 0
            do {
                let url = try await resolveModelForSmoke()
                try engine.load(modelPath: url.path)

                let base = String(repeating:
                    "The quarterly review went well and the team is confident about the roadmap, ",
                    count: 6) + "and so"
                let additions = [" the plan", " is", " realistic", " given", " our", " current",
                                 " capacity", " this", " quarter", " overall"]

                // Cold first suggestion on the base context (no warm cache).
                let coldStart = Date()
                try engine.generate(prompt: base, maxTokens: 1) { _ in false }
                let coldMs = Date().timeIntervalSince(coldStart) * 1000

                // Warm loop: each "keystroke" appends text (strict extension) -> only the new tokens
                // are prefilled thanks to KV reuse. Measure TTFT (here: time to produce one token).
                var context = base
                var warm: [Double] = []
                for add in additions {
                    context += add
                    let t = Date()
                    try engine.generate(prompt: context, maxTokens: 1) { _ in false }
                    warm.append(Date().timeIntervalSince(t) * 1000)
                }
                let avg = warm.reduce(0, +) / Double(warm.count)
                let mx = warm.max() ?? 0

                NSLog("Shadowtype[bench]: cold=\(String(format: "%.1f", coldMs))ms warm avg=\(String(format: "%.1f", avg))ms max=\(String(format: "%.1f", mx))ms")
                print("BENCH_RESULT coldMs=\(String(format: "%.1f", coldMs)) warmAvgMs=\(String(format: "%.1f", avg)) warmMaxMs=\(String(format: "%.1f", mx)) budget150=\(mx < 150 ? "PASS" : "FAIL")")
                engine.unload()
            } catch {
                print("BENCH_RESULT error=\(error)")
                exitCode = 1
            }
            exit(exitCode)
        }
    }
}
