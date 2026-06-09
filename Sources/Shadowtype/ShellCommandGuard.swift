// ShellCommandGuard — the safety net for terminal shell-command mode. A base model (worse under 4-bit
// quant) can hallucinate an irreversible, destructive command; this is the post-generation gate that
// suppresses the ghost when the FULL command line (typed prefix + suggestion, joined by the caller so a
// split `rm -rf ` + `/` is still caught) matches a conservative denylist of catastrophic shapes.
//
// Shape-matched, not exact-string, so flag reordering (`rm -r -f /`) and spacing variants are caught.
// Deliberately narrow: it must NEVER suppress an ordinary destructive-but-intended command
// (`rm -rf ./build`, `> /dev/null`, `dd if=in of=out`) — a false hide is a worse UX regression than a
// rare miss, and the user still has to press Tab/→ to accept. Pure + idempotent (no AX/model/IO).
import Foundation

enum ShellCommandGuard {
    /// True when the full command is dangerous and the ghost must be hidden.
    static func isDangerous(fullCommand: String) -> Bool {
        let trimmed = fullCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Fork bomb: match regardless of internal spacing (`: () { :|:& };:`).
        let dense = trimmed.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
            .map(String.init).joined()
        if dense.contains(":(){:|:&};:") { return true }

        let collapsed = collapseSpaces(trimmed)
        let lower = collapsed.lowercased()

        // Network-pipe-to-shell: `curl … | sh`, `wget … | bash` (and `| sudo sh`).
        if (lower.contains("curl ") || lower.contains("wget ")) && pipesToShell(lower) { return true }

        // Redirect to a raw storage device anywhere on the line: `> /dev/sda`, `>/dev/disk2`.
        if redirectsToStorageDevice(lower) { return true }

        // Tokenize and drop leading privilege/env prefixes so `sudo rm -rf /` is seen as `rm …`.
        var tokens = collapsed.split(separator: " ").map(String.init)
        tokens = strippingCommandPrefixes(tokens)
        guard let cmd = tokens.first?.lowercased() else { return false }
        let args = Array(tokens.dropFirst())

        switch cmd {
        case "rm":
            return hasRecursiveFlag(args) && args.contains(where: isCatastrophicTarget)
        case "chmod", "chown":
            return hasRecursiveFlag(args) && args.contains(where: isCatastrophicTarget)
        case "dd":
            return args.contains { writesStorageDevice($0) }
        default:
            if cmd.hasPrefix("mkfs") { return true }   // mkfs / mkfs.ext4 / … always formats
            return false
        }
    }

    // MARK: - Pure helpers

    private static func collapseSpaces(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    // Leading tokens that don't change the operative command: privilege escalation, env wrappers, and
    // `VAR=value` assignments. Stripped so the switch sees the real verb.
    private static func strippingCommandPrefixes(_ tokens: [String]) -> [String] {
        var t = tokens
        let skip: Set<String> = ["sudo", "doas", "env", "command", "nice", "time", "exec", "builtin"]
        while let head = t.first {
            if skip.contains(head.lowercased()) { t.removeFirst(); continue }
            if head.contains("=") && !head.hasPrefix("-") { t.removeFirst(); continue } // FOO=bar prefix
            break
        }
        return t
    }

    // A flag token requesting recursion: combined (`-rf`, `-fr`, `-R`) or long (`--recursive`).
    private static func hasRecursiveFlag(_ args: [String]) -> Bool {
        for a in args {
            let l = a.lowercased()
            if l == "--recursive" { return true }
            // Short flag cluster like -rf / -fr / -Rf — a single leading '-' (not '--') with r in it.
            if a.hasPrefix("-") && !a.hasPrefix("--") && l.dropFirst().contains("r") { return true }
        }
        return false
    }

    // Targets whose recursive deletion/permission-change is catastrophic. Relative paths
    // (`./build`, `node_modules`, `/Users/me/x`) are intentionally NOT here.
    private static func isCatastrophicTarget(_ arg: String) -> Bool {
        if arg.hasPrefix("-") { return false }   // a flag, not a target
        let a = arg.lowercased()
        let exact: Set<String> = ["/", "/*", "~", "~/", "~/*", "*", ".", "$home", "$home/", "$home/*",
                                  "${home}", "${home}/", "${home}/*"]
        if exact.contains(a) { return true }
        // Top-level system directories (`/etc`, `/usr`, …) — but NOT `/users/...`, `/home/...` user data.
        let systemRoots = ["/bin", "/sbin", "/etc", "/usr", "/var", "/lib", "/sys", "/boot", "/dev",
                           "/private", "/system", "/library", "/applications"]
        for root in systemRoots where a == root || a == root + "/" || a == root + "/*" { return true }
        return false
    }

    // dd writing to a physical disk: `of=/dev/disk2`, `of=/dev/sda`. Pseudo-devices (null/zero/…) pass.
    private static func writesStorageDevice(_ arg: String) -> Bool {
        let l = arg.lowercased()
        guard l.hasPrefix("of=/dev/") else { return false }
        let dev = String(l.dropFirst("of=/dev/".count))
        return isStoragePrefix(dev)
    }

    private static func redirectsToStorageDevice(_ lower: String) -> Bool {
        // Find any `>` (or `>>`) redirect whose target is /dev/<storage>.
        var search = lower[...]
        while let gt = search.firstIndex(of: ">") {
            var rest = search[search.index(after: gt)...]
            while rest.first == ">" || rest.first == "&" { rest = rest.dropFirst() }
            while rest.first == " " { rest = rest.dropFirst() }
            if rest.hasPrefix("/dev/") {
                let dev = rest.dropFirst("/dev/".count)
                if isStoragePrefix(String(dev)) { return true }
            }
            search = rest
        }
        return false
    }

    // A /dev/ tail that names a raw block device (sd*, disk*, rdisk*, nvme*, hd*, vd*, mmcblk*).
    private static func isStoragePrefix(_ devTail: String) -> Bool {
        let prefixes = ["sd", "disk", "rdisk", "nvme", "hd", "vd", "mmcblk", "xvd"]
        return prefixes.contains { devTail.hasPrefix($0) }
    }

    private static func pipesToShell(_ lower: String) -> Bool {
        for shell in ["sh", "bash", "zsh", "dash", "ksh"] {
            if lower.contains("| \(shell)") || lower.contains("|\(shell)")
                || lower.contains("| sudo \(shell)") || lower.contains("|sudo \(shell)") { return true }
        }
        return false
    }
}
