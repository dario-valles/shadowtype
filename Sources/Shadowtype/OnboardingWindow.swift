// First-run onboarding window (PRD §9 onboarding / FR-KC-1).
//
// A native-SwiftUI recreation of the app/Onboarding.html design handoff (claude.ai/design): a six-step
// first-run flow — Welcome → How it works → Permissions → Language model → Try it → All set — with the
// design's dark periwinkle/violet brand chrome (left progress rail + right stage + footer nav).
//
// Unlike a static mock, the steps that touch real subsystems are wired live:
//   • Permissions reuses the same PermissionsManager the Settings → Permissions pane uses, and gates
//     "Continue" until both required grants land.
//   • Language model downloads the best free model for this Mac via ModelManager (real progress), then
//     posts .shadowtypeSelectModel so AppDelegate swaps it in live.
//   • All set wires Launch-at-login (LaunchAtLogin) + the menu-bar word-count toggle (@AppStorage).
// The "Try it" step is a self-contained ghost-text demo (a local sim — it intentionally does NOT touch
// the real WordMeter, so practicing in onboarding stays isolated from real usage tracking).
import Cocoa
import SwiftUI

// MARK: - Window controller

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let didCompleteKey = "shadowtype.didCompleteOnboarding"

    private var window: NSWindow?

    /// True until the user finishes (or has previously finished) the first-run flow.
    static var shouldShowOnFirstRun: Bool {
        !UserDefaults.standard.bool(forKey: didCompleteKey)
    }

    func show() {
        if window == nil {
            let root = OnboardingRootView { [weak self] in self?.finish() }
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Welcome to Shadowtype"
            // Match the design's integrated dark titlebar: transparent bar, hidden title, content runs
            // full height under the traffic lights (the rail draws its own brand lockup up there).
            win.styleMask = [.titled, .closable, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.appearance = NSAppearance(named: .darkAqua)
            win.backgroundColor = NSColor(OBTheme.win)
            win.setContentSize(NSSize(width: 880, height: 632))
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.center()
            window = win
        }
        // Same accessory-app activation fix as Settings: promote to .regular so the window is
        // active and its controls accept input, then demote on close (windowWillClose). The promotion
        // activates asynchronously, so re-assert key on the next runloop or text fields stay unfocusable.
        AppActivation.shared.promoteAndActivate()
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        AppActivation.shared.windowClosed()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.didCompleteKey)
        window?.close()
    }
}

// MARK: - Design tokens (from app/app.css)

private func ob(_ hex: UInt, _ a: Double = 1) -> Color {
    Color(.sRGB,
          red: Double((hex >> 16) & 0xff) / 255,
          green: Double((hex >> 8) & 0xff) / 255,
          blue: Double(hex & 0xff) / 255,
          opacity: a)
}

enum OBTheme {
    static let win        = ob(0x16181f)
    static let card       = ob(0x1d212c)
    static let card2      = ob(0x232734)
    static let field      = ob(0x0e1014)
    static let line       = ob(0x2a2f3b)
    static let lineSoft   = ob(0x20242e)
    static let lineStrong = ob(0x363c4a)

    static let text       = ob(0xe8eaf0)
    static let textDim    = ob(0xa3a9b8)
    static let textFaint  = ob(0x6c7283)
    static let ghost      = ob(0x5a6076)

    static let accent       = ob(0x7c9cff)
    static let accentBright  = ob(0xa6bcff)
    static let violet        = ob(0x8466ff)
    static let violetBright  = ob(0xa78bff)
    static let good          = ob(0x5ee0a0)
    static let warn          = ob(0xffcf6e)
}

// MARK: - Steps

private enum OBStep: Int, CaseIterable {
    case welcome, howItWorks, permissions, model, tryIt, selectionRewrite, personalize, done

    var railTitle: String {
        switch self {
        case .welcome:         return "Welcome"
        case .howItWorks:      return "How it works"
        case .permissions:     return "Permissions"
        case .model:           return "Language model"
        case .tryIt:           return "Try it out"
        case .selectionRewrite: return "Selection rewrite"
        case .personalize:     return "Make it yours"
        case .done:            return "All set"
        }
    }

    var nextLabel: String {
        switch self {
        case .welcome: return "Get started"
        case .done:    return "Finish setup"
        default:       return "Continue"
        }
    }
}

// MARK: - Root

private struct OnboardingRootView: View {
    let onFinish: () -> Void

    @State private var step: OBStep = .welcome
    @StateObject private var perms = PermissionsManager()
    private let permTick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var requiredGranted: Bool {
        (perms.granted[.accessibility] ?? false) && (perms.granted[.inputMonitoring] ?? false)
    }
    private var nextDisabled: Bool { step == .permissions && !requiredGranted }

