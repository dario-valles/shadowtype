// Shell-command framing: the pure prompt assembler + buffer extractors + secret redaction + the
// zero-hallucination history fast path. No AX/model needed.
import XCTest
@testable import Shadowtype

final class ShellPromptAssemblyTests: XCTestCase {

    // MARK: - Command extraction from the buffer

    func testShellCommandAfterSigilStripsPromptChrome() {
        XCTAssertEqual(CompletionCoordinator.shellCommandAfterSigil("user@host ~/p % git status"), "git status")
        XCTAssertEqual(CompletionCoordinator.shellCommandAfterSigil("~/proj ❯ ls -l"), "ls -l")   // starship (sigil-last)
        XCTAssertEqual(CompletionCoordinator.shellCommandAfterSigil("bash-3.2$ cd src"), "cd src")
        XCTAssertNil(CompletionCoordinator.shellCommandAfterSigil("total 8"))           // output
        XCTAssertNil(CompletionCoordinator.shellCommandAfterSigil("# a comment"))       // leading #
    }

    func testShellRecentCommandsOldestToNewest() {
        let buf = """
        ~ $ cd proj
        ~/proj $ npm install
        added 200 packages
        ~/proj $ npm run bui
        """
        XCTAssertEqual(CompletionCoordinator.shellRecentCommands(buf), ["cd proj", "npm install", "npm run bui"])
    }

    // MARK: - cwd / git extraction

    func testShellCwdAndBranchExtraction() {
        let starship = "~/code/app on  main ❯ git p"
        XCTAssertEqual(CompletionCoordinator.shellCwd(starship), "~/code/app")
        XCTAssertEqual(CompletionCoordinator.shellGitBranch("~/app (feature-x) $ git st"), "feature-x")
        XCTAssertNil(CompletionCoordinator.shellGitBranch("~ $ echo hi"))
    }

    // MARK: - Assembler shape + KV stability

    func testAssembleShellPromptFewShotAndTail() {
        let buf = """
        ~ $ cd proj
        ~/proj $ git status
        ~/proj $ git pu
        """
        let out = CompletionCoordinator.assembleShellPrompt(prefix: "git pu", terminalBuffer: buf)
        // Few-shot exemplars are `$ `-prefixed; the tail is the typed line with NO trailing newline.
        XCTAssertTrue(out.contains("$ cd proj"))
        XCTAssertTrue(out.contains("$ git status"))
        XCTAssertTrue(out.hasSuffix("$ git pu"), "prompt must END at the typed command with no trailing newline")
        XCTAssertFalse(out.hasSuffix("\n"))
    }

    func testAssembleShellPromptFrontStableAcrossKeystrokes() {
        // The header + few-shot block must be byte-stable as the tail grows (KV warm path, FR-CE-5):
        // the two prompts share the longest common prefix up to the typed tail.
        let buf = "~ $ git status\n~ $ git pu"
        let a = CompletionCoordinator.assembleShellPrompt(prefix: "git pu", terminalBuffer: buf)
        let b = CompletionCoordinator.assembleShellPrompt(prefix: "git pus", terminalBuffer: buf)
        let common = String(zip(a, b).prefix(while: { $0 == $1 }).map(\.0))
        XCTAssertTrue(common.hasSuffix("$ git pu"), "front (everything up to the tail) must be identical")
    }

    func testShellCurrentLineIsTailAfterNewline() {
        XCTAssertEqual(CompletionCoordinator.shellCurrentLine("line1\nline2\ngit pu"), "git pu")
        XCTAssertEqual(CompletionCoordinator.shellCurrentLine("git pu"), "git pu")
    }

    // MARK: - Prompt chrome on the CURRENT line
    //
    // Every test above hands the assembler a pre-cleaned stem ("git pu"), which baked in the assumption
    // that the current line arrives chrome-free. In a real terminal it does not: the AX prefix ends with
    // the live PS1 — the very thing isShellPromptLine matched to enter shell mode.

    func testShellTypedCommandStripsPromptChrome() {
        XCTAssertEqual(CompletionCoordinator.shellTypedCommand("~ $ cd proj\ndario@mac ~/proj % git pu"),
                       "git pu")
        // Trailing space is PRESERVED: a typed `git ` must complete to `status`, not ` status`.
        XCTAssertEqual(CompletionCoordinator.shellTypedCommand("~/proj $ git "), "git ")
        // Chrome only — nothing typed yet.
        XCTAssertEqual(CompletionCoordinator.shellTypedCommand("~/proj $ "), "")
        // No sigil (terminals that expose only the typed text) → the raw line, unchanged behaviour.
        XCTAssertEqual(CompletionCoordinator.shellTypedCommand("line1\ngit pu"), "git pu")
    }

