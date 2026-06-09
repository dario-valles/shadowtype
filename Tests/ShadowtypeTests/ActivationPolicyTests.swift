// ActivationPolicy — pure idle/auto-activate decisions for terminals + code editors (Cotypist
// parity). No AX/model needed; these pin the conservative heuristics and the force-activate-bypass
// boundary the coordinator relies on.
import XCTest
import CoreGraphics
@testable import Shadowtype

final class ActivationPolicyTests: XCTestCase {

    // MARK: - Context classification

    func testManagedClassification() {
        XCTAssertTrue(ActivationPolicy.isTerminal(bundleId: "com.apple.Terminal"))
        XCTAssertTrue(ActivationPolicy.isTerminal(bundleId: "com.googlecode.iterm2"))
        XCTAssertTrue(ActivationPolicy.isEditor(bundleId: "com.microsoft.VSCode"))
        XCTAssertTrue(ActivationPolicy.isEditor(bundleId: "com.todesktop.230313mzl4w4u92")) // Cursor
        XCTAssertTrue(ActivationPolicy.isManaged(bundleId: "com.apple.Terminal"))
        XCTAssertFalse(ActivationPolicy.isManaged(bundleId: "com.apple.Notes"))
        XCTAssertFalse(ActivationPolicy.isManaged(bundleId: nil))
    }

    // MARK: - Ordinary apps are never idle

    func testOrdinaryAppNeverIdle() {
        XCTAssertFalse(ActivationPolicy.isIdle(.init(bundleId: "com.apple.Notes")))
        XCTAssertFalse(ActivationPolicy.isIdle(.init(bundleId: "com.tinyspeck.slackmacgap")))
        XCTAssertFalse(ActivationPolicy.isIdle(.init(bundleId: nil)))
    }

    // MARK: - Terminals: idle at a shell, active in an agent prompt

    func testTerminalIdleAtNormalShell() {
        let input = ActivationPolicy.Input(bundleId: "com.apple.Terminal",
                                           terminalText: "user@mac ~/proj % ls -la\ntotal 8\ndrwxr-xr-x")
        XCTAssertTrue(ActivationPolicy.isIdle(input), "normal shell stays idle")
    }

    func testTerminalActiveOnAgentPromptMarkers() {
        for marker in ["? for shortcuts", "esc to interrupt", "Claude Code", "Cursor Agent"] {
            let input = ActivationPolicy.Input(bundleId: "com.googlecode.iterm2",
                                               terminalText: "some output\n\(marker)\n")
            XCTAssertFalse(ActivationPolicy.isIdle(input), "‘\(marker)’ should activate")
        }
    }

    func testTerminalAgentDetectionIsCaseInsensitive() {
        XCTAssertTrue(ActivationPolicy.isAgentPrompt("? FOR SHORTCUTS"))
        XCTAssertTrue(ActivationPolicy.isAgentPrompt("Welcome to CLAUDE CODE"))
        XCTAssertFalse(ActivationPolicy.isAgentPrompt("just a normal line"))
        XCTAssertFalse(ActivationPolicy.isAgentPrompt(nil))
        XCTAssertFalse(ActivationPolicy.isAgentPrompt(""))
    }

    func testTerminalWithNoReadableTextStaysIdle() {
        // AX gave us nothing → can't confirm an agent prompt → stay idle (conservative).
        XCTAssertTrue(ActivationPolicy.isIdle(.init(bundleId: "com.apple.Terminal", terminalText: nil)))
    }

    // MARK: - Editors: idle on the code surface, active in the small chat input

    func testEditorIdleOnFullHeightCodeSurface() {
        // Monaco fills ~the whole window → ratio high → idle.
        let input = ActivationPolicy.Input(bundleId: "com.microsoft.VSCode",
                                           fieldHeight: 760, windowHeight: 800)
        XCTAssertTrue(ActivationPolicy.isIdle(input))
    }

    func testEditorActiveInSmallChatInput() {
        // A few-line composer in a tall window → small ratio → chat input → active.
        let input = ActivationPolicy.Input(bundleId: "com.microsoft.VSCode",
                                           fieldHeight: 90, windowHeight: 800)
        XCTAssertFalse(ActivationPolicy.isIdle(input))
    }

    func testEditorWithoutMeasurementsStaysIdle() {
        // No frame info → can't prove it's the chat input → idle (force-activate covers it).
        XCTAssertTrue(ActivationPolicy.isIdle(.init(bundleId: "com.microsoft.VSCode")))
    }