    var body: some View {
        HStack(spacing: 0) {
            OBRail(current: step) { tapped in
                // Match the mock: you can jump back, or one step forward.
                if tapped.rawValue <= step.rawValue || tapped.rawValue == step.rawValue + 1 {
                    withAnimation(.easeOut(duration: 0.28)) { step = tapped }
                }
            }
            .frame(width: 244)

            VStack(spacing: 0) {
                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .background(OBTheme.win)
        }
        .frame(width: 880, height: 632)
        .background(OBTheme.win)
        .onReceive(permTick) { _ in if step == .permissions { perms.refresh() } }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in perms.refresh() }
    }

    @ViewBuilder private var stage: some View {
        ScrollView {
            Group {
                switch step {
                case .welcome:     OBWelcome()
                case .howItWorks:  OBHowItWorks()
                case .permissions: OBPermissions(perms: perms)
                case .model:       OBModelStep()
                case .tryIt:       OBTryIt()
                case .selectionRewrite: OBSelectionRewrite()
                case .personalize: OBPersonalize()
                case .done:        OBDone()
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 44)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
            .id(step)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Back") { withAnimation(.easeOut(duration: 0.28)) { go(-1) } }
                .buttonStyle(OBGhostButton())
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)

            OBDots(current: step.rawValue, total: OBStep.allCases.count)

            Spacer()

            Button(step.nextLabel) {
                if step == .done { onFinish() }
                else { withAnimation(.easeOut(duration: 0.28)) { go(1) } }
            }
            .buttonStyle(OBPrimaryButton(large: true))
            .disabled(nextDisabled)
            .help(nextDisabled ? "Grant the two required permissions to continue" : "")
        }
        .padding(.horizontal, 30)
        .frame(height: 72)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(OBTheme.lineSoft), alignment: .top)
    }

    private func go(_ dir: Int) {
        let n = step.rawValue + dir
        guard let next = OBStep(rawValue: n) else { return }
        step = next
    }
}

// MARK: - Left progress rail

private struct OBRail: View {
    let current: OBStep
    let onTap: (OBStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand lockup (sits below the transparent titlebar's traffic lights).
            HStack(spacing: 11) {
                Image(systemName: "cursor.rays")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(OBTheme.violetBright)
                    .shadow(color: OBTheme.violet.opacity(0.5), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shadowtype").font(.system(size: 16, weight: .bold)).foregroundStyle(OBTheme.text)
                    Text("FIRST RUN")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(OBTheme.accentBright)
                }
            }
            .padding(.top, 30)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(OBStep.allCases, id: \.self) { s in
                    railItem(s)
                }
            }
            .padding(.top, 36)

            Spacer()

            // Privacy reassurance foot.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(OBTheme.good)
                    Text("100% on-device").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(OBTheme.textDim)
                }
                Text("Your keystrokes never leave this Mac. No account, no cloud, no telemetry.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(OBTheme.textFaint)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(colors: [ob(0x15131f), ob(0x101019), ob(0x0e0f17)],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(Rectangle().frame(width: 1).foregroundStyle(OBTheme.lineSoft), alignment: .trailing)
    }

    @ViewBuilder private func railItem(_ s: OBStep) -> some View {
        let isActive = s == current
        let isDone = s.rawValue < current.rawValue
        HStack(spacing: 12) {
            dot(s, isActive: isActive, isDone: isDone)
            Text(s.railTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? OBTheme.text : (isDone ? OBTheme.textDim : OBTheme.textFaint))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(isActive ? Color.white.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { onTap(s) }
    }

    @ViewBuilder private func dot(_ s: OBStep, isActive: Bool, isDone: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isActive
                      ? AnyShapeStyle(LinearGradient(colors: [OBTheme.accentBright, OBTheme.accent],
                                                     startPoint: .top, endPoint: .bottom))
                      : (isDone ? AnyShapeStyle(OBTheme.good.opacity(0.14)) : AnyShapeStyle(OBTheme.field)))
            Circle()
                .stroke(isActive ? OBTheme.accent : (isDone ? OBTheme.good : OBTheme.lineStrong), lineWidth: 1.5)
            if isActive { Circle().stroke(OBTheme.accent.opacity(0.35), lineWidth: 4).scaleEffect(1.18) }

            if isDone {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(OBTheme.good)
            } else {
                Text("\(s.rawValue + 1)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isActive ? ob(0x0a0b0e) : OBTheme.textFaint)
            }
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Footer bits

private struct OBDots: View {
    let current: Int
    let total: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i == current ? OBTheme.accent : OBTheme.lineStrong)
                    .frame(width: i == current ? 22 : 7, height: 7)
                    .animation(.easeOut(duration: 0.3), value: current)
            }
        }
    }
}

// MARK: - Shared step header + components

