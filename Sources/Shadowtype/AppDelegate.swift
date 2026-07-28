// AppDelegate — the ONLY glue/wiring file (INTEGRATOR owns this).
// Pre-instantiates every component so filling a stub body activates it without touching shared files.
import Cocoa
import ApplicationServices
import Carbon.HIToolbox

extension Notification.Name {
    static let shadowtypeRequiredPermissionsMayHaveChanged =
        Notification.Name("shadowtypeRequiredPermissionsMayHaveChanged")
}

struct RequiredPermissionSnapshot: Equatable {
    let accessibility: Bool
    let inputMonitoring: Bool

    var allGranted: Bool { accessibility && inputMonitoring }

    static var current: RequiredPermissionSnapshot {
        RequiredPermissionSnapshot(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess())
    }
}

final class PermissionLifecycleCoordinator {
    enum Transition: Equatable {
        case none
        case started
        case stopped
    }

    private(set) var isRunning = false
    private let start: () -> Void
    private let stop: () -> Void

    init(start: @escaping () -> Void, stop: @escaping () -> Void) {
        self.start = start
        self.stop = stop
    }

    @discardableResult
    func update(_ permissions: RequiredPermissionSnapshot) -> Transition {
        if permissions.allGranted {
            guard !isRunning else { return .none }
            isRunning = true
            start()
            return .started
        }

        guard isRunning else { return .none }
        isRunning = false
        stop()
        return .stopped
    }

