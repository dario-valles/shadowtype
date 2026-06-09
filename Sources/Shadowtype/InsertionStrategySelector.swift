// InsertionStrategySelector — pure choice of how an accepted completion is committed when the direct
// AX set-value path is unavailable (web/Electron nodes, or AX-refused fields) and we fall back to
// synthesizing input.
//
// Synthetic Unicode keystrokes are reliable and clipboard-free for the common short, single-line
// completion, but some hosts mishandle a long or multi-line synthetic string (a `\n` in the synthesized
// string may not register as Enter, and very long strings can be truncated). Pasting is steadier there.
// Keeping the decision pure (separate from the side-effectful Injector) makes the policy testable.
enum InsertionStrategy: Equatable {
    // Synthesize the text as a Unicode keyboard event (the default, clipboard-free path).
    case keystroke
    // Place the text on the pasteboard and synthesize Cmd-V. Only when paste insertion is enabled and
    // the chunk is large or multi-line.
    case paste
}

enum InsertionStrategySelector {
    // At or above this many characters a completion is a paste candidate. Short completions stay on the
    // keystroke path so the clipboard is never touched for the overwhelmingly common case.
    static let pasteCharacterThreshold = 80

    // Picks the strategy for `chunk`. Returns .keystroke whenever paste insertion is disabled, so the
    // default behavior is unchanged; otherwise pastes multi-line or long chunks and keystrokes the rest.
    static func strategy(forChunk chunk: String, pasteEnabled: Bool) -> InsertionStrategy {
        guard pasteEnabled else { return .keystroke }
        if chunk.contains(where: \.isNewline) { return .paste }
        return chunk.count >= pasteCharacterThreshold ? .paste : .keystroke
    }
}