private struct OBHeader: View {
    let eyebrow: String
    let title: String        // plain part
    let accentTail: String   // gradient-highlighted tail
    var lead: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Rectangle()
                    .fill(LinearGradient(colors: [OBTheme.violet, .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 20, height: 1.5)
                Text(eyebrow.uppercased())
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(OBTheme.accentBright)
            }
            .padding(.bottom, 16)

            (Text(title).foregroundStyle(OBTheme.text)
             + Text(accentTail).foregroundStyle(OBTheme.violetBright))
                .font(.system(size: 29, weight: .bold))
                .tracking(-0.7)
                .lineSpacing(2)

            if let lead {
                lead
                    .font(.system(size: 15))
                    .foregroundStyle(OBTheme.textDim)
                    .lineSpacing(4)
                    .padding(.top, 13)
                    .frame(maxWidth: 460, alignment: .leading)
            }
        }
    }
}

private struct OBKey: View {
    let label: String
    var onDark: Bool = false
    var body: some View {
        Text(label)
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(OBTheme.text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(onDark ? Color.black.opacity(0.25) : OBTheme.card2, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(onDark ? Color.black.opacity(0.3) : OBTheme.lineStrong, lineWidth: 1))
    }
}

private struct OBPrimaryButton: ButtonStyle {
    var large = false
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : (small ? 12 : 13), weight: .semibold))
            .foregroundStyle(ob(0x0a0b0e))
            .padding(.horizontal, large ? 22 : (small ? 12 : 16))
            .padding(.vertical, large ? 12 : (small ? 7 : 10))
            .background(
                LinearGradient(colors: [OBTheme.accentBright, OBTheme.accent], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: large ? 12 : 8))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .shadow(color: OBTheme.accent.opacity(0.35), radius: 10, y: 6)
    }
}

private struct OBGhostButton: ButtonStyle {
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: .medium))
            .foregroundStyle(OBTheme.text)
            .padding(.horizontal, small ? 12 : 16)
            .padding(.vertical, small ? 7 : 10)
            .background(Color.white.opacity(configuration.isPressed ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(OBTheme.line, lineWidth: 1))
    }
}

private struct OBTag: View {
    enum Kind { case required, optional, good, pro }
    let text: String
    var kind: Kind = .optional
    private var fg: Color {
        switch kind {
        case .required: return OBTheme.warn
        case .optional: return OBTheme.textFaint
        case .good:     return OBTheme.good
        case .pro: return OBTheme.violetBright
        }
    }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(0.4)
            .foregroundStyle(fg)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(fg.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(fg.opacity(0.3), lineWidth: 1))
    }
}

private struct OBCardBG: ViewModifier {
    var granted = false
    func body(content: Content) -> some View {
        content
            .background(
                LinearGradient(colors: [granted ? OBTheme.good.opacity(0.07) : OBTheme.card, ob(0x16191f)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(granted ? OBTheme.good.opacity(0.4) : OBTheme.line, lineWidth: 1))
    }
}
private extension View {
    func obCard(granted: Bool = false) -> some View { modifier(OBCardBG(granted: granted)) }
}

// MARK: - Step 1: Welcome

private struct OBWelcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OBHeader(eyebrow: "Inline AI autocomplete",
                     title: "Type ahead.\n",
                     accentTail: "Everywhere on your Mac.",
                     lead: AnyView(
                        Text("Shadowtype predicts your next words as faint ghost text, right at the caret — in Mail, Slack, Notes, Safari, anywhere you type. Press ")
                        + Text("Tab").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(OBTheme.text)
                        + Text(" to accept. It runs entirely on-device.")
                     ))

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [ob(0x0e1118), ob(0x0b0d13)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(OBTheme.line, lineWidth: 1))

                (Text("Thanks for the update — I'll review it and ").foregroundColor(OBTheme.text)
                 + Text("get back to you by Friday.").foregroundColor(OBTheme.ghost))
                    .font(.system(size: 20))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 8) {
                            OBKey(label: "Tab")
                            Text("to accept").font(.system(size: 12)).foregroundStyle(OBTheme.textFaint)
                        }
                        .padding(18)
                    }
                }
            }
            .frame(height: 250)
            .padding(.top, 28)
        }
    }
}

// MARK: - Step 2: How it works

private struct OBHowItWorks: View {
    private struct Feature { let icon, title, body: String; let accent: Bool }
    private let features: [Feature] = [
        .init(icon: "text.alignleft",       title: "Ghost text at the caret",  body: "Predictions appear inline in faint grey, matching the field's font and size.", accent: true),
        .init(icon: "keyboard",             title: "Tab or → to accept",       body: "Tab (or Right Arrow at end-of-line) takes the next word; ⌥Tab takes the whole line. Keep typing to dismiss.", accent: false),
        .init(icon: "lock.fill",            title: "Nothing leaves your Mac",  body: "A local model on Apple Silicon does all the work. Free tier never touches the network.", accent: false),
        .init(icon: "sparkles",             title: "Knows your context",       body: "Optionally reads the screen and clipboard locally to make sharper suggestions.", accent: false),
    ]

