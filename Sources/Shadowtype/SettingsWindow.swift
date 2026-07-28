// Settings window: model selection, hotkeys, per-app enable/disable, etc.
// FR-SET-1: sidebar-driven settings with sections General, Models, Context,
// Apps & Domains, Shortcuts, Personalization, Instructions, Statistics,
// License, About/Updates. FR-SET-2: the only non-latency-critical UI surface.
//
// This pane set is a native-SwiftUI recreation of the app/Settings.html design handoff
// (claude.ai/design). Controls backed by real subsystems are wired live; controls the design
// shows ahead of their backing (all-time/acceptance stats, auto-update channel) persist via
// @AppStorage and/or render as faithful placeholders so the window matches the mock.
// A "Soon" pill is only honest for something we intend to ship: the mock's Quantization picker and
// Speculative-decoding (MTP) toggle were removed outright rather than left disabled, because we
// decided NOT to build them (MTP doubles resident RAM to speed up a 1-4B target that already clears
// the deadline). Advertising a decided-against feature as "Soon" is a promise we would never keep.
import Cocoa
import SwiftUI

// Model-selection notification posted by the Models pane with userInfo["entry"] = ModelCatalogEntry.
// AppDelegate observes it and downloads (if needed) + swaps the active model live on the inference queue.
extension Notification.Name {
    static let shadowtypeSelectModel = Notification.Name("shadowtype.selectModel")
    // Posted by AppDelegate after a live swap finishes; userInfo ["id": String, "ok": Bool] plus
    // an optional ["error": String] failure reason when ok == false.
    // The Models pane clears its download spinner and reverts the picker if the swap failed.
    static let shadowtypeModelDidChange = Notification.Name("shadowtype.modelDidChange")
    // Posted by AppDelegate while a catalog download is in flight; userInfo ["id": String,
    // "fraction": Double] — "fraction" absent while the total size is unknown (indeterminate).
    static let shadowtypeModelDownloadProgress = Notification.Name("shadowtypeModelDownloadProgress")
    // Posted by AppDelegate whenever the inference engine's resident-model state changes (startup
    // load + every live swap); userInfo ["loaded": Bool] plus an optional ["error": String]. The
    // Models pane uses this for the Active-model pill so it reflects the ENGINE, not just file-on-disk
    // — a model can be downloaded yet fail to load (e.g. Metal init failure on new GPU/OS).
    static let shadowtypeEngineLoadStateChanged = Notification.Name("shadowtype.engineLoadStateChanged")
    // Posted by the General pane when the rewrite-hotkey chord (UserDefaults
    // "shadowtype.rewriteHotkeyChord") changes; AppDelegate re-registers the global hotkey.
    static let shadowtypeRewriteHotkeyChanged = Notification.Name("shadowtypeRewriteHotkeyChanged")
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// The settings window when it's on screen, so callers (e.g. the mandatory-update prompt) can attach a
    /// sheet to it instead of racing an app-modal alert behind it. nil when never shown or closed.
    var visibleWindow: NSWindow? { (window?.isVisible == true) ? window : nil }

    func show() {
        if window == nil {
            // Match the onboarding's dark/periwinkle brand: force dark appearance and tint every
            // system control (toggles, sliders, list selection) with the brand accent instead of
            // system blue. Explicit accent usages in the panes use OBTheme.accent too.
            let hosting = NSHostingController(rootView: SettingsRootView().tint(OBTheme.accent))
            let win = NSWindow(contentViewController: hosting)
            win.title = "Shadowtype Settings"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.setContentSize(NSSize(width: 880, height: 660))
            win.contentMinSize = NSSize(width: 720, height: 520)
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: .darkAqua)
            win.backgroundColor = NSColor(OBTheme.win)
            win.delegate = self
            win.center()
            window = win
        }
        // Promote to .regular first so the accessory app actually becomes active and the window
        // can take key/first-responder focus (otherwise text fields won't accept input).
        guard let window else { return }
        AppActivation.shared.promoteAndActivate(for: window)
        window.makeKeyAndOrderFront(nil)
        // The .accessory→.regular promotion activates ASYNCHRONOUSLY: the window above comes up
        // "main" (active titlebar, mouse clicks → toggles work) but NOT "key", so SwiftUI TextFields
        // get no keyboard and can't be typed into. Re-assert key once activation has settled so the
        // field editor attaches. (Symptom without this: "toggle works, can't type".)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }
        AppActivation.shared.windowClosed(closedWindow)
    }
}

// MARK: - Sidebar model

private enum SettingsSection: String, CaseIterable, Identifiable {
    case permissions = "Permissions"
    case general = "General"
    case models = "Models"
    case context = "Context"
    case perApp = "Per-App"
    case shortcuts = "Shortcuts"
    case personalization = "Personalization"
    case instructions = "Instructions"
    case localAPI = "Local API"
    case statistics = "Statistics"
    case about = "About"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .perApp: return "Apps & Domains"
        case .about: return "About & Updates"
        default: return rawValue
        }
    }

    var subtitle: String {
        switch self {
        case .permissions:    return "System access Shadowtype needs to run."
        case .general:        return "Core behavior, triggering, and startup."
        case .models:         return "Your on-device language models and how they run."
        case .context:        return "What Shadowtype reads to make sharper suggestions — all local."
        case .perApp:         return "Where Shadowtype is active, per app and per website."
        case .shortcuts:      return "Keys for accepting, dismissing, and toggling suggestions."
        case .personalization:return "Learn your writing style on-device."
        case .instructions:   return "Steer tone and role globally and per app."
        case .localAPI:       return "Expose your local model to Cursor, Zed, Claude Code, and any OpenAI-compatible tool."
        case .statistics:     return "Your local-only usage dashboard. Nothing is transmitted."
        case .about:          return "Version, updates, and privacy."
        }
    }

    var systemImage: String {
        switch self {
        case .permissions: return "lock.shield"
        case .general: return "gearshape"
        case .models: return "cpu"
        case .context: return "doc.text.magnifyingglass"
        case .perApp: return "square.grid.2x2"
        case .shortcuts: return "keyboard"
        case .personalization: return "person.crop.circle"
        case .instructions: return "text.justify.left"
        case .localAPI: return "network"
        case .statistics: return "chart.bar"
        case .about: return "info.circle"
        }
    }
}

private struct SettingsRootView: View {
    // Open on Permissions when something isn't granted yet, so onboarding lands where it matters.
    @State private var selection: SettingsSection? =
        PermissionsManager.allRequiredGranted() ? .general : .permissions

    private let top: [SettingsSection] = [.permissions, .general, .models, .context, .perApp, .shortcuts,
                                          .personalization, .instructions, .localAPI]
    private let more: [SettingsSection] = [.statistics, .about]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(top) { navRow($0) }
                Section("More") { ForEach(more) { navRow($0) } }
            }
            .navigationSplitViewColumnWidth(min: 196, ideal: 212, max: 260)
            .safeAreaInset(edge: .bottom) { sideFooter }
        } detail: {
            SettingsDetailView(section: selection ?? .general)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder private func navRow(_ section: SettingsSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
    }

    private var sideFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursor.rays")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OBTheme.accent)
                .frame(width: 26, height: 26)
                .background(OBTheme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text("Shadowtype")
                    .font(.caption.weight(.semibold))
                Text("v\(AppInfo.shortVersion) · free & open source")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.bar)
    }
}

private struct SettingsDetailView: View {
    let section: SettingsSection

    var body: some View {
        paneView
    }

