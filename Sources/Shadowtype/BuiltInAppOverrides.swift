// BuiltInAppOverrides — apps where Shadowtype is OFF by default because completion either won't work
// or shouldn't run there (Cotypist "Has built-in overrides" parity). This is the missing default layer
// under AppRules: AppRules only ever *disabled* on top of a global default-on, so without this table
// Shadowtype fired in password managers, IDEs, terminals, and non-text utilities.
//
// These overrides are SOFT: they only change the *default*. A user can re-enable any of them in
// Settings → Apps (an explicit AppRules enable wins — see AppRules.effectiveDefaultCompletions). Only
// secure text *fields* (EditContextTracker.isSecure) are a hard, non-overridable block.
//
// Terminals/editors are ALSO soft-idled at runtime by ActivationPolicy (which can flip back on inside an
// AI-agent prompt / sidebar chat). Listing terminals here as well surfaces them in the per-app UI and
// makes "off by default" explicit; we reuse ActivationPolicy.terminalBundleIds rather than re-spell them.
import Foundation

enum OverrideCategory: String {
    case passwordManager   // credential fields — useless/risky to complete
    case ide               // has its own autocomplete (IntelliSense/Copilot)
    case system            // no meaningful free-text composition surface
    case terminal          // draws its own text / shell has completion

    var label: String {
        switch self {
        case .passwordManager: return "Password manager"
        case .ide:             return "Code editor"
        case .system:          return "System app"
        case .terminal:        return "Terminal"
        }
    }
}

struct BuiltInOverride {
    let category: OverrideCategory
    let completionsOff: Bool   // default-off when true (all current entries are off)
    let reason: String         // shown as the per-app subtitle in Settings
}

enum BuiltInAppOverrides {
    /// Bundle id → built-in override. Exact-match on bundle id (case-sensitive, as Apple ships them).
    static let table: [String: BuiltInOverride] = {
        var t: [String: BuiltInOverride] = [:]

        // Password managers — credential fields; field-level secure-input already blocks the password
        // box, but the whole app (notes, search, vaults) has no use for prose completion.
        let pwReason = "Built-in: password managers don't need text completion."
        for id in [
            "com.1password.1password",      // 1Password 8
            "com.1password.1password7",     // 1Password 7
            "com.agilebits.onepassword7",   // 1Password 7 (older signing id)
            "com.bitwarden.desktop",
            "com.apple.Passwords",          // macOS 15 Passwords app
            "org.keepassxc.keepassxc",
            "com.dashlane.Dashlane",
            "com.lastpass.LastPass",
            "me.proton.pass.electron",
            "in.sinew.Enpass-Desktop",
        ] {
            t[id] = BuiltInOverride(category: .passwordManager, completionsOff: true, reason: pwReason)
        }

        // IDEs / code editors with their own completion. (VS Code / Cursor / Windsurf are handled by
        // ActivationPolicy soft-idle — they complete only in the sidebar AI chat — so they're NOT here.)
        let ideReason = "Built-in: code editors have their own autocomplete."
        for id in [
            "com.apple.dt.Xcode",
            "com.google.android.studio",
            "com.jetbrains.intellij",
            "com.jetbrains.intellij.ce",
            "com.jetbrains.AppCode",
            "com.jetbrains.pycharm",
            "com.jetbrains.pycharm.ce",
            "com.jetbrains.WebStorm",
            "com.jetbrains.PhpStorm",
            "com.jetbrains.CLion",
            "com.jetbrains.goland",
            "com.jetbrains.rubymine",
            "com.jetbrains.rider",
            "com.jetbrains.datagrip",
            "com.sublimetext.4",
        ] {
            t[id] = BuiltInOverride(category: .ide, completionsOff: true, reason: ideReason)
        }

        // System / non-text utilities — no prose surface to complete into.
        let sysReason = "Built-in: no text-composition surface here."
        for id in [
            "com.apple.finder",
            "com.apple.Preview",
            "com.apple.systempreferences",  // System Settings
            "com.apple.iCal",               // Calendar
            "com.runningwithcrayons.Alfred",
            "com.raycast.macos",
            "com.apple.ActivityMonitor",
        ] {
            t[id] = BuiltInOverride(category: .system, completionsOff: true, reason: sysReason)
        }

        // Terminals — already soft-idled by ActivationPolicy; reuse its set so the two never drift, then
        // add the GPU-rendered terminals (Ghostty/Warp) that can't be read at all.
        let termReason = "Built-in: terminals draw their own text / have shell completion."
        for id in ActivationPolicy.terminalBundleIds.union([
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty",
            "io.alacritty",
        ]) {
            t[id] = BuiltInOverride(category: .terminal, completionsOff: true, reason: termReason)
        }

        return t
    }()

    /// The built-in override for a bundle id, or nil when the app has no override (the common case).
    static func override(forBundleId bundleId: String?) -> BuiltInOverride? {
        guard let bundleId else { return nil }
        return table[bundleId]
    }
}