    private let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            OBHeader(eyebrow: "How it works",
                     title: "Invisible until it's ",
                     accentTail: "useful.",
                     lead: AnyView(Text("Like spell-check, Shadowtype stays out of the way until it can save you a few keystrokes — then it offers a suggestion you can take or ignore.")))

            LazyVGrid(columns: cols, spacing: 14) {
                ForEach(features.indices, id: \.self) { i in card(features[i]) }
            }
        }
    }

    private func card(_ f: Feature) -> some View {
        let tint = f.accent ? OBTheme.accentBright : OBTheme.violetBright
        return VStack(alignment: .leading, spacing: 0) {
            Image(systemName: f.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.27), lineWidth: 1))
                .padding(.bottom, 13)
            Text(f.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(OBTheme.text)
            Text(f.body).font(.system(size: 12.7)).foregroundStyle(OBTheme.textDim).lineSpacing(3).padding(.top, 5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .obCard()
    }
}

// MARK: - Step 3: Permissions (wired to the real PermissionsManager)

private struct OBPermissions: View {
    @ObservedObject var perms: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            OBHeader(eyebrow: "Permissions",
                     title: "Two quick grants to ",
                     accentTail: "get going.",
                     lead: AnyView(Text("macOS asks for these so Shadowtype can see the text field you're in and place ghost text at your caret. Both are required — and you can revoke them anytime in System Settings.")))

            VStack(spacing: 13) {
                row(.accessibility, icon: "figure.wave.circle",
                    desc: "Reads the focused field's text and caret position to know what and where to suggest.")
                row(.inputMonitoring, icon: "keyboard.badge.ellipsis",
                    desc: "Observes keystrokes to trigger suggestions and catch your Tab. Listen-only — never logged.")
                row(.screenRecording, icon: "menubar.dock.rectangle",
                    desc: "Only if you enable screen-aware context. Captures the active window locally for on-device OCR.")
            }
        }
    }

    @ViewBuilder private func row(_ p: Permission, icon: String, desc: String) -> some View {
        let granted = perms.granted[p] ?? false
        HStack(spacing: 16) {
            Image(systemName: granted ? "checkmark" : icon)
                .font(.system(size: granted ? 20 : 22, weight: granted ? .bold : .regular))
                .foregroundStyle(granted ? OBTheme.good : OBTheme.accentBright)
                .frame(width: 44, height: 44)
                .background((granted ? OBTheme.good : OBTheme.accentBright).opacity(granted ? 0.12 : 0.0001),
                            in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .stroke(granted ? OBTheme.good : OBTheme.lineStrong, lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(p.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(OBTheme.text)
                    OBTag(text: p.required ? "Required" : "Optional", kind: p.required ? .required : .optional)
                }
                Text(desc).font(.system(size: 12.6)).foregroundStyle(OBTheme.textDim).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)

            if granted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                    Text(p.required ? "Granted" : "Enabled").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(OBTheme.good)
            } else {
                Button(p.required ? "Grant access" : "Enable") {
                    perms.request(p)
                    // The system prompt only fires once; also surface Settings for a prior denial.
                    perms.openSettings(p)
                }
                .buttonStyle(p.required ? AnyButtonStyle(OBPrimaryButton(small: true)) : AnyButtonStyle(OBGhostButton(small: true)))
            }
        }
        .padding(17)
        .obCard(granted: granted)
    }
}

// Type-erased button style so a row can pick primary vs ghost at runtime.
private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Step 4: Language model (real ModelManager download)

private struct OBModelStep: View {
    private let manager = ModelManager()
    private let physicalBytes = ProcessInfo.processInfo.physicalMemory

    // The best model that fits this Mac's RAM — the default selection. Every model is free and
    // selectable. Mirrors the Settings → Models recommendation logic.
    private let recommended = ModelCatalog.recommended(
        physicalBytes: ProcessInfo.processInfo.physicalMemory)

    @State private var selectedID: String
    @State private var progress: Double = 0     // 0...1
    @State private var phase: Phase = .idle

    init() {
        let rec = ModelCatalog.recommended(
            physicalBytes: ProcessInfo.processInfo.physicalMemory)
        _selectedID = State(initialValue: rec.id)
    }

    private enum Phase: Equatable { case idle, downloading, installed, failed }