    // The continuation line must stay command-shaped. With the chrome it read
    // `$ dario@mac ~/proj % git pu` — not a command, and repeating the stem the exemplars already end on.
    func testAssembleShellPromptStripsChromeFromTheTypedTail() {
        let buf = """
        ~ $ cd proj
        ~/proj $ git status
        dario@mac ~/proj % git pu
        """
        let out = CompletionCoordinator.assembleShellPrompt(
            prefix: "~ $ cd proj\ndario@mac ~/proj % git pu", terminalBuffer: buf)
        XCTAssertTrue(out.hasSuffix("$ git pu"))
        XCTAssertFalse(out.contains("$ dario@mac"))
        // The exemplar equal to the typed stem is dropped, so the stem appears exactly once.
        XCTAssertEqual(out.components(separatedBy: "$ git pu").count - 1, 1)
    }

    // Redaction was applied to the exemplars but not to the typed tail, so a secret on the line the user
    // is typing RIGHT NOW — the one most worth withholding — went to the model verbatim.
    func testAssembleShellPromptRedactsTheTypedTail() {
        let out = CompletionCoordinator.assembleShellPrompt(
            prefix: "~ $ export AWS_SECRET_ACCESS_KEY=abc123", terminalBuffer: "~ $ ls")
        XCTAssertFalse(out.contains("abc123"))
        XCTAssertTrue(out.hasSuffix("$ export AWS_SECRET_ACCESS_KEY=•••"))
    }

    // The zero-hallucination fast path compares the stem against chrome-STRIPPED history commands, so a
    // chrome-laden stem could never match anything and the path was dead in a real terminal.
    func testHistoryPrefixMatchNeedsTheChromeStrippedStem() {
        let buf = "~ $ git status\n~ $ docker compose up -d\n~/proj % doc"
        let prefix = "~ $ git status\n~/proj % doc"
        XCTAssertNil(ShellHistory.prefixMatch(currentLine: CompletionCoordinator.shellCurrentLine(prefix),
                                              buffer: buf))
        XCTAssertEqual(ShellHistory.prefixMatch(currentLine: CompletionCoordinator.shellTypedCommand(prefix),
                                                buffer: buf),
                       "ker compose up -d")
    }

    // The destructive-command guard tokenizes the JOINED line: with the chrome its first token was
    // `dario@mac`, never `rm`, so the whole denylist was bypassed at a real shell prompt.
    func testDangerGuardOnlySeesTheCommandOnceChromeIsStripped() {
        let prefix = "~ $ ls\ndario@mac ~/proj % rm -rf "
        XCTAssertFalse(ShellCommandGuard.isDangerous(
            fullCommand: CompletionCoordinator.shellCurrentLine(prefix) + "/"))
        XCTAssertTrue(ShellCommandGuard.isDangerous(
            fullCommand: CompletionCoordinator.shellTypedCommand(prefix) + "/"))
    }

    func testTruncatedAtNewlineKeepsOneLine() {
        XCTAssertEqual(CompletionCoordinator.truncatedAtNewline("sh\nmore"), "sh")
        XCTAssertEqual(CompletionCoordinator.truncatedAtNewline("\n\npush"), "push")
        XCTAssertEqual(CompletionCoordinator.truncatedAtNewline("push origin main"), "push origin main")
    }

    // MARK: - Secret redaction

    func testRedactingSecrets() {
        XCTAssertEqual(CompletionCoordinator.redactingSecrets("export AWS_SECRET_ACCESS_KEY=abc123"),
                       "export AWS_SECRET_ACCESS_KEY=•••")
        XCTAssertEqual(CompletionCoordinator.redactingSecrets("mysql --password hunter2 -u root"),
                       "mysql --password ••• -u root")
        XCTAssertEqual(CompletionCoordinator.redactingSecrets("curl -H Authorization: Bearer tok_live_x"),
                       "curl -H Authorization: Bearer •••")
        XCTAssertEqual(CompletionCoordinator.redactingSecrets("GITHUB_TOKEN=ghp_xxx gh pr list"),
                       "GITHUB_TOKEN=••• gh pr list")
        // Ordinary command untouched.
        XCTAssertEqual(CompletionCoordinator.redactingSecrets("git push origin main"),
                       "git push origin main")
    }

    // MARK: - History fast path

    func testHistoryPrefixMatchReturnsRemainder() {
        let buf = "~ $ git status\n~ $ docker compose up -d\n~ $ doc"
        XCTAssertEqual(ShellHistory.prefixMatch(currentLine: "doc", buffer: buf), "ker compose up -d")
        // No match → nil.
        XCTAssertNil(ShellHistory.prefixMatch(currentLine: "kube", buffer: buf))
        // Too-short stem → nil (don't suggest the whole last command on an empty prompt).
        XCTAssertNil(ShellHistory.prefixMatch(currentLine: "d", buffer: buf))
    }

    func testHistoryPrefersMostRecentMatch() {
        let buf = "~ $ git checkout main\n~ $ git commit -m wip\n~ $ git c"
        // Newest matching command wins.
        XCTAssertEqual(ShellHistory.prefixMatch(currentLine: "git c", buffer: buf), "ommit -m wip")
    }
}