    @ViewBuilder private var paneView: some View {
        switch section {
        case .permissions: PermissionsPane()
        case .general: GeneralPane()
        case .models: ModelsPane()
        case .context: ContextPane()
        case .perApp: AppsDomainsPane()
        case .shortcuts: ShortcutsPane()
        case .personalization: PersonalizationPane()
        case .instructions: InstructionsPane()
        case .localAPI: LocalAPISettingsPane()
        case .statistics: StatisticsPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Shared UI

// Shadowtype is free, so there are no paid badges. Kept as an empty stub so the historical
// `if !unlocked { ProBadge() }` call sites (now dead, since `unlocked` is always true) still compile.
private struct ProBadge: View {
    var compact: Bool = false
    var body: some View { EmptyView() }
}

private enum PillKind { case good, warn, neutral }

private struct Pill: View {
    let text: String
    var kind: PillKind = .neutral
    private var tint: Color {
        switch kind {
        case .good: return .green
        case .warn: return .orange
        case .neutral: return .secondary
        }
    }
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

// The privacy reassurance banner the design puts atop the Models / Context panes.
private struct Callout: View {
    let systemImage: String
    let text: LocalizedStringKey
    var tint: Color = .green
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 1)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.22), lineWidth: 1))
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

// Shadowtype is free and open source: every feature is always unlocked.
private enum Entitlement {
    static var isUnlocked: Bool { true }
}

// App version/build, read once from the bundle. Single source for the sidebar footer and About pane.
private enum AppInfo {
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.2"
    }
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1042"
    }
}

// Shared secondary caption used under rows across every pane.
private func caption(_ s: String) -> some View {
    Text(s).font(.caption).foregroundStyle(.secondary)
}

// Trailing "Soon" chip + .disabled() for controls whose backing isn't wired yet, so the UI never
// implies a setting works when it doesn't. Use on the row label.
private struct SoonPill: View {
    var body: some View { Pill(text: "Soon", kind: .neutral) }
}

// Monospace keycap row ("⌥ Tab"), matching the design's <span class="kbd">.
private struct Keycaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { k in
                Text(k)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
            }
        }
    }
}

// MARK: General — engine, startup/menu-bar, typo handling.

private struct GeneralPane: View {
    @State private var unlocked = Entitlement.isUnlocked

    // Mirror the coordinator's enabled state; the menu-bar toggle posts .shadowtypeToggleEnabled.
    @State private var isEnabled = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    // Suggestion trigger delay (real: AppDelegate.syncToggles mirrors this into coordinator.debounce).
    @AppStorage("shadowtype.triggerDelayMs") private var triggerDelayMs = 50.0
    // Aggressiveness — real: AppDelegate.syncToggles mirrors this into coordinator.pauseMultiplier, which
    // scales the adaptive typing-pause threshold. Stored as the Aggressiveness rawValue.
    @AppStorage(Aggressiveness.defaultsKey) private var aggressivenessRaw = Aggressiveness.balanced.rawValue
    // Suggestion length — the SAME engine knob AppDelegate reads, so the control always reflects (and
    // drives) real behavior. Segments map 1:1 to CompletionLength; no separate display store.
    @AppStorage(CompletionLength.defaultsKey) private var lengthRaw = CompletionLength.medium.rawValue
    // Typo handling.
    @AppStorage("GW.autocorrectEnabled") private var autocorrectEnabled = false
    // Live: AppDelegate.syncToggles mirrors these on every UserDefaults change — menu-bar count + icon
    // style into StatusItemController, typo hold-back into the coordinator's fire() gate.
    @AppStorage("shadowtype.showWordCountInMenuBar") private var showWordCount = true
    @AppStorage("shadowtype.menuBarIconStyle") private var iconStyle = "mono"
    @AppStorage("shadowtype.holdBackOnTypos") private var holdBackOnTypos = true
    // Show the one-time "Gmail's Smart Compose is on" coexistence banner. Default ON — once the user
    // dismisses or sees it, the per-session/persisted gate in SmartComposeNudgeStore stops it
    // re-firing; flipping this off skips the AX value read entirely.
    @AppStorage("shadowtype.smartComposeNudge") private var smartComposeNudge = true
    // Real: AppDelegate.syncToggles mirrors this into the active-field badge (default on).
    @AppStorage("shadowtype.showActiveBadge") private var showActiveBadge = true
    @AppStorage("shadowtype.showTabHint") private var showTabHint = true
    // Rewrite-selection hotkey chord. AppDelegate observes .shadowtypeRewriteHotkeyChanged and
    // re-registers the global hotkey when this changes.
    @AppStorage("shadowtype.rewriteHotkeyChord") private var rewriteHotkeyChord = "opt-cmd-k"

    // Reads/writes the real CompletionLength key; all lengths are available.
    private var lengthBinding: Binding<CompletionLength> {
        Binding(
            get: { CompletionLength(rawValue: lengthRaw) ?? .medium },
            set: { newValue in
                guard unlocked || newValue == .medium else { return }   // snaps back via get
                lengthRaw = newValue.rawValue
                NotificationCenter.default.post(name: .shadowtypeCompletionLengthChanged, object: nil)
            }
        )
    }

    // Free, core-UX control (not gated): writing the @AppStorage key triggers AppDelegate.syncToggles live.
    private var aggressivenessBinding: Binding<Aggressiveness> {
        Binding(
            get: { Aggressiveness(rawValue: aggressivenessRaw) ?? .balanced },
            set: { aggressivenessRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Engine") {
                Toggle("Enable Shadowtype", isOn: $isEnabled)
                    .onChange(of: isEnabled) {
                        NotificationCenter.default.post(
                            name: .shadowtypeToggleEnabled, object: nil,
                            userInfo: ["enabled": isEnabled])
                    }
                caption("Master switch for inline suggestions across every app. When off, no completions are computed or shown.")

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Suggestion trigger delay")
                        Spacer()
                        Text("\(Int(triggerDelayMs)) ms")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $triggerDelayMs, in: 40...400, step: 10)
                    caption("The minimum wait after you stop typing before suggesting. Shadowtype adapts the real wait to your typing rhythm above this floor.")
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Aggressiveness", selection: aggressivenessBinding) {
                        ForEach(Aggressiveness.allCases) { a in
                            Text(a.displayName).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)
                    caption("How eagerly to suggest. Shadowtype learns your typing rhythm and waits for a natural pause — Eager fires on a briefer lull, Conservative waits for a clearer one. Calmer settings tend to land more useful suggestions.")
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Suggestion length", selection: lengthBinding) {
                        ForEach(CompletionLength.allCases) { len in
                            Text(len.displayName).tag(len)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("How much to predict at once.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section("Startup & menu bar") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { requested in
                        switch LaunchAtLogin.setEnabled(requested) {
                        case .success:
                            launchAtLogin = LaunchAtLogin.isEnabled
                            launchAtLoginError = nil
                        case .failure(let error):
                            launchAtLogin = LaunchAtLogin.isEnabled
                            launchAtLoginError = "\(error.localizedDescription) Check System Settings → General → Login Items."
                        }
                    }
                ))
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Show today’s word count in menu bar", isOn: $showWordCount)
                caption("Display your accepted-word count beside the menu-bar icon.")
                Picker("Menu-bar icon style", selection: $iconStyle) {
                    Text("Monochrome").tag("mono")
                    Text("Tinted").tag("tinted")
                }
                .pickerStyle(.segmented)
                Toggle("Show active-field indicator", isOn: $showActiveBadge)
                caption("Show a small Shadowtype chip beside whatever text field you're typing in, so you can see at a glance that it's watching.")
                Toggle("Show Tab hint on suggestions", isOn: $showTabHint)
                caption("Show a faint “⇥ Tab” keycap next to the ghost text so you remember the accept key. It fades away on its own once you've accepted a few suggestions.")
            }

            Section("Rewrite") {
                Picker("Rewrite shortcut", selection: $rewriteHotkeyChord) {
                    Text("⌥⌘K (default)").tag("opt-cmd-k")
                    Text("⌃⌘K").tag("ctrl-cmd-k")
                    Text("⌥⌘J").tag("opt-cmd-j")
                }
                .onChange(of: rewriteHotkeyChord) {
                    NotificationCenter.default.post(name: .shadowtypeRewriteHotkeyChanged, object: nil)
                }
                caption("⌥⌘K can conflict with Apple Writing Tools in some apps.")
            }