    private var selected: ModelCatalogEntry {
        ModelCatalog.entries.first { $0.id == selectedID } ?? recommended
    }
    private func isInstalled(_ entry: ModelCatalogEntry) -> Bool {
        FileManager.default.fileExists(atPath: manager.modelURL(for: entry).path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OBHeader(eyebrow: "Language model",
                     title: "Choose your ",
                     accentTail: "on-device model.",
                     lead: AnyView(Text("Shadowtype runs a local model on Apple Silicon via Metal. We've preselected the best one for your Mac — pick another below if you like. It's stored locally and verified by checksum.")))
                .padding(.bottom, 24)

            // Download card — reflects the currently selected model.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "cpu")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(OBTheme.violetBright)
                        .frame(width: 46, height: 46)
                        .background(OBTheme.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(OBTheme.violet.opacity(0.26), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(selected.name).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(OBTheme.text)
                            if selected.id == recommended.id { OBTag(text: "Recommended", kind: .good) }
                        }
                        Text(spec(selected)).font(.system(size: 12.5)).foregroundStyle(OBTheme.textDim)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Download size").font(.system(size: 12)).foregroundStyle(OBTheme.textFaint)
                        Text(String(format: "%.1f GB", selected.downloadGB))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(OBTheme.text)
                    }
                }

                // Progress bar
                VStack(spacing: 9) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(OBTheme.field).overlay(Capsule().stroke(OBTheme.line, lineWidth: 1))
                            Capsule()
                                .fill(LinearGradient(colors: [OBTheme.violet, OBTheme.accent], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text(statusLeft).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(OBTheme.textFaint)
                        Spacer()
                        Text(statusRight).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(OBTheme.accentBright)
                    }
                }
                .padding(.top, 18)

                HStack(spacing: 10) {
                    Button(primaryLabel) { startDownload() }
                        .buttonStyle(OBPrimaryButton())
                        .disabled(phase == .downloading || phase == .installed)
                }
                .padding(.top, 18)
            }
            .padding(20)
            .obCard()

            // Selectable model list (everything except the one already shown in the card above).
            VStack(alignment: .leading, spacing: 0) {
                Text("CHOOSE A DIFFERENT MODEL — SWITCH ANYTIME IN SETTINGS")
                    .font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(OBTheme.textFaint)
                    .padding(.bottom, 10)
                ForEach(alternatives) { entry in modelRow(entry) }
            }
            .padding(.top, 18)
        }
        .onAppear { if isInstalled(selected) { phase = .installed; progress = 1 } }
    }

    @ViewBuilder private func modelRow(_ entry: ModelCatalogEntry) -> some View {
        let ramOK = ModelCatalog.ramOK(for: entry, physicalBytes: physicalBytes)
        let canPick = phase != .downloading
        HStack(spacing: 10) {
            Text(entry.name).font(.system(size: 13, weight: .medium)).foregroundStyle(OBTheme.text)
            if entry.id == recommended.id { OBTag(text: "Recommended", kind: .good) }
            if isInstalled(entry) { OBTag(text: "Downloaded", kind: .good) }
            if !ramOK { OBTag(text: "Tight on RAM", kind: .optional) }
            Spacer()
            Text(String(format: "%.1f GB", entry.downloadGB))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(OBTheme.textFaint)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(canPick ? OBTheme.accentBright : OBTheme.textFaint.opacity(0.4))
        }
        .padding(.vertical, 11)
        .opacity(canPick ? 1 : 0.5)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(OBTheme.lineSoft), alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { if canPick { select(entry) } }
    }

    private var alternatives: [ModelCatalogEntry] {
        ModelCatalog.entries.filter { $0.id != selectedID }
    }
    private func spec(_ entry: ModelCatalogEntry) -> String {
        "Q4_K_M · on-device · ~\(String(format: "%.1f", entry.approxRAMGB)) GB RAM"
    }
    private var primaryLabel: String {
        switch phase {
        case .idle:        return "Download & install"
        case .downloading: return "Downloading…"
        case .installed:   return "Installed ✓"
        case .failed:      return "Retry download"
        }
    }
    private var statusLeft: String {
        switch phase {
        case .idle:        return "Ready to download"
        case .downloading: return String(format: "%.1f GB of %.1f GB", selected.downloadGB * progress, selected.downloadGB)
        case .installed:   return "Verified · GGUF ✓"
        case .failed:      return "Download failed — check your connection"
        }
    }
    private var statusRight: String {
        switch phase {
        case .installed: return "100%"
        case .failed:    return "—"
        default:         return "\(Int(progress * 100))%"
        }
    }

    // Switch the card to a new model (only allowed when not mid-download — the list disables taps then).
    private func select(_ entry: ModelCatalogEntry) {
        selectedID = entry.id
        progress = isInstalled(entry) ? 1 : 0
        phase = isInstalled(entry) ? .installed : .idle
    }

    private func startDownload() {
        guard phase != .downloading, phase != .installed else { return }
        let entry = selected
        // The file may have landed since selection (e.g. downloaded from the Settings → Models pane).
        // Re-check so we never kick off a redundant second download to the same path through a separate
        // ModelManager instance.
        if isInstalled(entry) {
            progress = 1; phase = .installed
            activate(entry)
            return
        }
        phase = .downloading
        progress = 0
        manager.onDownloadProgress = { frac in
            DispatchQueue.main.async { if let f = frac { progress = f } }
        }
        Task {
            do {
                _ = try await manager.ensureModel(entry)
                await MainActor.run {
                    progress = 1; phase = .installed
                    activate(entry)
                }
            } catch {
                await MainActor.run { phase = .failed }
                NSLog("Shadowtype: onboarding model download failed: \(error)")
            }
        }
    }

    // Persist + make the freshly-downloaded model active (AppDelegate swaps it in live).
    private func activate(_ entry: ModelCatalogEntry) {
        UserDefaults.standard.set(entry.id, forKey: ModelManager.selectedModelDefaultsKey)
        NotificationCenter.default.post(name: .shadowtypeSelectModel, object: nil,
                                        userInfo: ["entry": entry])
    }
}

