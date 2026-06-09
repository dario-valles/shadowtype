// ShellHistory — the zero-hallucination fast path for terminal shell-command mode, mirroring fish /
// zsh-autosuggestions' default "history" strategy: if a command ALREADY VISIBLE in the buffer starts
// with what the user is typing, suggest its remainder verbatim and skip the model entirely. No model =
// no hallucination, instant, and the suggestion is something the user provably ran before. Pure +
// testable. Buffer→command parsing is shared with the prompt assembler (CompletionCoordinator
// .shellRecentCommands) so the sigil rule lives in exactly one place.
import Foundation

enum ShellHistory {
    /// The completion remainder for `currentLine` drawn from the most-recent matching command in
    /// `buffer`, or nil when nothing in history extends the current stem. The returned string is the
    /// part AFTER the typed stem (what Tab would inject), never the whole command.
    static func prefixMatch(currentLine: String, buffer: String?) -> String? {
        let stem = currentLine
        // Require a real stem so we don't suggest the entire last command on an empty prompt.
        guard stem.trimmingCharacters(in: .whitespaces).count >= 2, let buffer else { return nil }
        // Newest→oldest: the last matching command the user ran is the best guess.
        for cmd in CompletionCoordinator.shellRecentCommands(buffer).reversed() {
            guard cmd.count > stem.count, cmd.hasPrefix(stem), cmd != stem else { continue }
            return String(cmd.dropFirst(stem.count))
        }
        return nil
    }
}