    func shutdown() {
        guard isRunning else { return }
        isRunning = false
        stop()
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
    // Thermal pressure / Low Power Mode (see PowerPolicy). Both signals only ever loosen the live
    // knobs; the stored settings they are derived from are untouched.
    private var thermalObserver: NSObjectProtocol?
    private var powerModeObserver: NSObjectProtocol?
    private var permissionObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var permissionLifecycle: PermissionLifecycleCoordinator?
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
    private var rewriteHotkeyObserver: NSObjectProtocol?
    // M1: local OpenAI-compatible HTTP + MCP API server. Pre-instantiated so the settings panel +
    // status menu can read its state; started lazily when the user enables it. Coordinator +
    // ModelManager are wired in `wireCoordinator()` (where their lifetimes are already established).
    // Auto-restarts on sleep/wake; observes .shadowtypeToggleLocalAPI for menu-driven on/off.
    let localAPI = LocalAPIServer()
    private lazy var localAPIRuntimeController =
        LocalAPIRuntimeController(localAPI: localAPI, statusItem: statusItem)
    private var localAPIToggleObserver: NSObjectProtocol?

    // M2: the CompletionCoordinator owns the overlay end-to-end (keystroke -> inference -> ghost).
    // `enabled` mirrors the menu-bar toggle (FR-MB-1) and gates the whole loop.
    private var enabled = true
    // Mirrors the Settings "Show active-field indicator" toggle (default on). Gates the badge only.
    private var showBadge = true
    private var focusObserver: NSObjectProtocol?

    // Focus generation whose field we have already warmed (FR-CE-8). Both warm triggers — app activation
    // and the tracker's own focus-change callback — go through warmFocusIfFocusChanged(), so an app
    // switch warms exactly once and the per-keystroke kAXValueChanged republishes warm not at all.
    private var lastWarmedFocusSeq: UInt64?

    private lazy var appUpdateCoordinator = AppUpdateCoordinator(settings: settings)
    private lazy var inferenceRuntimeController = InferenceRuntimeController(
        engine: engine,
        coordinator: coordinator,
        modelManager: modelManager,
        statusItem: statusItem)
    private lazy var badgeAvailabilityController = BadgeAvailabilityController(
        contextTracker: contextTracker,
        rewriteController: rewriteController,
        appRules: appRules,
        coordinator: coordinator,
        statusItem: statusItem,
        settings: settings,
        isEnabled: { [weak self] in self?.enabled ?? false },
        updateEnabled: { [weak self] enabled in self?.enabled = enabled },
        refreshBadge: { [weak self] in self?.refreshBadge() },
        syncToggles: { [weak self] in self?.syncToggles() })
    private lazy var inferenceDiagnostics =
        InferenceDiagnostics(modelManager: modelManager, engine: engine)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Retention policy applies to every process start, including smoke/bench harnesses that exit
        // before normal UI wiring: stale diagnostics must not survive an opt-out or a new run.
        Diag.reset()
        // M0 debug/smoke entry point: SHADOWTYPE_SMOKE=1 loads a model, generates >=20 tokens
        // from a hardcoded prompt, prints tokens + timing, confirms Metal, then exits.
        if ProcessInfo.processInfo.environment["SHADOWTYPE_SMOKE"] == "1" {
            inferenceDiagnostics.runSmoke()
            return
        }
        // KV-reuse perf harness: SHADOWTYPE_BENCH=1 measures warm typing-loop TTFT (FR-CE-5/7).
        if ProcessInfo.processInfo.environment["SHADOWTYPE_BENCH"] == "1" {
            inferenceDiagnostics.runBench()
            return
        }

        installMainMenu()
        statusItem.install()
        wireStatusItemMenu()

        Diag.log("launch: AXIsProcessTrusted=\(AXIsProcessTrusted()) preflightListenEvent=\(CGPreflightListenEventAccess())")

        // FR-KC-1 / PRD §9 onboarding step 1: gate the capture+overlay pipeline behind the
        // Accessibility TCC grant. AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt)
        // shows the system prompt on first launch; until granted, AX caret/text reads are inert
        // (EditContextTracker also re-validates live state to dodge the stale-cache bug).
        let accessibilityGranted = ensureAccessibilityTrust()
        let inputMonitoringGranted = ensureInputMonitoringTrust()
        if !accessibilityGranted || !inputMonitoringGranted {
            NSLog("Shadowtype: required permissions not yet granted — capture/overlay will start automatically after Accessibility and Input Monitoring are enabled.")
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
                    self.inferenceRuntimeController.setCurrentModelURL(url)
                    self.statusItem.setModelName(url.deletingPathExtension().lastPathComponent)
                    NotificationCenter.default.post(
                        name: .shadowtypeEngineLoadStateChanged, object: nil, userInfo: ["loaded": true])
                }
            } catch {
                // The engine failed to load the model on disk (e.g. Metal context init failure on a
                // new GPU/OS). This is distinct from the Settings "Loaded" pill, which only checks that
                // the file exists — so surface it where the user (and a bug report) can actually see it:
                // the diag file and the menu bar. Without this the failure was NSLog-only and invisible.
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                NSLog("Shadowtype: model load failed: \(error)")
                Diag.log("model load FAILED: \(reason)")
                await MainActor.run {
                    self.statusItem.setModelName("failed to load — see diag.log")
                    NotificationCenter.default.post(
                        name: .shadowtypeEngineLoadStateChanged, object: nil,
                        userInfo: ["loaded": false, "error": reason])
                }
            }
        }

        wireCoordinator()

        // Auto-update: a silent launch check (gated by the "Automatically check for updates" toggle).
        // The repeating timer is set up by syncToggles (already run inside wireCoordinator above).
        // A pending MANDATORY update bypasses the toggle: the previous session saw a min_build force
        // and the user deferred ("Later") or quit before staging — re-check immediately so the
        // install prompt rides the start of this session, not minutes in.
        if appUpdateCoordinator.autoCheckUpdatesEnabled || UpdateManager.hasPendingMandatoryUpdate {
            Task { @MainActor in
                await UpdateManager.shared.checkThenStage(
                    channel: self.appUpdateCoordinator.currentUpdateChannel(),
                    manual: false)
            }
        }

        // M2 hot loop: every observed keystroke feeds the coordinator, which debounces,
        // reads the prefix-before-caret, runs inference off-thread, and drives the ghost
        // overlay. Continuing to type cancels the in-flight run and dismisses the ghost
        // (CompletionCoordinator.onKeystroke -> cancel(), FR-CE-4 / FR-KC-5).
        inputMonitor.onEvent = { [weak self] event in
            guard let self, event.isKeyDown else { return }
            Diag.log("keyDown code=\(event.keycode)")
            // Check the focused field before touching `event.chars`: password/secure-input keystrokes
            // must never be copied into diagnostics, even under the explicit content-debug opt-in.
            // A failed strict focus read is privacy-unknown, so fail closed instead of consulting the
            // cached read target that may belong to the field active before this key event.
            let privacyUnknown = self.contextTracker.focusedElement() == nil
            if let content = Diag.keyContentMessage(
                secureField: privacyUnknown || self.contextTracker.isSecureField(),
                characters: event.chars) {
                Diag.logContent(content)
            }
            self.inferenceRuntimeController.noteActivityAndReloadIfNeeded()
            self.coordinator.onKeystroke(at: event.uptime)
        }

        // Models → idle-unload: poll once a minute for inactivity past the configured window. Added on
        // .common modes so the check still fires while a menu/drag/modal tracking loop is open.
        inferenceRuntimeController.startIdleTimer()

        // Focus-in / app-switch: warm the KV cache for the freshly focused field (FR-CE-8) so
        // the first real keystroke's suggestion lands faster.
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.enabled, self.permissionLifecycle?.isRunning == true else { return }
            self.inferenceRuntimeController.noteActivityAndReloadIfNeeded()
            self.updateTabDisableForFrontmost()   // per-app "Disable Tab key"
            self.updateRightArrowAcceptForFrontmost()   // per-app "Accept with Right Arrow"
            // App switch: dismiss any ghost still anchored to the previous app's caret (and supersede
            // any in-flight run) BEFORE warming the new focus, so a lingering suggestion can't be
            // Tab-accepted into the newly-focused app.
            self.coordinator.focusDidChange()
            // Let AX focus settle after the activation before reading the caret.
            DispatchQueue.main.async {
                self.warmFocusIfFocusChanged()
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
        badge.menuProvider = { [weak self] in
            self?.badgeAvailabilityController.makeBadgeMenu() ?? NSMenu()
        }
        // Re-anchor / hide the active-field badge on every focus change (set before start()), and warm
        // the KV cache for the newly focused field. The warm used to hang off
        // NSWorkspace.didActivateApplicationNotification ALONE, so moving between fields WITHIN an app
        // (compose box → subject → another compose box) never warmed anything and the first keystroke
        // there always paid a cold prefill. Value changes invalidate read caches without entering this
        // callback; this closure therefore represents an actual focus/app transition.
        contextTracker.onFocusChange = { [weak self] in
            guard let self else { return }
            self.coordinator.focusDidChange()
            self.refreshBadge()
            self.warmFocusIfFocusChanged()
        }
        // Global force-activate hotkey (⌃`): same effect as the menu's "Force suggestions here".
        forceHotKey.onPress = { [weak self] in
            guard let self, self.permissionLifecycle?.isRunning == true else { return }
            self.coordinator.forceActivate()
        }
        forceHotKey.start()

        // Selection-rewrite hotkey (⌥⌘K). Gated by the same global + per-app/domain enable rules as the
        // ghost path; opt-out via the Shortcuts pane toggle. Distinct hotkey id so it doesn't collide
        // with force-activate.
        rewriteController.isAllowedForFrontmost = { [weak self] in
            guard let self, self.coordinator.isEnabled,
                  self.permissionLifecycle?.isRunning == true,
                  (UserDefaults.standard.object(forKey: "shadowtype.rewriteEnabled") as? Bool) ?? true
            else { return false }
            return self.appRules.isEnabled(bundleId: self.contextTracker.frontmostBundleId,
                                           domain: self.contextTracker.frontmostDomainHost())
        }
        rewriteHotKey.onPress = { [weak self] in self?.rewriteController.trigger() }
        registerRewriteHotkey()
        // The General pane's "Rewrite shortcut" picker posts this after writing the chord key —
        // GlobalHotKey.start() tears down the old registration first, so a single call rebinds.
        rewriteHotkeyObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("shadowtypeRewriteHotkeyChanged"), object: nil, queue: .main
        ) { [weak self] _ in self?.registerRewriteHotkey() }
        // TabSwallowTap.start() registers the active tap but it only swallows while a suggestion
        // is visible (gated on setSuggestionVisible, driven by onSuggestionVisibleChanged below).
        installPermissionLifecycle()

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
            self?.updateRightArrowAcceptForFrontmost()
        }

        // Thermal pressure / Low Power Mode: re-apply the knobs so a hot or battery-saving Mac gets a
        // longer pause and a shorter generation, and gets its full settings back when it recovers.
        // Both notifications can be delivered on any thread; queue: .main because every knob they
        // touch is main-thread-owned (as with the settings observers above).
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.inferenceRuntimeController.applyPowerPolicy() }
        powerModeObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.inferenceRuntimeController.applyPowerPolicy() }

        // FR-CE-3: the Context length picker writes CompletionLength.defaultsKey then posts this.
        lengthObserver = NotificationCenter.default.addObserver(
            forName: .shadowtypeCompletionLengthChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.inferenceRuntimeController.applyCompletionLength()
        }

        // FR-LM-1: live model swap. The Models pane posts .shadowtypeSelectModel with the chosen
        // ModelCatalogEntry; download+verify off the main thread, then unload/reload on the inference
        // queue and refresh the menu-bar status. (The legacy file-URL payload is ignored — the catalog
        // entry is the wiring contract.)
        selectModelObserver = NotificationCenter.default.addObserver(
            forName: .shadowtypeSelectModel, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let entry = note.userInfo?["entry"] as? ModelCatalogEntry else { return }
            self.inferenceRuntimeController.swapModel(to: entry)
        }

        // FR-CE-3: own the engine's stop policy here (single owner, per the coordinator's
        // INTEGRATOR-NOTE). Default to the widened multi-word/clause continuation rather than the
        // legacy "first sentence only" fragment; the engine still stops early at maxWords/EOG/newline.
        inferenceRuntimeController.configureCompletion()
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
        // todayCount() applies the local-midnight rollover; the count is informational, never a cap.
        statusItem.setWordCount(wordMeter.todayCount())

        // An API/MCP request counts as activity, exactly like a keystroke: it pushes back the
        // idle-unload window and lazily reloads a model the idle timer already unloaded. Without this
        // the API could neither keep the model alive nor wake it — once unloaded, every request failed
        // at the engine.isLoaded guard until the user physically typed somewhere.
        coordinator.onExternalActivity = { [weak self] in
            self?.inferenceRuntimeController.noteActivityAndReloadIfNeeded()
        }

        // M1: local API server. Started here if the user has flipped the toggle on.
        localAPIRuntimeController.configure(coordinator: coordinator, modelManager: modelManager)
        // Menu / settings toggle.
        localAPIToggleObserver = NotificationCenter.default.addObserver(
            forName: .shadowtypeToggleLocalAPI, object: nil, queue: .main
        ) { [weak self] _ in self?.applyLocalAPIToggle() }
    }

    // Reconcile the running server against the enabled-toggle. Used by the settings toggle + menu toggle.
    func applyLocalAPIToggle() {
        localAPIRuntimeController.applyLocalAPIToggle()
    }

    // Push current server state into the status menu. The Local API is always available (free).
    // Also stashes the live port in UserDefaults so the settings pane can read it (no direct
    // reference from a SwiftUI @State view to the AppDelegate-owned server).
    func refreshLocalAPIMenu() {
        localAPIRuntimeController.refreshLocalAPIMenu()
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
        // Diagnostics may be flipped through UserDefaults while the app is running. Enforce the
        // ephemeral-retention policy immediately instead of leaving prior content on disk.
        Diag.applyRetentionPolicy()
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
        // General → "Suggestion trigger delay" + Context → "Context window size" + the completion-length
        // preset's token ceiling all land through the thermal/Low-Power policy (see applyPowerPolicy).
        inferenceRuntimeController.applyPowerPolicy()
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
        // Models → "Unload model when idle" (minutes; 0 == Never; default 10 matches the picker). The
        // idle timer reads this.
        inferenceRuntimeController.syncIdleUnloadSetting()
        // General → menu-bar presentation (count + icon style). Defaults match the General pane.
        statusItem.setShowWordCount(
            (UserDefaults.standard.object(forKey: "shadowtype.showWordCountInMenuBar") as? Bool) ?? true)
        statusItem.setIconStyle(UserDefaults.standard.string(forKey: "shadowtype.menuBarIconStyle") ?? "mono")
        // About → "Automatically check for updates" / "Include beta builds": (re)schedule the daily
        // update timer to match. No immediate network call here (syncToggles runs on every defaults
        // change); the launch check + manual "Check for Updates…" cover on-demand checking.
        appUpdateCoordinator.scheduleUpdateTimer()
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

    // Warm the KV cache for the focused field, but only once per focus session (FR-CE-8). Called from the
    // app-activation observer AND from contextTracker.onFocusChange — the latter is the only signal for a
    // focus move WITHIN an app, and it also fires on kAXValueChanged (every keystroke), so the sequence
    // guard is what stops a per-keystroke storm of cold prefills on the inference queue.
    private func warmFocusIfFocusChanged() {
        // Also require a resident model: warmFocus() bails on an unloaded engine, and recording the
        // sequence for a warm that never ran would mark this field warmed for the rest of its focus
        // session — the launch case, where the model is still loading when focus first resolves.
        guard enabled, coordinator.isEngineLoaded else { return }
        let seq = contextTracker.focusChangeSequence
        guard seq != lastWarmedFocusSeq else { return }
        lastWarmedFocusSeq = seq
        coordinator.warmFocus()
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
        for obs in [lengthObserver, selectModelObserver, appSettingsObserver, rewriteHotkeyObserver,
                    thermalObserver, powerModeObserver, permissionObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(obs)
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        permissionLifecycle?.shutdown()
        inferenceRuntimeController.shutdown()
        appUpdateCoordinator.shutdown()
        badge.hide()
        tabSwallow.stop()
        inputMonitor.stop()
        contextTracker.stop()
        // The engine has no internal locking: every other unload/load is serialized onto the
        // coordinator's inferenceQueue precisely because freeing the llama context under an in-flight
        // `llama_decode` is a use-after-free. This used to free it straight on MAIN, so quitting
        // mid-suggestion was a crash-on-quit. unloadModelAndWait() cancels the running decode, then
        // performs the unload ON that queue and blocks until it is done (the process is exiting; an
        // async unload would just lose the race).
        coordinator.unloadModelAndWait()
    }

    // MARK: - Accessibility gate (FR-KC-1)

    @discardableResult
    private func ensureAccessibilityTrust() -> Bool {
        let opt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
    }

    @discardableResult
    private func ensureInputMonitoringTrust() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        return CGRequestListenEventAccess()
    }

    private func installPermissionLifecycle() {
        let lifecycle = PermissionLifecycleCoordinator(
            start: { [weak self] in self?.startPermissionPipeline() },
            stop: { [weak self] in self?.stopPermissionPipeline() })
        permissionLifecycle = lifecycle

        permissionObserver = NotificationCenter.default.addObserver(
            forName: .shadowtypeRequiredPermissionsMayHaveChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPermissionLifecycle()
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPermissionLifecycle()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
        refreshPermissionLifecycle()
    }

    private func refreshPermissionLifecycle() {
        let transition = permissionLifecycle?.update(.current) ?? .none
        switch transition {
        case .started:
            Diag.log("permissions: required grants available — pipeline started")
        case .stopped:
            Diag.log("permissions: required grant revoked — pipeline stopped")
        case .none:
            break
        }
    }

    private func startPermissionPipeline() {
        contextTracker.start()
        inputMonitor.start()
        tabSwallow.start()
        updateTabDisableForFrontmost()
        updateRightArrowAcceptForFrontmost()
    }

    private func stopPermissionPipeline() {
        coordinator.cancel()
        tabSwallow.setSuggestionVisible(false)
        badge.hide()
        tabSwallow.stop()
        inputMonitor.stop()
        contextTracker.stop()
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
            self.badgeAvailabilityController.manualMasterToggleDidOccur()
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
                await UpdateManager.shared.checkThenStage(
                    channel: self.appUpdateCoordinator.currentUpdateChannel(),
                    manual: true)
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
                if UpdateManager.shared.isMandatory(manifest) {
                    self.appUpdateCoordinator.presentMandatoryUpdateAlert(manifest)
                }
            }
        }
    }

    // Map the persisted chord choice (General pane picker) onto Carbon keycode+modifiers and
    // (re)register. ⌥⌘K stays the default; alternates exist because it collides with Apple
    // Writing Tools in some first-party apps on macOS 15+.
    private func registerRewriteHotkey() {
        let chord = UserDefaults.standard.string(forKey: "shadowtype.rewriteHotkeyChord") ?? "opt-cmd-k"
        let keyCode: UInt32
        let modifiers: UInt32
        switch chord {
        case "ctrl-cmd-k": keyCode = UInt32(kVK_ANSI_K); modifiers = UInt32(cmdKey | controlKey)
        case "opt-cmd-j":  keyCode = UInt32(kVK_ANSI_J); modifiers = UInt32(cmdKey | optionKey)
        default:           keyCode = UInt32(kVK_ANSI_K); modifiers = UInt32(cmdKey | optionKey)
        }
        if !rewriteHotKey.start(keyCode: keyCode, modifiers: modifiers, id: 2) {
            // Registration failures are otherwise invisible — record for the settings pane.
            UserDefaults.standard.set("Couldn't register the rewrite shortcut (in use by another app).",
                                      forKey: "shadowtype.rewriteHotkey.lastError")
            Diag.log("rewriteHotkey: registration failed for \(chord) (status \(rewriteHotKey.lastStatus))")
        } else {
            UserDefaults.standard.removeObject(forKey: "shadowtype.rewriteHotkey.lastError")
        }
    }

}