// MARK: - Step 5: Try it out (local ghost-text demo — does NOT touch the real WordMeter)

private struct OBTryIt: View {
    private static let base = "Hi Maya, thanks for flagging that. "
    private static let firstGhost = ["Let's", "sync", "tomorrow", "morning", "to", "align", "on", "the", "details."]
    private static let secondGhost = ["I'll", "send", "over", "the", "revised", "draft", "shortly."]

    @State private var typed = OBTryIt.base
    @State private var remaining = OBTryIt.firstGhost
    @State private var accepted = 0
    @State private var flash = false
    @State private var flashText = "+1 word"
    // Local key monitor so the real Tab key accepts a word while this step is on screen (mirrors the
    // app's Tab-to-accept). Installed on appear, removed on leave; consumed so Tab doesn't move focus.
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OBHeader(eyebrow: "Try it out",
                     title: "Press ",
                     accentTail: "Tab to accept.",
                     lead: AnyView(Text("Here's a live preview. The grey text is Shadowtype's suggestion — press Tab (or Right Arrow at end-of-line) to take the next word, or ⌥Tab to take the whole line.")))
                .padding(.bottom, 24)

            // Faux text field
            VStack(alignment: .leading, spacing: 0) {
                Text("✉︎ REPLY TO MAYA")
                    .font(.system(size: 10.5, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(OBTheme.textFaint)
                (Text(typed).foregroundColor(OBTheme.text)
                 + Text(remaining.joined(separator: " ")).foregroundColor(OBTheme.ghost))
                    .font(.system(size: 19))
                    .lineSpacing(8)
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
            .padding(EdgeInsets(top: 16, leading: 24, bottom: 22, trailing: 24))
            .frame(height: 200, alignment: .topLeading)
            .background(ob(0x0d0f14), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(OBTheme.lineStrong, lineWidth: 1))

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button { acceptWord() } label: {
                        HStack(spacing: 7) {
                            OBKey(label: "Tab", onDark: true)
                            Text("Accept word").lineLimit(1).fixedSize()
                        }
                    }
                    .buttonStyle(OBPrimaryButton(small: true))

                    Button { acceptLine() } label: {
                        HStack(spacing: 5) {
                            OBKey(label: "⌥"); OBKey(label: "Tab")
                            Text("Accept line").lineLimit(1).fixedSize()
                        }
                    }
                    .buttonStyle(OBGhostButton(small: true))

                    Spacer()
                    Button("Reset") { reset() }.buttonStyle(OBGhostButton(small: true))
                }

                HStack(spacing: 6) {
                    Text("Accepted").font(.system(size: 13)).foregroundStyle(OBTheme.textFaint)
                    Text("\(accepted)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(OBTheme.accentBright)
                    Text("/ 100").font(.system(size: 13)).foregroundStyle(OBTheme.textFaint)
                    Text(flashText).font(.system(size: 13, weight: .semibold)).foregroundStyle(OBTheme.good)
                        .opacity(flash ? 1 : 0)
                        .padding(.leading, 8)
                    Spacer()
                }
            }
            .padding(.top, 16)
        }
        .onAppear {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 48 else { return event }   // Tab
                let option = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask).contains(.option)
                if option { acceptLine() } else { acceptWord() }
                return nil                 // swallow so Tab doesn't shift focus / beep
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }

    private func acceptWord() {
        if remaining.isEmpty { remaining = OBTryIt.secondGhost }
        let w = remaining.removeFirst()
        typed += w + (remaining.isEmpty ? "" : " ")
        accepted += 1
        showFlash(1)
    }