            Section("Typo handling") {
                Toggle("Hold back suggestions on likely typos", isOn: $holdBackOnTypos)
                caption("Suppress ghost text when the last word looks mistyped, instead of completing nonsense.")
                Toggle("Autocorrect", isOn: $autocorrectEnabled)
                caption("Offer inline corrections of typos and transpositions.")
            }

            Section("Coexistence tips") {
                Toggle("Show Smart Compose coexistence tip", isOn: $smartComposeNudge)
                caption("When Gmail's Smart Compose appears alongside Shadowtype's ghost, show a one-time banner pointing you at Gmail's setting so the two don't clash on Tab.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
        .onReceive(NotificationCenter.default.publisher(for: .shadowtypeToggleEnabled)) { note in
            if let on = note.userInfo?["enabled"] as? Bool { isEnabled = on }
        }
    }
}

// MARK: Models — active model, library, runtime knobs.

private struct ModelsPane: View {
    @AppStorage(ModelManager.selectedModelDefaultsKey) private var selectedID =
        ModelCatalog.entries[0].id
    // Live: AppDelegate.syncToggles drives the idle-unload timer from this key.
    @AppStorage("shadowtype.unloadIdleMinutes") private var unloadIdle = 10

    @State private var unlocked = Entitlement.isUnlocked
    @StateObject private var model = ModelsSettingsModel()

    private var selectedEntry: ModelCatalogEntry {
        model.selectedEntry(for: selectedID)
    }

    // Whether the selected model's file is actually on disk — drives the Active-model pill and
    // gates "Reveal in Finder" (revealing a non-existent file just opens an unrelated folder).
    private var activeModelFileExists: Bool {
        model.modelFileExists(selectedEntry)
    }

    // Derived Active-model state: a download in flight beats everything (apply() only ever starts a
    // download for the model it just selected), then installed vs missing-on-disk.
    @ViewBuilder private var activeModelPill: some View {
        if model.downloading != nil {
            Pill(text: "Downloading…", kind: .warn)
        } else if !activeModelFileExists {
            Pill(text: "Not downloaded", kind: .warn)
        } else if !model.engineLoaded {
            Pill(text: "Failed to load", kind: .warn)
        } else {
            Pill(text: "Loaded", kind: .good)
        }
    }

