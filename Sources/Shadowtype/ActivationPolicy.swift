// ActivationPolicy — where Shadowtype stays IDLE by default (Cotypist parity), and the heuristics
// that flip it on. Two managed context families:
//
//   • Terminals (Terminal.app, iTerm): a normal shell already has its own completion, so we stay
//     quiet — UNLESS the visible buffer shows we're typing into an AI agent's prompt (Claude Code,
//     Codex, Cursor Agent), where natural-language completion is genuinely useful.
//   • Code editors (VS Code, Cursor, Windsurf): the code surface has IntelliSense/Copilot, so we
//     stay quiet there — and only complete in the small sidebar AI-chat input (where NL prompts live).
//
// Everything here is PURE so it unit-tests without AX/model/overlay (mirrors WordCap / sanitizer).
// The heuristics are deliberately CONSERVATIVE and always overridable by the force-activate hotkey:
// a false negative just means the user presses ⌃`, while a false positive would put a ghost where it
// isn't wanted — so the agent-prompt markers are specific UI strings, and the editor test requires a
// clearly small (non-code-surface) field. This is the "undocumented" part of the feature; treat the
// marker list + ratio as tunables.
import CoreGraphics

enum ActivationPolicy {
    // Bundle ids treated as terminals.
    static let terminalBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]

    // Web browsers. Their editable CHROME — the address/omnibox, find-in-page bar, in-toolbar
    // search — is structured input (URLs, queries), never prose, so ghosts there are wrong. Page
    // CONTENT (compose boxes, web text fields) lives inside an AXWebArea and is unaffected.
    static let browserBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "company.thebrowser.Browser",   // Arc
        "company.thebrowser.dia",       // Dia
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    // Bundle ids treated as code editors (Electron, sidebar-chat-only).
    static let editorBundleIds: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",       // VSCodium / code-oss
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf",        // Windsurf
    ]

    // Specific TUI strings shipped by AI coding agents. Chosen to be unlikely in ordinary shell
    // output (full product names with a space, or distinctive footer hints) to avoid false positives.
    static let agentPromptMarkers: [String] = [
        "? for shortcuts",     // Claude Code / Codex input footer
        "esc to interrupt",    // agent "working…" hint
        "claude code",
        "cursor agent",
        "/clear to clear",     // Claude Code slash-hint
    ]

    // Interactive-shell prompt sigils we recognise at the END of the active command line. Deliberately
    // EXCLUDES `>` — too ambiguous (heredoc/quote continuation, pagers, `>>>` REPLs) and the cause of
    // most false positives. Each must be FOLLOWED BY A SPACE on the line (the PS1 trailing space), so a
    // command containing `$VAR`/`#tag`/`$5` doesn't read as a prompt.
    static let shellPromptSigils: Set<Character> = ["$", "%", "#", "❯", "➜"]

    // Editor chat composers are a few lines tall; the Monaco code surface fills most of the window.
    // A focused editable shorter than this fraction of its window is treated as the chat input.
    static let editorChatMaxHeightRatio: CGFloat = 0.5

    // Field-descriptor markers that name a web-mail recipient/subject input across Gmail/Outlook/
    // Superhuman/Shortwave/Front/Missive in EN/ES/FR. Hosts vary (and new clients appear), but the
    // visible label exposed via kAXDescription / kAXRoleDescription / AXTitle is stable enough to be
    // a positive signal that the focused field expects an email address or short subject — never prose.
    // Long markers (>4 chars) are substring-matched; short markers (≤4 chars: "bcc", "cc", "à") require
    // trimmed equality so "Carbon Copy" / "according" don't false-positive.
    static let webMailFieldMarkers: [String] = [
        "to recipients", "cc recipients", "bcc recipients", "bcc",
        "subject",
        "destinatario", "asunto",
        "à", "cc",
        "objet",
    ]

    // Role-description markers on AXButton children inside a recipients field when Gmail-style "chips"
    // have been committed (an email address rendered as a pill, with a remove button). Ghost text
    // appended after a chip is dropped on send, so the field is non-prose once any chip exists.
    static let recipientChipMarkers: [String] = ["recipient", "destinatario", "chip"]

    /// Inputs the coordinator gathers from the focused field. Each is best-effort/optional so the
    /// policy can fall back conservatively (idle) when AX can't answer.
    struct Input {
        var bundleId: String? = nil
        var terminalText: String? = nil   // full visible buffer (terminals only)
        var fieldHeight: CGFloat? = nil   // focused editable height (editors)
        var windowHeight: CGFloat? = nil  // its window height (editors)
        var shellCommandsEnabled: Bool = false  // per-app opt-in for shell-command auto-fire (terminals)
    }

    /// What kind of terminal context the visible buffer shows. Drives both the idle gate and which
    /// prompt/sampling the coordinator uses. `agentPrompt` wins over `shellCommand` (an agent TUI that
    /// happens to draw a `$` must not be treated as a shell).
    enum TerminalMode { case agentPrompt, shellCommand, none }

    /// Pure: classify a terminal's visible buffer. agentPrompt → NL completion (unchanged); shellCommand
    /// → shell-command mode (gated by the per-app opt-in); none → idle (output/pager/REPL/ambiguous).
    static func terminalMode(_ text: String?) -> TerminalMode {
        guard let t = text, !t.isEmpty else { return .none }
        if isAgentPrompt(t) { return .agentPrompt }
        return isShellPromptLine(lastVisibleLine(t)) ? .shellCommand : .none
    }

    /// The last non-empty line of the buffer — the line the caret sits on. Trailing blank lines are
    /// ignored so a buffer captured with a trailing newline still yields the prompt line.
    static func lastVisibleLine(_ text: String) -> String {
        var s = Substring(text)
        while s.last == "\n" || s.last == "\r" { s = s.dropLast() }
        if let nl = s.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return String(s[s.index(after: nl)...])
        }
        return String(s)
    }

    /// Pure: does this single line look like an interactive shell prompt with a command being typed?
    /// Finds the last prompt sigil that is FOLLOWED BY A SPACE (the PS1 trailing space). Rejects REPL /
    /// debugger continuation prompts, treats a line-leading `#`/`%` as a comment/output, and requires the
    /// text after the sigil to start command-like (kills `Total: $ 100` money/digit prose). Residual: a
    /// rare prose line like `save 50 % off` still reads as a `%` (zsh) prompt — accepted, since the cost
    /// is one ignorable ghost in an opt-in terminal, and dropping `%` would lose real zsh prompts.
    static func isShellPromptLine(_ line: String) -> Bool {
        let lead = line.trimmingCharacters(in: .whitespaces)
        guard !lead.isEmpty, line.count < 512 else { return false }
        let replPrefixes = [">>>", "...", "In [", "Out[", "(gdb)", "(lldb)", "irb(", "pry(", "ipdb>", "pdb>"]
        if replPrefixes.contains(where: { lead.hasPrefix($0) }) { return false }
        let chars = Array(line)
        for i in stride(from: chars.count - 1, through: 0, by: -1) {
            guard shellPromptSigils.contains(chars[i]) else { continue }
            guard i + 1 < chars.count, chars[i + 1] == " " else { continue } // sigil + trailing space
            if (chars[i] == "#" || chars[i] == "%") && i == 0 { continue }   // leading # / % = not a prompt
            // What follows must look like the START of a command, not prose/money. The text after the
            // sigil's space, leading spaces dropped: either empty (a bare prompt with nothing typed yet)
            // or beginning with a command-name char (letter, or a path/var lead `. / _ ~`). This rejects
            // `Total: $ 100` / `50 % off` (digit-led) and other prose that happens to embed a sigil+space.
            let after = chars[(i + 2)...].drop(while: { $0 == " " })
            guard let first = after.first else { return true }             // bare prompt, nothing typed
            if first.isLetter || "./_~".contains(first) { return true }    // command-like start
            continue
        }
        return false
    }

    static func isManaged(bundleId: String?) -> Bool {
        guard let b = bundleId else { return false }
        return terminalBundleIds.contains(b) || editorBundleIds.contains(b)
    }

    static func isTerminal(bundleId: String?) -> Bool {
        guard let b = bundleId else { return false }
        return terminalBundleIds.contains(b)
    }

    static func isEditor(bundleId: String?) -> Bool {
        guard let b = bundleId else { return false }
        return editorBundleIds.contains(b)
    }

    static func isBrowser(bundleId: String?) -> Bool {
        guard let b = bundleId else { return false }
        return browserBundleIds.contains(b)
    }

    /// Web-mail hosts that expose STRUCTURED single-line fields (To/Cc/Bcc/Subject) inside their page
    /// chrome. Compose body remains contenteditable (AXWebArea/AXGroup), so the structured-field gate
    /// only catches AXTextField/AXComboBox while the prose body still gets ghosts. Bare lowercased hosts.
    static let webMailHosts: Set<String> = [
        "mail.google.com",
        "outlook.live.com",
        "outlook.office.com",
        "outlook.office365.com",
        "mail.proton.me",
        "mail.yahoo.com",
        "mail.aol.com",
    ]

    /// Pure (testable): is this a web-mail host whose recipient/subject fields collide with native autocomplete?
    static func isWebMailHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return webMailHosts.contains(h)
    }

    /// Pure (testable): structured single-line field on a web-mail host (To/Cc/Bcc/Subject).
    /// Compose body in Gmail/Outlook is multi-line contenteditable → AXWebArea/AXGroup, so it never
    /// matches; only the header inputs do. Keeps the user's native recipient autocomplete uncontested.
    static func isStructuredWebMailField(host: String?, role: String?) -> Bool {
        guard isWebMailHost(host), let r = role else { return false }
        return r == "AXTextField" || r == "AXComboBox"
    }

    /// Pure: suppress ghosts because the focused field is STRUCTURED input, not prose — so a ghost
    /// would offer URL/query/form garbage (e.g. "aelo.com" in the address bar). Signals:
    ///   • `subroleIsSearch` — an AXSearchField anywhere (omniboxes, in-app search boxes).
    ///   • `isStructuredWebMailField` — Gmail/Outlook To/Cc/Bcc/Subject (AXTextField inside web mail),
    ///     where the host's own contact autocomplete must win and our ghost would offer prose garbage.
    ///   • browser CHROME — an editable field in a browser with NO web-area ancestor: the address
    ///     bar / find bar / toolbar search. Page content (inside an AXWebArea) is prose → allowed.
    /// Conservative: requires `isEditable` so a non-text focus never trips it, and it is bypassable
    /// by the force-activate hotkey at the call site. AX-unknowns pass through as "prose" (allow).
    /// `isProseContentRole` is the key guard against false positives: a multi-line AXTextArea (or an
    /// AXWebArea) IS page content — the Gmail/web compose box — never the single-line omnibox, so it is
    /// always prose even when the web-area ancestor walk comes up empty (Chromium's parent chain often
    /// doesn't expose the AXWebArea, which made the bare `!hasWebAreaAncestor` rule suppress real
    /// composers). The chrome rule then only fires for a plain text FIELD with no web context.
    static func isNonProseField(isBrowser: Bool, subroleIsSearch: Bool, isEditable: Bool,
                                hasWebAreaAncestor: Bool, isProseContentRole: Bool,
                                isStructuredWebMailField: Bool = false) -> Bool {
        if subroleIsSearch { return true }
        if isStructuredWebMailField { return true }
        if isProseContentRole { return false }
        if isBrowser && isEditable && !hasWebAreaAncestor { return true }
        return false
    }

    /// Should completions stay IDLE (suppressed) for this focused field? Non-managed apps are never
    /// idle. Terminals are idle unless an AI-agent prompt is visible. Editors are idle unless the
    /// focused field looks like the small sidebar chat input.
    static func isIdle(_ input: Input) -> Bool {
        if isTerminal(bundleId: input.bundleId) {
            switch terminalMode(input.terminalText) {
            case .agentPrompt:  return false                          // NL completion (unchanged)
            case .shellCommand: return !input.shellCommandsEnabled    // per-app opt-in
            case .none:         return true                           // output/pager/REPL → stay quiet
            }
        }
        if isEditor(bundleId: input.bundleId) {
            return !looksLikeChatInput(fieldHeight: input.fieldHeight, windowHeight: input.windowHeight)
        }
        return false
    }

    /// Conservative scan of a terminal's visible text for an AI-agent prompt signature.
    static func isAgentPrompt(_ text: String?) -> Bool {
        guard let t = text, !t.isEmpty else { return false }
        let hay = t.lowercased()
        return agentPromptMarkers.contains { hay.contains($0) }
    }

    /// True when the focused editable is clearly smaller than its window (a chat composer), and we
    /// have both measurements. Missing measurements → false (stay idle; the user can force-activate).
    static func looksLikeChatInput(fieldHeight: CGFloat?, windowHeight: CGFloat?) -> Bool {
        guard let fh = fieldHeight, let wh = windowHeight, fh > 0, wh > 0 else { return false }
        return fh < wh * editorChatMaxHeightRatio
    }

    /// Pure: does any descriptor look like a web-mail recipient/subject label? `descriptors` is the
    /// bag of strings the caller pulls from kAXDescription / kAXRoleDescription / AXTitle (and
    /// optionally placeholder) on the focused field. Length-aware matching: ≤4-char markers require
    /// trimmed equality with the descriptor, so a short label like "Cc" / "À" / "Bcc" matches while
    /// "according" / "Carbon Copy" / "scope" do not. Longer markers match by case-insensitive substring.
    static func isWebMailRecipientOrSubject(descriptors: [String]) -> Bool {
        for raw in descriptors {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            for marker in webMailFieldMarkers {
                if marker.count <= 4 {
                    if trimmed == marker { return true }
                } else {
                    if trimmed.contains(marker) { return true }
                }
            }
        }
        return false
    }

    /// Pure: does the focused field hold committed recipient chips? `buttonRoleDescriptions` is the
    /// caller's collection of kAXRoleDescription strings from AXButton descendants of the field.
    /// Substring-matched (markers are unambiguous full words).
    static func hasRecipientChip(buttonRoleDescriptions: [String]) -> Bool {
        for raw in buttonRoleDescriptions {
            let s = raw.lowercased()
            for marker in recipientChipMarkers where s.contains(marker) { return true }
        }
        return false
    }
}