    func testLooksLikeChatInputBoundary() {
        XCTAssertTrue(ActivationPolicy.looksLikeChatInput(fieldHeight: 100, windowHeight: 800))
        XCTAssertFalse(ActivationPolicy.looksLikeChatInput(fieldHeight: 500, windowHeight: 800))
        XCTAssertFalse(ActivationPolicy.looksLikeChatInput(fieldHeight: nil, windowHeight: 800))
        XCTAssertFalse(ActivationPolicy.looksLikeChatInput(fieldHeight: 100, windowHeight: 0))
    }

    // MARK: - non-prose field suppression (address bar / search boxes)

    func testIsBrowser() {
        XCTAssertTrue(ActivationPolicy.isBrowser(bundleId: "com.brave.Browser"))
        XCTAssertTrue(ActivationPolicy.isBrowser(bundleId: "com.apple.Safari"))
        XCTAssertTrue(ActivationPolicy.isBrowser(bundleId: "company.thebrowser.Browser"))
        XCTAssertFalse(ActivationPolicy.isBrowser(bundleId: "com.apple.TextEdit"))
        XCTAssertFalse(ActivationPolicy.isBrowser(bundleId: nil))
    }

    func testAddressBarSuppressed() {
        // Browser chrome: editable plain text FIELD, no web-area ancestor, not a prose role → omnibox.
        XCTAssertTrue(ActivationPolicy.isNonProseField(
            isBrowser: true, subroleIsSearch: false, isEditable: true,
            hasWebAreaAncestor: false, isProseContentRole: false))
    }

    func testBrowserPageContentAllowed() {
        // Editable INSIDE a web area (Gmail compose, a web text field) → prose, allowed.
        XCTAssertFalse(ActivationPolicy.isNonProseField(
            isBrowser: true, subroleIsSearch: false, isEditable: true,
            hasWebAreaAncestor: true, isProseContentRole: false))
    }

    func testTextAreaAllowedEvenWithoutWebAreaAncestor() {
        // The Gmail-compose regression: Chromium hides the AXWebArea from the parent walk, so
        // hasWebAreaAncestor is false — but an AXTextArea is page content, never the omnibox. Allow it.
        XCTAssertFalse(ActivationPolicy.isNonProseField(
            isBrowser: true, subroleIsSearch: false, isEditable: true,
            hasWebAreaAncestor: false, isProseContentRole: true))
    }

    func testSearchFieldSuppressedAnywhere() {
        // An AXSearchField is suppressed even in a non-browser, with or without a web area, and even
        // if it somehow reports a prose role — the search subrole wins.
        XCTAssertTrue(ActivationPolicy.isNonProseField(
            isBrowser: false, subroleIsSearch: true, isEditable: true,
            hasWebAreaAncestor: true, isProseContentRole: true))
    }

    func testNativeTextFieldAllowed() {
        // Non-browser, not a search field → prose (e.g. a native single-line compose). Allowed.
        XCTAssertFalse(ActivationPolicy.isNonProseField(
            isBrowser: false, subroleIsSearch: false, isEditable: true,
            hasWebAreaAncestor: false, isProseContentRole: false))
    }

    func testBrowserNonEditableFocusNotTreatedAsChrome() {
        // A non-editable focus in a browser must not trip the chrome rule.
        XCTAssertFalse(ActivationPolicy.isNonProseField(
            isBrowser: true, subroleIsSearch: false, isEditable: false,
            hasWebAreaAncestor: false, isProseContentRole: false))
    }

    // MARK: - web-mail structured fields (Gmail/Outlook To/Cc/Bcc/Subject)

    func testIsWebMailHostMatchesKnownHosts() {
        XCTAssertTrue(ActivationPolicy.isWebMailHost("mail.google.com"))
        XCTAssertTrue(ActivationPolicy.isWebMailHost("MAIL.GOOGLE.COM"))
        XCTAssertTrue(ActivationPolicy.isWebMailHost("outlook.live.com"))
        XCTAssertTrue(ActivationPolicy.isWebMailHost("mail.proton.me"))
        XCTAssertFalse(ActivationPolicy.isWebMailHost("docs.google.com"))
        XCTAssertFalse(ActivationPolicy.isWebMailHost(nil))
    }