    var body: some View {
        Form {
            Callout(systemImage: "lock.fill",
                    // "when one is available", not a flat "verified by SHA-256": most catalog entries
                    // ship no pinned hash, so verification depends on Hugging Face returning the LFS
                    // object's digest — and it can legitimately fall back to the GGUF-magic check.
                    text: "**All inference runs on this Mac** via llama.cpp + Metal. Models download once over HTTPS, are checked against the publisher's SHA-256 whenever one is available, and never phone home during completion.")

            if let err = model.downloadError {
                Callout(systemImage: "exclamationmark.triangle.fill",
                        text: LocalizedStringKey(err), tint: .orange)
            }

            if let err = model.engineLoadError {
                Callout(systemImage: "exclamationmark.triangle.fill",
                        text: LocalizedStringKey("This model is on disk but failed to load, so no suggestions will appear: \(err) Full details are in diag.log."),
                        tint: .orange)
            }

            Section("Active model") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(selectedEntry.name).fontWeight(.semibold)
                            activeModelPill
                        }
                        Text(modelSpec(selectedEntry))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            model.modelURL(for: selectedEntry)
                        ])
                    }
                    .controlSize(.small)
                    .disabled(!activeModelFileExists)
                }
                .padding(.vertical, 2)

                Picker("Unload model when idle", selection: $unloadIdle) {
                    Text("5 min").tag(5)
                    Text("10 min").tag(10)
                    Text("30 min").tag(30)
                    Text("Never").tag(0)
                }
                .pickerStyle(.segmented)
                caption("Free the model from memory after inactivity; it reloads on your next keystroke.")
            }

            // "Fits this Mac", NOT "Recommended": ramOK is only a memory gate, and it passes models far
            // too slow to make the coordinator's first-token deadline (a 32 GB Mac clears the 30B MoE).
            // ModelCatalog.recommended() is the single recommendation, and it caps well below the RAM
            // ceiling — labelling this whole list "Recommended" was telling the user to pick the biggest.
            let fits = ModelCatalog.entries.filter(model.fitsPhysicalMemory)
            let other = ModelCatalog.entries.filter { !model.fitsPhysicalMemory($0) }

            if !fits.isEmpty {
                Section {
                    ForEach(fits) { entry in libraryRow(entry) }
                } header: {
                    HStack {
                        Text("Fits this Mac")
                        Spacer()
                        Text(model.freeDisk).font(.caption).foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                } footer: {
                    Text("Bigger isn't better here: suggestions are dropped when the first token misses its deadline, so the recommended model is the best one that still keeps up. Larger entries are for the local API.")
                }
            }

            if !other.isEmpty {
                Section {
                    ForEach(other) { entry in libraryRow(entry) }
                } header: {
                    Text("Other models")
                } footer: {
                    Text("Weights plus KV cache don't fit this Mac's memory budget once macOS and the app you're typing into are accounted for — these may swap, run slowly, or fail to load.")
                }
            }

            // M3 BYOM — Imported models section (Pro). Lists any user-imported GGUFs plus the
            // "Import .gguf…" button. Symlinked into models/imported/ — the user's original file
            // is never copied or modified.
            Section {
                if model.importedEntries.isEmpty {
                    Text("No imported models yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.importedEntries) { entry in
                    importedRow(entry)
                }
                HStack {
                    Button("Import .gguf…") { model.importLocalGGUF() }
                        .disabled(!unlocked)
                    Button("Import from HuggingFace…") { model.hfSheetVisible = true }
                        .disabled(!unlocked)
                    if !unlocked { ProBadgeInline2() }
                    Spacer()
                    if let err = model.importError {
                        Text(err).font(.caption).foregroundStyle(.red)
                            .lineLimit(2).truncationMode(.tail)
                    }
                }
            } header: {
                HStack { Text("Imported"); Spacer() }
            } footer: {
                Text("Any local .gguf is fair game. We symlink it (your original file isn't copied) and verify the GGUF magic bytes before saving the import.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Models")
        .onAppear {
            model.rescan()
            model.reloadImportedEntries()
        }
        .sheet(isPresented: $model.hfSheetVisible) {
            HFImportSheet { newEntry in
                // Switch to the just-imported model so the user sees it become Active without
                // having to find it in the list and click "Switch to".
                model.importedFromHuggingFace(newEntry, selectedID: $selectedID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shadowtypeModelDidChange)) { note in
            model.handleModelDidChange(note, selectedID: $selectedID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shadowtypeModelDownloadProgress)) { note in
            model.handleModelDownloadProgress(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shadowtypeEngineLoadStateChanged)) { note in
            model.handleEngineLoadStateChanged(note)
        }
        .confirmationDialog(
            "Remove \u{201C}\(model.removeCandidate?.name ?? "model")\u{201D}?",
            isPresented: Binding(get: { model.removeCandidate != nil },
                                 set: { if !$0 { model.removeCandidate = nil } }),
            titleVisibility: .visible,
            presenting: model.removeCandidate
        ) { entry in
            Button("Remove", role: .destructive) {
                model.confirmRemove(entry, selectedID: $selectedID)
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            if entry.id == selectedID {
                Text("This model is currently active — suggestions will stop until another model is selected. Shadowtype will switch to \u{201C}\(model.removalFallbackEntry.name)\u{201D} after removal. Your original .gguf file on disk is not deleted.")
            } else {
                Text("This removes the import from Shadowtype. Your original .gguf file on disk is not deleted.")
            }
        }
    }

    // The catalog entry we auto-select after removing the ACTIVE imported model: the one this Mac is
    // actually recommended. It used to take the first RAM-fitting entry, which is the SMALLEST that
    // fits — so removing a BYOM model silently landed the user on the 1B while the rest of the pane
    // badged something else as recommended. Same call as the badge, so the dialog's named model and
    // the recommendation cannot disagree.
    // The single entry ModelCatalog.recommended() would pre-select for this Mac, used to badge one row.
    private var recommendedEntry: ModelCatalogEntry {
        model.recommendedEntry
    }

    @ViewBuilder private func libraryRow(_ entry: ModelCatalogEntry) -> some View {
        let isActive = entry.id == selectedID
        let isInstalled = model.installed.contains(entry.id)
        let ramOK = model.fitsPhysicalMemory(entry)
        HStack(spacing: 10) {
            Image(systemName: "cube.box.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).fontWeight(.medium)
                    if isActive { Pill(text: "Active", kind: .good) }
                    // Marks the ONE entry ModelCatalog.recommended() would pick. The list used to sit
                    // under a "Recommended" section header covering everything that fit RAM, which
                    // read as "take the largest" — the opposite of the deadline-capped recommendation.
                    if entry.id == recommendedEntry.id { Pill(text: "Recommended", kind: .good) }
                    if entry.isInstruct { Pill(text: "Instruct", kind: .warn) }
                }
                Text(libraryDetail(entry, ramOK: ramOK))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.downloading == entry.id {
                if let fraction = model.downloadFraction {
                    ProgressView(value: fraction).frame(width: 90)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if isActive {
                Button("In use") {}.disabled(true).controlSize(.small)
            } else if isInstalled {
                Pill(text: "Downloaded", kind: .good)
                Button("Switch to") { model.apply(to: entry.id, selectedID: $selectedID) }
                    .controlSize(.small)
                    .disabled(model.downloading != nil)   // no mid-download switch race
            } else {
                Text(gb(entry.downloadGB)).font(.caption.monospaced()).foregroundStyle(.secondary)
                Button("Download") { model.apply(to: entry.id, selectedID: $selectedID) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .disabled(model.downloading != nil)   // one download at a time
            }
        }
        .padding(.vertical, 2)
    }

    private func libraryDetail(_ entry: ModelCatalogEntry, ramOK: Bool) -> String {
        var s = "\(gb(entry.downloadGB)) · needs ~\(gb(entry.approxRAMGB)) RAM"
        if !ramOK { s += " · tight on this Mac" }
        // Instruct models end their turn on complete-looking text, so they skip more completions —
        // base models continue more reliably (bug 3). Flag it so a manual pick is informed.
        if entry.isInstruct { s += " · instruct (skips some completions)" }
        return s
    }

    private func modelSpec(_ entry: ModelCatalogEntry) -> String {
        "\(gb(entry.downloadGB)) · ~\(gb(entry.approxRAMGB)) RAM"
    }

    private func gb(_ v: Double) -> String { String(format: "%.1f GB", v) }

    // --- M3 BYOM: import UI + plumbing -------------------------------------------------------

    @ViewBuilder private func importedRow(_ entry: ImportedModelEntry) -> some View {
        let isActive = entry.id == selectedID
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).fontWeight(.medium)
                    if isActive { Pill(text: "Active", kind: .good) }
                }
                Text(importedDetail(entry))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if isActive {
                Button("In use") {}.disabled(true).controlSize(.small)
            } else {
                Button("Switch to") { model.apply(to: entry.id, selectedID: $selectedID) }
                    .controlSize(.small)
                    .disabled(model.downloading != nil)   // no mid-download switch race
            }
            Button("Remove") { model.removeCandidate = entry }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func importedDetail(_ entry: ImportedModelEntry) -> String {
        var s = String(format: "~%.1f GB RAM", entry.approxRAMGB)
        if let orig = entry.originalPath { s += " · \(orig)" }
        return s
    }

}

// Empty stub — Shadowtype is free, so there is no Pro badge. Kept so dead `if !unlocked` call sites
// compile.
private struct ProBadgeInline2: View {
    var body: some View { EmptyView() }
}

// MARK: Context — local context sources + transparency.

private struct ContextPane: View {
    @State private var unlocked = Entitlement.isUnlocked
    @AppStorage("shadowtype.useScreenOCR") private var useScreenOCR = false
    @State private var screenRecordingGranted =
        PermissionsManager.isGranted(.screenRecording)
    @AppStorage("clipboardContextEnabled") private var clipboardContext = false
    // Live: AppDelegate.syncToggles caps engine.maxContextTokens from this key AND derives the
    // coordinator's prompt byte budget from it, so this picker sizes the context blocks too.
    @AppStorage("shadowtype.contextWindowTokens") private var contextTokens = 1024
    private let permissionTick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var effectiveScreenOCR: Binding<Bool> {
        Binding(
            get: { useScreenOCR && screenRecordingGranted },
            set: { useScreenOCR = $0 }
        )
    }

    var body: some View {
        Form {
            Callout(systemImage: "checkmark.shield.fill",
                    text: "**Every context source is processed locally and kept in memory only.** Nothing is written to disk or transmitted. Toggle each one independently.")

            Section {
                LabeledContent("Text before the caret") { Pill(text: "Always on", kind: .good) }
                caption("The window of text you’re currently typing. Always used — it’s how completion works.")

                Toggle("Use screen text for context", isOn: effectiveScreenOCR)
                    .disabled(!screenRecordingGranted)
                caption("Reads what's on screen so suggestions fit the surrounding text — e.g. the email thread you're replying to. In web apps (Gmail, etc.) it reads the page directly via Accessibility (exact, instant, no extra permission); elsewhere it falls back to on-device OCR (needs Screen Recording — see Permissions). Everything stays on your Mac, never stored or sent. Off by default; nothing is captured while off.")
                if useScreenOCR && !screenRecordingGranted {
                    HStack {
                        Label("Screen Recording required", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Permissions") {
                            NSWorkspace.shared.open(Permission.screenRecording.settingsURL)
                        }
                        .controlSize(.small)
                    }
                }

                Toggle(isOn: $clipboardContext) {
                    HStack(spacing: 6) { Text("Clipboard awareness"); if !unlocked { ProBadge() } }
                }
                .disabled(!unlocked)
                caption("Include recent clipboard text as context when relevant. Nothing is stored; the clipboard is read only while this is on.")

                // 3072 is the top usable step: the engine runs a 4096-token context and reserves 256 for
                // generation, so anything above ~3840 is silently clamped. Without it the top half of the
                // window was unreachable from the UI.
                Picker("Context window size", selection: $contextTokens) {
                    Text("512").tag(512)
                    Text("1024").tag(1024)
                    Text("2048").tag(2048)
                    Text("3072").tag(3072)
                }
                .pickerStyle(.segmented)
                caption("How much text to feed the model — the recent text you're typing plus the context sources above. More gives sharper suggestions in long drafts; less is lighter on memory. 3072 is the most the model's window can hold.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Context")
        .onAppear { refreshScreenRecordingPermission() }
        .onReceive(permissionTick) { _ in refreshScreenRecordingPermission() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshScreenRecordingPermission()
            }
    }

    private func refreshScreenRecordingPermission() {
        screenRecordingGranted = PermissionsManager.isGranted(.screenRecording)
    }
}

// MARK: Apps & Domains — per-app + per-domain rules (AppRules-backed where the bundle/domain is known).

private struct AppsDomainsPane: View {
    private let metadataProvider = ApplicationMetadataProvider.shared
    @StateObject private var model = AppScopeSettingsModel()

    // AppRules is the source of truth; these @State mirrors drive native redraw on toggle (no .id()
    // rebuild). `defaultOn` is the per-new-app default; the disabled/enabled sets are the explicit
    // overrides that buck it. All are reloaded from AppRules via refreshRules().
    private typealias Kind = AppScopeSettingsModel.Kind
    private typealias TargetRef = AppScopeSettingsModel.TargetRef

    private struct Target {
        let name: String; let key: String; let glyph: String
        let detail: String; let tone: String?; let warn: Bool
    }
    private let apps: [Target] = [
        .init(name: "Mail",   key: "com.apple.mail",            glyph: "envelope.fill",   detail: "com.apple.mail",            tone: "Formal tone", warn: false),
        .init(name: "Slack",  key: "com.tinyspeck.slackmacgap", glyph: "number",          detail: "com.tinyspeck.slackmacgap", tone: "Casual tone", warn: false),
        .init(name: "Notes",  key: "com.apple.notes",           glyph: "note.text",       detail: "com.apple.notes",           tone: nil,           warn: false),
        .init(name: "Notion", key: "notion.id",                 glyph: "n.square.fill",   detail: "notion.id",                 tone: nil,           warn: false),
        .init(name: "Xcode",  key: "com.apple.dt.Xcode",        glyph: "hammer.fill",     detail: "Text fields only",          tone: nil,           warn: false),
    ]
    private let domains: [Target] = [
        .init(name: "mail.google.com", key: "mail.google.com", glyph: "globe", detail: "Gmail — compose body only; To/Cc/Bcc/Subject left to Gmail's autocomplete", tone: nil, warn: false),
        .init(name: "docs.google.com", key: "docs.google.com", glyph: "globe", detail: "Enable “Accessibility” in Docs menu",   tone: nil, warn: true),
        .init(name: "github.com",      key: "github.com",      glyph: "globe", detail: "Code editor surfaces are skipped",       tone: nil, warn: false),
    ]

    // The sidebar app list = curated seeds + every app the user has touched (an AppRules rule, a
    // per-app instruction, a behavior override, or a session add) + built-in-override apps that are
    // actually installed on this machine. The built-in catalog covers ~hundreds of apps the user
    // doesn't own, so we only surface those when present; user-configured keys always show even if the
    // app is gone. Ordering: enabled (allowed) first, disabled (blocked) last; alphabetical within each.
    private var allAppKeys: [String] {
        // Keys the user has explicitly configured — always visible regardless of install state.
        var configured = Set(apps.map(\.key))
        configured.formUnion(model.disabledApps); configured.formUnion(model.enabledApps)
        configured.formUnion(InstructionStore.shared.allPerApp().keys)
        configured.formUnion(AppSettingsStore.shared.configuredBundleIds())
        configured.formUnion(model.addedApps)
        // Built-in-override apps only join the list when installed.
        let builtInInstalled = BuiltInAppOverrides.table.keys.filter { metadataProvider.isInstalled($0) }
        let s = configured.union(builtInInstalled)
        return s.sorted { a, b in
            let aOff = !AppRules.shared.isEnabled(bundleId: a, domain: nil)
            let bOff = !AppRules.shared.isEnabled(bundleId: b, domain: nil)
            if aOff != bOff { return !aOff }   // allowed before blocked
            return metadataProvider.displayName(a)
                .localizedCaseInsensitiveCompare(metadataProvider.displayName(b)) == .orderedAscending
        }
    }
    private var allDomainKeys: [String] {
        var s = Set(domains.map(\.key))
        s.formUnion(model.disabledDomains)
        s.formUnion(model.enabledDomains)
        s.formUnion(model.addedDomains)
        return s.sorted()
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Apps & Domains")
        .onAppear(perform: model.refreshRules)
        .onReceive(NotificationCenter.default.publisher(for: .shadowtypeAppRulesDidChange)) { _ in
            model.refreshRules()   // reflect a menu-bar "Pause for current app" toggle while this pane is open
        }
    }

    // MARK: Sidebar (apps + domains, real icons, struck-through when off)

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                Section("Apps") {
                    ForEach(allAppKeys, id: \.self) { key in
                        sidebarRow(key: key, kind: .app).tag(TargetRef(kind: .app, key: key))
                    }
                }
                Section("Domains") {
                    ForEach(allDomainKeys, id: \.self) { key in
                        sidebarRow(key: key, kind: .domain).tag(TargetRef(kind: .domain, key: key))
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            addBar
        }
    }

    @ViewBuilder private func sidebarRow(key: String, kind: Kind) -> some View {
        let off = kind == .app ? !AppRules.shared.isEnabled(bundleId: key, domain: nil)
                               : !AppRules.shared.isEnabled(bundleId: nil, domain: key)
        let builtIn = kind == .app ? BuiltInAppOverrides.override(forBundleId: key) : nil
        HStack(spacing: 8) {
            AppIconView(bundleId: kind == .app ? key : nil, isDomain: kind == .domain, size: 18)
            Text(kind == .app ? metadataProvider.displayName(key) : key)
                .strikethrough(off)
                .foregroundStyle(off ? Color.secondary : Color.primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if builtIn != nil {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Add bundle id or domain…", text: $model.addText)
                    .textFieldStyle(.roundedBorder).font(.caption)
                Menu {
                    Button("Add as app") { model.addTarget(isApp: true) }
                    Button("Add as domain") { model.addTarget(isApp: false) }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(model.addText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Domain rules match subdomains too — “google.com” also matches “mail.google.com”.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
    }

    // MARK: Detail (overview when nothing is selected; per-app / per-domain otherwise)

    @ViewBuilder private var detail: some View {
        if let sel = model.selection {
            switch sel.kind {
            case .app:    appDetail(sel.key)
            case .domain: domainDetail(sel.key)
            }
        } else {
            overviewDetail
        }
    }

    @ViewBuilder private func appDetail(_ key: String) -> some View {
        let builtIn = BuiltInAppOverrides.override(forBundleId: key)
        Form {
            if let appSettingsError = model.appSettingsError {
                Callout(
                    systemImage: "exclamationmark.triangle.fill",
                    text: LocalizedStringKey(appSettingsError),
                    tint: .orange
                )
            }
            Section {
                HStack(spacing: 12) {
                    AppIconView(bundleId: key, isDomain: false, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metadataProvider.displayName(key)).font(.title3.weight(.semibold))
                        Text(builtIn != nil ? "Has built-in overrides" : key)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let b = builtIn {
                    Callout(systemImage: "lock.fill", text: LocalizedStringKey(b.reason), tint: OBTheme.accent)
                }
            }

            Section("Completions") {
                triRow("Enable completions",
                       "Turn suggestions on or off in this app.",
                       defaultOn: AppRules.shared.defaultEnabled(forBundleId: key),
                       state: model.appCompletionsBinding(key))
                triRow("Mid-line completions",
                       "Suggest even when there's text after the cursor on the same line.",
                       defaultOn: false,
                       state: model.configBinding(\.midLine, bundleId: key))
                if ActivationPolicy.isTerminal(bundleId: key) {
                    triRow("Shell commands",
                           "Suggest the next shell command at the prompt, drawn from your recent commands. Off by default — shells already have their own completion; ⌃` forces a suggestion either way. Destructive commands (rm -rf /, etc.) are never suggested.",
                           defaultOn: false,
                           state: model.configBinding(\.shellCommands, bundleId: key))
                }
                triRow("Autocorrect",
                       "Offer a fix when the word you're typing looks like a typo.",
                       defaultOn: UserDefaults.standard.bool(forKey: "GW.autocorrectEnabled"),
                       state: model.configBinding(\.autocorrect, bundleId: key))
                triRow("Disable Tab key",
                       "Stop Tab from accepting completions, for apps where Tab has native use.",
                       defaultOn: false,
                       state: model.configBinding(\.disableTab, bundleId: key))
                triRow("Accept with Right Arrow",
                       "Accept the next word with Right Arrow at end-of-line, in addition to Tab.",
                       defaultOn: (UserDefaults.standard.object(forKey: "shadowtype.acceptOnRightArrow") as? Bool) ?? true,
                       state: model.configBinding(\.rightArrowAccept, bundleId: key))
            }

            Section("Custom instructions") {
                TextField("Additional instructions for the AI in this app…",
                          text: model.instructionBinding(key), axis: .vertical)
                    .lineLimit(3...8)
                caption("Overrides the global instructions from Personalization for this app.")
            }

            Section("Typing history") {
                triRow("Collect inputs for personalization",
                       "Learn your writing style from accepted text in this app. Stays on this Mac.",
                       defaultOn: collectInputsGlobalDefault,
                       state: model.configBinding(\.collectInputs, bundleId: key))
                let count = { () -> Int in
                    _ = model.detailTick
                    return StyleProfile.shared.inputCount(forBundleId: key)
                }()
                HStack {
                    Text("Collected inputs")
                    Spacer()
                    Text("\(count) input\(count == 1 ? "" : "s") collected")
                        .foregroundStyle(.secondary)
                    Button("Delete…") {
                        StyleProfile.shared.deleteApp(bundleId: key)
                        model.refreshDetail()
                    }
                    .controlSize(.small)
                    .disabled(count == 0)
                }
            }
        }
        .formStyle(.grouped)
        .id(key)   // reset field editors when switching apps
    }

    @ViewBuilder private func domainDetail(_ key: String) -> some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AppIconView(bundleId: nil, isDomain: true, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key).font(.title3.weight(.semibold))
                        Text("Browser domain").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            Section("Completions") {
                triRow("Enable completions",
                       "Turn suggestions on or off on this website.",
                       defaultOn: AppRules.shared.defaultEnabled(),
                       state: model.domainCompletionsBinding(key))
            }
        }
        .formStyle(.grouped)
        .id(key)
    }

    @ViewBuilder private var overviewDetail: some View {
        Form {
            Section {
                Picker(selection: $model.defaultOn) {
                    Text("On").tag(true)
                    Text("Off").tag(false)
                } label: {
                    Text("Default behavior in new apps")
                }
                .pickerStyle(.segmented)
                .onChange(of: model.defaultOn) {
                    model.setDefaultEnabled(model.defaultOn)
                }
                caption("Whether Shadowtype is on by default in apps you haven’t configured.")

                LabeledContent("Never suggest in password fields") {
                    Toggle("", isOn: .constant(true)).labelsHidden().disabled(true)
                }
                caption("Secure text fields are always skipped. This can’t be turned off.")
            } header: {
                Text("Select an app or domain on the left to configure it.")
            }

            // Cotypist-style compatibility map: most apps just work; a few need a one-time nudge; some
            // can't be supported because they draw their own text (no accessible field to read).
            Section("Works out of the box") {
                ForEach(supportedApps, id: \.self) { name in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 20)
                        Text(name)
                        Spacer()
                        Pill(text: "Supported", kind: .good)
                    }
                    .padding(.vertical, 1)
                }
            }

            Section("Needs one-time setup") {
                setupRow("doc.text", "Google Docs",
                         "Tools ▸ Accessibility ▸ turn on screen-reader support, so Docs exposes the document.")
                launchCommandRow("Arc", "open -a 'Arc' --args --force-renderer-accessibility=complete")
                launchCommandRow("Dia", "open -a 'Dia' --args --force-renderer-accessibility=complete")
                setupRow("chevron.left.forwardslash.chevron.right", "VS Code · Cursor · Windsurf",
                         "Completions appear in the sidebar AI chat, not the code editor. Press ⌃` to force them anywhere.")
                setupRow("terminal", "Terminal · iTerm",
                         "Auto-on inside an AI agent prompt (Claude Code, Codex, Cursor Agent). For plain commands press ⌃`.")
            }

            Section {
                ForEach(unsupportedApps, id: \.name) { app in
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle").foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).foregroundStyle(.secondary)
                            Text(app.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 1)
                }
            } header: {
                Text("Not supported")
            } footer: {
                Text("These apps render their own text, so macOS can't expose it to Shadowtype — there's no setting on our end that changes this.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Tri-state rows + bindings

    private var collectInputsGlobalDefault: Bool {
        UserDefaults.standard.object(forKey: "styleProfileEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "styleProfileEnabled")
    }

    @ViewBuilder private func triRow(_ title: String, _ desc: String,
                                     defaultOn: Bool, state: Binding<TriState>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                TriStatePicker(defaultOn: defaultOn, state: state)
            }
            caption(desc)
        }
        .padding(.vertical, 1)
    }

    // Compatibility map (Cotypist parity). Curated, illustrative — not exhaustive.
    private let supportedApps = ["Mail", "Notes", "Slack", "Notion", "Safari & Chrome", "TextEdit", "Messages"]
    private let unsupportedApps: [(name: String, reason: String)] = [
        ("Pages", "Custom text rendering"),
        ("Scrivener", "Custom text rendering"),
        ("Sublime Text", "Custom text rendering"),
        ("BBEdit", "Custom text rendering"),
        ("Ghostty · Warp", "Terminals that draw their own text"),
    ]

    // A one-time-setup row with an explanatory caption.
    @ViewBuilder private func setupRow(_ glyph: String, _ name: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Pill(text: "Setup needed", kind: .warn)
        }
        .padding(.vertical, 1)
    }

    // A Chromium browser row whose launch flag is copy-pasteable (no need to memorize it).
    @ViewBuilder private func launchCommandRow(_ name: String, _ command: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "globe").frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).fontWeight(.medium)
                Text(command).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Copy command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .padding(.vertical, 1)
    }

}

// MARK: App metadata + reusable per-app controls

// Real app icon (or a globe / dashed-app fallback), sized for both the sidebar and the detail header.
private struct AppIconView: View {
    private let metadataProvider = ApplicationMetadataProvider.shared
    let bundleId: String?
    var isDomain: Bool = false
    var size: CGFloat = 20
    var body: some View {
        if let id = bundleId, let img = metadataProvider.icon(id) {
            Image(nsImage: img).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: isDomain ? "globe" : "app.dashed")
                .resizable().scaledToFit()
                .frame(width: size * 0.84, height: size * 0.84)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

// Cotypist-style "Default (on/off) · On · Off" menu picker driving a TriState binding.
private struct TriStatePicker: View {
    let defaultOn: Bool
    @Binding var state: TriState
    var body: some View {
        Picker("", selection: $state) {
            Text("Default (\(defaultOn ? "on" : "off"))").tag(TriState.auto)
            Text("On").tag(TriState.on)
            Text("Off").tag(TriState.off)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

// MARK: Shortcuts — fixed accept/dismiss keys + behavior toggles.

private struct ShortcutsPane: View {
    @AppStorage("shadowtype.swallowTab") private var swallowTab = true
    @AppStorage("shadowtype.acceptOnRightArrow") private var acceptOnRightArrow = true
    @AppStorage("shadowtype.emojiShortcode") private var emojiShortcode = true
    @AppStorage("shadowtype.rewriteEnabled") private var rewriteEnabled = true

    @AppStorage("shadowtype.rewriteHotkeyChord") private var rewriteChord = "opt-cmd-k"

    private struct Shortcut: Identifiable {
        let id = UUID(); let action: String; let note: String; let keys: [String]?
    }
    // Keycap symbols for the configurable rewrite chord (General pane picker).
    private var rewriteChordKeys: [String] {
        switch rewriteChord {
        case "ctrl-cmd-k": return ["⌃", "⌘", "K"]
        case "opt-cmd-j":  return ["⌥", "⌘", "J"]
        default:           return ["⌥", "⌘", "K"]
        }
    }
    private var rewriteChordLabel: String { rewriteChordKeys.joined() }

    private var shortcuts: [Shortcut] { staticShortcuts(rewriteKeys: rewriteChordKeys) }
    private func staticShortcuts(rewriteKeys: [String]) -> [Shortcut] { [
        .init(action: "Accept next word", note: "Take one word from the current suggestion. Right Arrow also works at end-of-line when enabled.", keys: ["Tab"]),
        .init(action: "Accept whole line", note: "Take the entire suggested line at once.", keys: ["⌥", "Tab"]),
        .init(action: "Dismiss suggestion", note: "Hide the current ghost text. Typing also dismisses.", keys: ["esc"]),
        .init(action: "Force suggestions here", note: "Turn completions on in the current field, even where Shadowtype stays idle (terminals, code editors).", keys: ["⌃", "`"]),
        .init(action: "Rewrite selection", note: "Rewrite the selected text on-device — improve, shorten, change tone, fix grammar, or summarize. Preview before keeping.", keys: rewriteKeys),
        .init(action: "Pause for current app", note: "Temporarily disable in the frontmost app.", keys: ["⌃", "⌥", "P"]),
    ] }

    var body: some View {
        Form {
            Section {
                ForEach(shortcuts) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.action)
                            Text(s.note).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let keys = s.keys { Keycaps(keys: keys) }
                        else { SoonPill() }
                    }
                    .padding(.vertical, 1)
                }
            } footer: {
                Text("Accept and dismiss keys are fixed; the rewrite shortcut is configurable in General.")
            }

            Section {
                Toggle("Swallow Tab when a suggestion is showing", isOn: $swallowTab)
                caption("Prevents the literal Tab from also reaching the app while accepting. Off lets Tab pass through to the app even when a ghost is visible.")
                Toggle("Also accept with Right Arrow", isOn: $acceptOnRightArrow)
                caption("Accept the next word with Right Arrow when the caret is at end-of-line. Matches Smart Compose and Superhuman. Cursor motion still wins mid-line or with any modifier held.")
                Toggle("Emoji shortcode", isOn: $emojiShortcode)
                caption("Type “:” then a name to insert emoji. Turn off to disable the trigger entirely.")
                Toggle("Selection rewrite (\(rewriteChordLabel))", isOn: $rewriteEnabled)
                caption("Rewrite selected text on-device with a local model. Off disables the \(rewriteChordLabel) hotkey. Change the shortcut in General.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }
}

// MARK: Personalization — writing-style profile (FR-CTX-3).

private struct PersonalizationPane: View {
    @AppStorage("styleProfileEnabled") private var learnOn = true
    // Live: AppDelegate.syncToggles mirrors this into the coordinator, which scales the style-hint
    // budget prepended to the prompt (0 = off).
    @AppStorage("shadowtype.personalizationStrength") private var strength = 3
    @State private var phrases = 0
    @State private var sizeText = "Empty"
    @State private var wipeConfirmVisible = false

    private static let strengthLabels = ["Off", "Light", "Medium", "Strong"]

    var body: some View {
        Form {
            Callout(systemImage: "sparkles",
                    text: "Shadowtype learns your phrasing locally to bias suggestions toward how you actually write. The profile is encrypted on this Mac and never leaves it.",
                    tint: OBTheme.accent)

            Section {
                Toggle(isOn: $learnOn) {
                    Text("Learn my writing style")
                }
                caption("Build a local profile from your accepted phrasings and typing patterns.")

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Personalization strength")
                        Spacer()
                        Text(Self.strengthLabels[min(max(strength, 0), 3)])
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { Double(strength) }, set: { strength = Int($0) }),
                           in: 0...3, step: 1)
                    caption("How strongly to bias toward your style versus the base model. Off ignores your profile even while learning stays on.")
                }
                .padding(.vertical, 2)
            } header: {
                Text("Personalization")
            }

            Section("Your profile") {
                LabeledContent("Learned patterns") {
                    Text("\(phrases)").monospacedDigit().foregroundStyle(OBTheme.accent).fontWeight(.semibold)
                }
                LabeledContent("Profile storage", value: sizeText)
                Button("Wipe my profile", role: .destructive) {
                    wipeConfirmVisible = true
                }
                .confirmationDialog("Wipe your writing-style profile?",
                                    isPresented: $wipeConfirmVisible, titleVisibility: .visible) {
                    Button("Wipe Profile", role: .destructive) {
                        StyleProfile.shared.wipe()
                        refresh()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently deletes everything Shadowtype has learned about your writing style on this Mac. It can’t be undone.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Personalization")
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let s = StyleProfile.shared.profileStats()
        phrases = s.phrases
        sizeText = s.sizeBytes <= 0
            ? "Empty"
            : ByteCountFormatter.string(fromByteCount: Int64(s.sizeBytes), countStyle: .file)
    }
}

// MARK: Instructions — global + per-app custom instructions (FR-PA-3).

private struct InstructionsPane: View {
    @State private var global = ""
    @State private var perApp: [String: String] = [:]
    @State private var newBundleId = ""
    @State private var newInstruction = ""
    @State private var resetFlash = false   // brief "Reset to default." confirmation flash

    private var sortedBundleIds: [String] { perApp.keys.sorted() }
    private var trimmedNewBundleId: String {
        newBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Callout(systemImage: "text.justify.left",
                    text: "Steer tone, audience, and role globally, then override it per app. These instructions are prepended locally to every prompt.",
                    tint: OBTheme.accent)

            Section {
                caption("Customize how Shadowtype completes your text. Focus on info relevant to your writing — your occupation, the languages you write in, and the kinds of writing you do. A few hundred words is plenty; shorter works just as well.")
                TextField("Custom AI Instructions", text: $global,
                          prompt: Text("My name is …\nI usually write in English and Spanish.\nWrite in a friendly, professional voice — short, concise and readable."),
                          axis: .vertical)
                    .labelsHidden()
                    .lineLimit(6...14)
                    .onChange(of: global) { InstructionStore.shared.setGlobalInstruction(global) }
            } header: {
                HStack {
                    Text("Custom AI Instructions")
                    Spacer()
                    if resetFlash {
                        Text("Reset to default.")
                            .font(.caption).foregroundStyle(.secondary)
                            .textCase(nil)
                            .transition(.opacity)
                    }
                    Button("Reset to Default") {
                        InstructionStore.shared.resetGlobalToDefault()
                        refresh()
                        resetFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { resetFlash = false }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            } footer: {
                Text("Applied to every completion in every app unless an app overrides it. Prepended locally to every prompt — never sent anywhere.")
            }

            Section("Per-app overrides") {
                if perApp.isEmpty {
                    Text("No per-app overrides.").foregroundStyle(.secondary)
                } else {
                    ForEach(sortedBundleIds, id: \.self) { bundleId in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(bundleId).font(.system(.body, design: .monospaced))
                                Spacer()
                                Button(role: .destructive) {
                                    InstructionStore.shared.setInstruction(nil, forBundleId: bundleId)
                                    refresh()
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                            }
                            TextField("Instruction", text: bindingFor(bundleId),
                                      prompt: Text("Instruction for this app"), axis: .vertical)
                                .labelsHidden()
                                .lineLimit(2...5)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Add override") {
                TextField("App bundle id", text: $newBundleId,
                          prompt: Text("App bundle id (e.g. com.tinyspeck.slackmacgap)"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                if !trimmedNewBundleId.isEmpty && !BundleIDValidator.isValid(trimmedNewBundleId) {
                    Text("Not a valid bundle id — use at least two dot-separated parts of letters, digits, or hyphens (e.g. com.apple.mail).")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Instruction for that app", text: $newInstruction,
                          prompt: Text("Instruction for that app"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...5)
                Button("Add override") {
                    let bid = trimmedNewBundleId
                    guard BundleIDValidator.isValid(bid) else { return }
                    InstructionStore.shared.setInstruction(newInstruction, forBundleId: bid)
                    newBundleId = ""; newInstruction = ""
                    refresh()
                }
                .disabled(!BundleIDValidator.isValid(trimmedNewBundleId))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Instructions")
        .onAppear(perform: refresh)
    }

    private func refresh() {
        global = InstructionStore.shared.globalInstruction()
        perApp = InstructionStore.shared.allPerApp()
    }

    private func bindingFor(_ bundleId: String) -> Binding<String> {
        Binding(
            get: { perApp[bundleId] ?? "" },
            set: { newValue in
                perApp[bundleId] = newValue
                InstructionStore.shared.setInstruction(newValue, forBundleId: bundleId)
            }
        )
    }
}

// Pure bundle-id shape check for the "Add override" field. Internal (not private) so unit tests
// can exercise it directly. Deliberately ASCII-strict: real CFBundleIdentifiers are reverse-DNS
// of ASCII letters/digits/hyphens — anything else is almost certainly a typo in this field.
enum BundleIDValidator {
    /// True when `raw` (whitespace-trimmed) has ≥2 dot-separated components, each non-empty and
    /// containing only ASCII letters, digits, or hyphens.
    static func isValid(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.components(separatedBy: ".")
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                    || ("0"..."9").contains($0) || $0 == "-"
            }
        }
    }
}

// MARK: Statistics — local-only dashboard (FR-ST-1). No transmission.

private struct StatisticsPane: View {
    @State private var todayWords = 0
    @State private var allTimeWords = 0
    @State private var acceptance: Double? = nil
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                // All figures are backed by WordMeter's local-only counters (never transmitted).
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                    statCard("\(todayWords)", "Words accepted today", OBTheme.accent)
                    statCard(allTimeWords > 0 ? "\(allTimeWords)" : "—", "All-time accepted", .primary)
                    // "Est. time saved" stays "—": unlike the other cards it isn't a measured count, and
                    // fabricating a savings figure would sit badly next to the "not analytics" promise.
                    statCard("—", "Est. time saved", .green)
                    statCard(acceptance.map { String(format: "%.0f%%", $0 * 100) } ?? "—", "Acceptance rate", OBTheme.accent)
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                Text("Acceptance rate is the share of shown suggestions you accepted — the best single signal of how useful suggestions feel. If it's low, try a calmer Aggressiveness in General. All statistics are stored locally and never transmitted; this is a private dashboard, not analytics. Per-app breakdowns arrive in a later build.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Statistics")
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        todayWords = WordMeter.shared.todayCount()
        allTimeWords = WordMeter.shared.allTimeWordCount()
        acceptance = WordMeter.shared.acceptanceRate()
    }

    private func statCard(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(tint).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
    }
}

// MARK: About & Updates.

private struct AboutPane: View {
    // Wired to UpdateManager: autoCheck gates the launch + daily check (AppDelegate.scheduleUpdateTimer
    // observes the UserDefaults change), includeBeta selects the channel. @AppStorage writes post
    // UserDefaults.didChangeNotification, so flipping these reschedules the timer with no extra plumbing.
    @AppStorage("shadowtype.autoCheckUpdates") private var autoCheck = true
    @AppStorage("shadowtype.includeBetaBuilds") private var includeBeta = true
    @ObservedObject private var updater = UpdateManager.shared

    private var version: String {
        let channel = includeBeta ? " (beta channel)" : ""
        return "Version \(AppInfo.shortVersion)\(channel) · build \(AppInfo.buildNumber)"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "cursor.rays")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(OBTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shadowtype").font(.title3.weight(.bold))
                        Text(version).font(.caption).foregroundStyle(.secondary)
                        Text("macOS 14+ · Apple Silicon · © 2026 Shadowtype")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $autoCheck)
                Toggle("Include beta builds", isOn: $includeBeta)

                LabeledContent("Status") { updateStatusView }

                HStack {
                    Button("Check for Updates…") {
                        let channel: UpdateChannel = includeBeta ? .beta : .stable
                        Task { await updater.checkThenStage(channel: channel, manual: true) }
                    }
                    .disabled(isUpdateBusy)
                    if case .readyToInstall = updater.state {
                        Button("Install & Relaunch") { updater.installAndRelaunch() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                caption("Updates are downloaded from GitHub Releases, verified by SHA-256 checksum and code signature before they install. The app replaces itself and relaunches.")
            }

            Section("Privacy & data") {
                LabeledContent("Network activity") { Pill(text: "0 inference calls", kind: .good) }
                caption("The only outbound calls are model downloads and the optional update check (GitHub Releases). Completion never touches the network.")
                LabeledContent("Telemetry") { Pill(text: "Disabled by design", kind: .good) }
                caption("There is none. No analytics backend, ever.")
            }

            Section {
                Button("Open help & documentation") {
                    if let url = URL(string: "https://github.com/dario-valles/shadowtype") { NSWorkspace.shared.open(url) }
                }
                LabeledContent("Licenses & acknowledgements", value: "llama.cpp · Gemma · CryptoKit")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About & Updates")
    }

    // True while a check/download is in flight — disables the manual "Check for Updates…" button.
    private var isUpdateBusy: Bool {
        switch updater.state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    @ViewBuilder private var updateStatusView: some View {
        switch updater.state {
        case .idle:
            Pill(text: "Up to date", kind: .good)
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").font(.caption) }
        case .upToDate:
            Pill(text: "Up to date", kind: .good)
        case .available(let m):
            Pill(text: "Update available — v\(m.version)", kind: .neutral)
        case .downloading(let p):
            HStack(spacing: 8) {
                if let p { ProgressView(value: p).frame(width: 120) } else { ProgressView().controlSize(.small) }
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        case .readyToInstall(let m):
            Pill(text: "Ready to install — v\(m.version)", kind: .good)
        case .failed(let msg):
            // Show the actual failure reason (a pill truncates poorly for long messages) plus a
            // one-click retry of the same check/stage flow the manual button runs.
            VStack(alignment: .trailing, spacing: 4) {
                Text(msg)
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
                Button("Try again") {
                    let channel: UpdateChannel = includeBeta ? .beta : .stable
                    Task { await updater.checkThenStage(channel: channel, manual: true) }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Permissions (PRD §8.1 guided onboarding / FR-KC-1)

private struct PermissionsPane: View {
    @StateObject private var mgr = PermissionsManager()
    // Re-poll while the pane is visible so flipping a switch in System Settings reflects here.
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Text("Shadowtype needs system permissions to read the focused field and observe the accept key. It can’t enable these for you — flip the switch in System Settings, then return here. Shadowtype detects the change automatically.")
                    .foregroundStyle(.secondary)
            }

            Section("Required") {
                ForEach(Permission.allCases.filter { $0.required }) { row($0) }
            }
            Section("Optional") {
                ForEach(Permission.allCases.filter { !$0.required }) { row($0) }
            }

            Section {
                HStack {
                    Button("Re-check") { mgr.refresh() }
                    Spacer()
                    Button("Quit & Relaunch") { mgr.relaunch() }
                        .help("Restart Shadowtype if a granted permission still is not taking effect.")
                }
                if let relaunchError = mgr.relaunchError {
                    Text(relaunchError).font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text(mgr.granted.filter { $0.key.required && !$0.value }.isEmpty
                     ? "All required permissions granted."
                     : "Grant both required permissions; Shadowtype will start automatically.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
        .onAppear { mgr.refresh() }
        .onReceive(tick) { _ in mgr.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in mgr.refresh() }
    }

    @ViewBuilder private func row(_ p: Permission) -> some View {
        let ok = mgr.granted[p] ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(p.title).font(.headline)
                Spacer()
                Text(ok ? "Granted" : "Not granted")
                    .font(.subheadline)
                    .foregroundStyle(ok ? .green : .secondary)
            }
            Text(p.why).font(.caption).foregroundStyle(.secondary)
            if !ok {
                HStack {
                    Button("Request Access…") { mgr.request(p) }
                    Button("Open System Settings") { mgr.openSettings(p) }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }
}