    // ⌥Tab: take the entire remaining suggested line at once (mirrors the app's accept-line shortcut).
    private func acceptLine() {
        if remaining.isEmpty { remaining = OBTryIt.secondGhost }
        let n = remaining.count
        typed += remaining.joined(separator: " ") + " "
        remaining = []
        accepted += n
        showFlash(n)
    }

    private func showFlash(_ n: Int) {
        flashText = "+\(n) word" + (n == 1 ? "" : "s")
        withAnimation(.easeOut(duration: 0.15)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeOut(duration: 0.3)) { flash = false }
        }
    }

    private func reset() {
        typed = OBTryIt.base
        remaining = OBTryIt.firstGhost
        accepted = 0
    }
}

// MARK: - Step 6: Selection rewrite (informational — introduces the ⌥⌘K local rewrite)

// Introduces the on-device "rewrite selected text" feature: select text anywhere, press ⌥⌘K, pick how
// to rewrite it, preview inline. Static/informational (no live AX) — a before→after mock + the six
// action chips + the hotkey.
private struct OBSelectionRewrite: View {
    private struct Action { let icon, label: String }
    private let actions: [Action] = [
        .init(icon: "sparkles",                 label: "Rewrite"),
        .init(icon: "arrow.down.right.and.arrow.up.left", label: "Make shorter"),
        .init(icon: "briefcase",                label: "Make formal"),
        .init(icon: "face.smiling",             label: "Make casual"),
        .init(icon: "checkmark.seal",           label: "Fix grammar"),
        .init(icon: "list.bullet.rectangle",    label: "Summarize"),
    ]
    private let cols = [GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                OBHeader(eyebrow: "Selection rewrite",
                         title: "Rewrite anything with ",
                         accentTail: "⌥⌘K.",
                         lead: AnyView(Text("Select text in any app, press ⌥⌘K, and pick how to rewrite it — clearer, shorter, more formal, more casual, grammar-fixed, or summarized. The model runs on your Mac, so nothing is sent anywhere.")))
                Spacer(minLength: 12)
            }

            // Before → after mock (static), styled like the Try-it faux field.
            VStack(alignment: .leading, spacing: 10) {
                Text("SELECTED")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.1)
                    .foregroundStyle(OBTheme.textFaint)
                Text("hey can u send me that doc when u get a sec")
                    .font(.system(size: 16)).foregroundStyle(OBTheme.text)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(OBTheme.accent.opacity(0.20), in: RoundedRectangle(cornerRadius: 5))

                HStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(OBTheme.violetBright)
                    Text("Make formal").font(.system(size: 12, weight: .medium)).foregroundStyle(OBTheme.textDim)
                }
                .padding(.vertical, 2)

                Text("Could you please send me that document when you have a moment?")
                    .font(.system(size: 16)).foregroundStyle(OBTheme.violetBright)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 18, trailing: 20))
            .background(ob(0x0d0f14), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(OBTheme.lineStrong, lineWidth: 1))

            // Six actions.
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(actions.indices, id: \.self) { i in chip(actions[i]) }
            }

            // Hotkey + preview keys.
            HStack(spacing: 10) {
                HStack(spacing: 5) { OBKey(label: "⌥"); OBKey(label: "⌘"); OBKey(label: "K") }
                Text("to rewrite the selection").font(.system(size: 13)).foregroundStyle(OBTheme.textDim)
                Spacer()
            }
            HStack(spacing: 6) {
                Text("Preview before you keep it:").font(.system(size: 12.5)).foregroundStyle(OBTheme.textFaint)
                OBKey(label: "⏎"); Text("keep").font(.system(size: 12.5)).foregroundStyle(OBTheme.textDim)
                OBKey(label: "⌘R"); Text("redo").font(.system(size: 12.5)).foregroundStyle(OBTheme.textDim)
                OBKey(label: "⎋"); Text("undo").font(.system(size: 12.5)).foregroundStyle(OBTheme.textDim)
                Spacer()
            }
        }
    }

    private func chip(_ a: Action) -> some View {
        HStack(spacing: 9) {
            Image(systemName: a.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OBTheme.violetBright)
                .frame(width: 30, height: 30)
                .background(OBTheme.violetBright.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(OBTheme.violetBright.opacity(0.27), lineWidth: 1))
            Text(a.label).font(.system(size: 13, weight: .medium)).foregroundStyle(OBTheme.text)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 0)
        }
        .padding(10)
        .obCard()
    }
}

// Shared labelled text field used by onboarding steps (Make it yours, All set). Hoisted to file scope so
// both OBPersonalize and OBDone use the identical styling.
private func obField(label: String, placeholder: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(OBTheme.textDim)
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(OBTheme.textFaint))
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(OBTheme.text)
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .background(OBTheme.field, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(OBTheme.line, lineWidth: 1))
    }
}