    func testGmailRecipientFieldDetected() {
        // To/Cc/Bcc inputs surface as AXTextField inside the Gmail page → structured.
        XCTAssertTrue(ActivationPolicy.isStructuredWebMailField(
            host: "mail.google.com", role: "AXTextField"))
        XCTAssertTrue(ActivationPolicy.isStructuredWebMailField(
            host: "mail.google.com", role: "AXComboBox"))
    }

    func testGmailComposeBodyNotDetected() {
        // The compose iframe body is AXWebArea (contenteditable) → prose, must not match.
        XCTAssertFalse(ActivationPolicy.isStructuredWebMailField(
            host: "mail.google.com", role: "AXWebArea"))
        XCTAssertFalse(ActivationPolicy.isStructuredWebMailField(
            host: "mail.google.com", role: "AXTextArea"))
    }

    func testNonWebMailHostDoesNotTrigger() {
        // The structured-field rule must be host-scoped — a normal site's text input is prose.
        XCTAssertFalse(ActivationPolicy.isStructuredWebMailField(
            host: "github.com", role: "AXTextField"))
        XCTAssertFalse(ActivationPolicy.isStructuredWebMailField(
            host: nil, role: "AXTextField"))
    }

    func testStructuredWebMailFieldSuppressedThroughGate() {
        // Even though it's editable, inside a web area, and not a prose role — the Gmail header field
        // is structured input, so the gate suppresses (matches the search-field carve-out shape).
        XCTAssertTrue(ActivationPolicy.isNonProseField(
            isBrowser: true, subroleIsSearch: false, isEditable: true,
            hasWebAreaAncestor: true, isProseContentRole: false,
            isStructuredWebMailField: true))
    }

    func testGmailComposeBodyStillAllowedThroughGate() {
        // The compose body is AXWebArea (prose role); structured rule does not apply, gate allows.
        XCTAssertFalse(ActivationPolicy.isNonProseField(
            isBrowser: true, subroleIsSearch: false, isEditable: true,
            hasWebAreaAncestor: true, isProseContentRole: true,
            isStructuredWebMailField: false))
    }

    // MARK: - Web-mail recipient/subject suppression (host-agnostic)

    func testWebMailRecipientLongLabels() {
        // Gmail-style labels expose the role via descriptor strings; substring match for >4-char markers.
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["To recipients"]))
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["Cc recipients"]))
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["Bcc recipients"]))
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["Subject"]))
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["Subject line"]))
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["DESTINATARIO"]))
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["Asunto"]))
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["Objet"]))
    }

    func testWebMailRecipientShortLabelsRequireEquality() {
        // Outlook web / Superhuman: short single-word labels. Trimmed equality only — no substrings.
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["Bcc"]))
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["  bcc "]))
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["Cc"]))
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["À"]))
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["à"]))
    }

    func testWebMailRecipientShortLabelsNoSubstringFalsePositives() {
        // "according", "Carbon Copy", "Vaccination" all contain "cc" / "bcc" as substrings — must NOT match.
        XCTAssertFalse(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["according"]))
        XCTAssertFalse(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["Carbon Copy"]))
        XCTAssertFalse(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["Vaccination card"]))
        // A long string that merely begins with "à" (e.g. "à propos") must not match either.
        XCTAssertFalse(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["à propos"]))
    }

    func testWebMailRecipientEmptyAndIrrelevant() {
        XCTAssertFalse(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: []))
        XCTAssertFalse(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: [""]))
        XCTAssertFalse(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["Message body", "Compose"]))
        XCTAssertFalse(ActivationPolicy.isWebMailRecipientOrSubject(descriptors: ["Search mail"]))
    }

    func testWebMailRecipientMixedDescriptorBag() {
        // The caller pools kAXDescription + kAXRoleDescription + AXTitle into one bag; ANY match wins.
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(
            descriptors: ["text field", "Subject", "Compose"]))
        XCTAssertTrue(ActivationPolicy.isWebMailRecipientOrSubject(
            descriptors: ["combo box", "Cc", "Recipient input"]))
    }

    // MARK: - Recipient-chip detection

    func testRecipientChipDetected() {
        XCTAssertTrue(ActivationPolicy.hasRecipientChip(buttonRoleDescriptions: ["Recipient"]))
        XCTAssertTrue(ActivationPolicy.hasRecipientChip(buttonRoleDescriptions: ["Press delete to remove recipient"]))
        XCTAssertTrue(ActivationPolicy.hasRecipientChip(buttonRoleDescriptions: ["Destinatario"]))
        XCTAssertTrue(ActivationPolicy.hasRecipientChip(buttonRoleDescriptions: ["email chip"]))
    }

    func testRecipientChipIgnoresOrdinaryButtons() {
        XCTAssertFalse(ActivationPolicy.hasRecipientChip(buttonRoleDescriptions: []))
        XCTAssertFalse(ActivationPolicy.hasRecipientChip(buttonRoleDescriptions: ["button", "Send", "Discard"]))
        XCTAssertFalse(ActivationPolicy.hasRecipientChip(buttonRoleDescriptions: ["popup button"]))
    }

    // MARK: - Terminal mode classification (shell-command mode)

    func testTerminalModeShellPromptVariants() {
        // The active (last) line is a shell prompt with a command being typed.
        for buf in ["user@host ~/proj % git st",
                    "➜  ~ ls -l",
                    "~/code on  main ❯ npm ru",
                    "bash-3.2$ cd ",
                    "$ "] {
            XCTAssertEqual(ActivationPolicy.terminalMode(buf), .shellCommand, "‘\(buf)’ should be shellCommand")
        }
    }

    func testTerminalModeAgentWinsOverSigil() {
        // An agent TUI that also draws a `$` must classify as agentPrompt, never shellCommand.
        let buf = "some output\n? for shortcuts\n$ "
        XCTAssertEqual(ActivationPolicy.terminalMode(buf), .agentPrompt)
    }

    func testTerminalModeNoneForOutputReplPagerProse() {
        // REPLs, pagers, command output, and prose ending in `$` are NOT shell prompts.
        XCTAssertEqual(ActivationPolicy.terminalMode(">>> import os"), .none)        // python REPL
        XCTAssertEqual(ActivationPolicy.terminalMode("In [1]: x = 5"), .none)        // ipython
        XCTAssertEqual(ActivationPolicy.terminalMode("Cloning into 'repo'..."), .none) // output
        XCTAssertEqual(ActivationPolicy.terminalMode("total 8\ndrwxr-xr-x  4 me"), .none) // ls output
        XCTAssertEqual(ActivationPolicy.terminalMode("the price was $"), .none)      // prose ending $ (no trailing space)
        XCTAssertEqual(ActivationPolicy.terminalMode("Total: $ 100 paid"), .none)    // money: sigil+space but digit-led
        XCTAssertEqual(ActivationPolicy.terminalMode("# Introduction"), .none)       // markdown heading / comment
        XCTAssertEqual(ActivationPolicy.terminalMode(nil), .none)
        XCTAssertEqual(ActivationPolicy.terminalMode(""), .none)
    }

    func testShellPromptLineIgnoresCommandInternalSigils() {
        // `$` inside `$PATH` / `$5` is followed by a non-space → not mistaken for the prompt delimiter,
        // but the real prompt `$ ` earlier on the line still matches.
        XCTAssertTrue(ActivationPolicy.isShellPromptLine("~ $ echo $PATH"))
        XCTAssertTrue(ActivationPolicy.isShellPromptLine("~ $ git commit -m \"fix #123\""))
        XCTAssertFalse(ActivationPolicy.isShellPromptLine("cost is $5 today"))
    }

    // MARK: - Terminal idle gate honours the per-app opt-in

    func testTerminalShellPromptIdleUnlessOptedIn() {
        let buf = "user@host ~/proj % git st"
        // Default (opt-in OFF): a plain shell prompt stays idle.
        XCTAssertTrue(ActivationPolicy.isIdle(.init(bundleId: "com.googlecode.iterm2", terminalText: buf,
                                                    shellCommandsEnabled: false)))
        // Opt-in ON: the shell prompt becomes active.
        XCTAssertFalse(ActivationPolicy.isIdle(.init(bundleId: "com.googlecode.iterm2", terminalText: buf,
                                                     shellCommandsEnabled: true)))
        // Output line is idle regardless of the opt-in.
        XCTAssertTrue(ActivationPolicy.isIdle(.init(bundleId: "com.googlecode.iterm2",
                                                    terminalText: "total 8\ndrwxr-xr-x",
                                                    shellCommandsEnabled: true)))
    }

    func testTerminalAgentPromptActiveEvenWithoutOptIn() {
        let buf = "working…\nesc to interrupt"
        XCTAssertFalse(ActivationPolicy.isIdle(.init(bundleId: "com.googlecode.iterm2", terminalText: buf,
                                                     shellCommandsEnabled: false)))
    }
}