// MARK: - Step 7: Make it yours (personalization)

// "Make it yours" — optional personalization that seeds the global custom AI instruction. Everything
// here is editable later in Settings → Instructions; skipping leaves the global instruction untouched.
private struct OBPersonalize: View {
    @State private var name = ""
    @State private var languages = ""
    @State private var voice: InstructionStore.Voice = .friendly

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Make it yours").font(.system(size: 31, weight: .bold)).foregroundStyle(OBTheme.text)
            Text("A couple of details so suggestions sound like you. Optional — you can edit or clear all of this anytime in Settings.")
                .font(.system(size: 15)).foregroundStyle(OBTheme.textDim)
                .lineSpacing(4).frame(maxWidth: 520).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 11)

            VStack(alignment: .leading, spacing: 18) {
                obField(label: "Your name", placeholder: "e.g. Jane Appleseed", text: $name)
                obField(label: "Languages you write in", placeholder: "e.g. English, Spanish and Catalan", text: $languages)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Writing voice").font(.system(size: 13, weight: .semibold)).foregroundStyle(OBTheme.textDim)
                    HStack(spacing: 9) {
                        ForEach(InstructionStore.Voice.allCases, id: \.self) { v in voicePill(v) }
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.top, 26)

            // Live preview of the composed instruction so the user sees exactly what gets seeded.
            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT SHADOWTYPE WILL USE").font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.3).foregroundStyle(OBTheme.textFaint)
                Text(InstructionStore.composeDefault(name: name, languages: languages, voice: voice))
                    .font(.system(size: 13)).foregroundStyle(OBTheme.textDim).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
            .frame(maxWidth: 520, alignment: .leading)
            .background(OBTheme.field, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(OBTheme.line, lineWidth: 1))
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            let p = InstructionStore.shared.personalizationInputs()
            name = p.name; languages = p.languages; voice = p.voice ?? .friendly
        }
        .onChange(of: name) { seed() }
        .onChange(of: languages) { seed() }
        .onChange(of: voice) { seed() }
    }

    private func seed() {
        InstructionStore.shared.seedGlobalFromPersonalization(
            name: name, languages: languages, voice: voice)
    }

    private func voicePill(_ v: InstructionStore.Voice) -> some View {
        let on = v == voice
        return Text(v.label)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(on ? OBTheme.text : OBTheme.textDim)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(on ? OBTheme.accent.opacity(0.16) : OBTheme.field,
                       in: Capsule())
            .overlay(Capsule().stroke(on ? OBTheme.accent : OBTheme.line, lineWidth: 1))
            .contentShape(Capsule())
            .onTapGesture { voice = v }
    }
}

private struct OBDone: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @AppStorage("shadowtype.showWordCountInMenuBar") private var showWordCount = true

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "cursor.rays")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(OBTheme.violetBright)
                .frame(width: 92, height: 92)
                .background(
                    LinearGradient(colors: [OBTheme.violet.opacity(0.2), OBTheme.accent.opacity(0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(OBTheme.violet.opacity(0.4), lineWidth: 1))
                .shadow(color: OBTheme.violet.opacity(0.5), radius: 25, y: 18)
                .padding(.bottom, 26)

            Text("You're all set.").font(.system(size: 31, weight: .bold)).foregroundStyle(OBTheme.text)
            Text("Shadowtype is now running in your menu bar. Start typing anywhere and it'll quietly suggest as you go.")
                .font(.system(size: 15)).foregroundStyle(OBTheme.textDim)
                .multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 460)
                .padding(.top, 13)

            VStack(spacing: 0) {
                optRow(title: "Launch at login", sub: "Always on, right when you sign in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LaunchAtLogin.setEnabled(launchAtLogin) }
                Divider().overlay(OBTheme.lineSoft)
                optRow(title: "Show today's word count in menu bar",
                       sub: "See how many words you've accepted today at a glance", isOn: $showWordCount)
            }
            .frame(maxWidth: 420)
            .padding(.top, 22)

            // Free + open-source note
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(OBTheme.accentBright)
                (Text("Free and open source. ").font(.system(size: 13, weight: .semibold)).foregroundColor(OBTheme.text)
                 + Text("Every feature is on, with no limits — and it always will be. Everything runs locally on your Mac.").font(.system(size: 13)).foregroundColor(OBTheme.textDim))
                    .lineSpacing(3)
            }
            .padding(EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18))
            .frame(maxWidth: 460)
            .background(OBTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(OBTheme.accent.opacity(0.26), lineWidth: 1))
            .padding(.top, 26)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func optRow(title: String, sub: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(OBTheme.text)
                Text(sub).font(.system(size: 13)).foregroundStyle(OBTheme.textDim)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(OBTheme.accent)
        }
        .padding(.vertical, 12)
    }
}
