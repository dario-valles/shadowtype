import Foundation

struct CompletionActivationEvaluator {
    enum SkipReason: Equatable {
        case idleContext
        case missingPrefix
        case notBoundary
        case thinContext
        case completeStatement
        case nonProseField
        case midLineDisabled
        case typo
        case contextPending
    }

    enum PrefixDecision: Equatable {
        case holdCapability(misses: Int)
        case skip(SkipReason)
        case continueEvaluation(prefix: String, shellMode: Bool)
    }

    struct PrefixSnapshot {
        let forced: Bool
        let bundleId: String?
        let terminalText: String?
        let editorFieldHeight: CGFloat?
        let editorWindowHeight: CGFloat?
        let shellCommandsEnabled: Bool
        let originalPrefix: String?
        let prefix: String?
        let focusSeq: UInt64
        let emojiTrigger: Bool
        let minPrefixChars: Int
    }

    struct PrefixEvaluation {
        let decision: PrefixDecision
        let capabilityGate: FocusCapabilityFlickerGate
    }

    enum Decision: Equatable {
        case skip(SkipReason)
        case emoji(value: String, queryLength: Int)
        case correction(value: String, run: String)
        case shellHistory(remainder: String)
        case generate(prefix: String, shellMode: Bool, terminalText: String?)
    }

    enum PreTypoDecision: Equatable {
        case skip(SkipReason)
        case emoji(value: String, queryLength: Int)
        case continueEvaluation
    }

    enum TypoAssessment: Equatable {
        case notLikely
        case likely(run: String, correction: String?)
    }

    struct Snapshot {
        let prefix: String
        let shellMode: Bool
        let terminalText: String?
        let nonProseField: Bool
        let midLineEnabled: Bool
        let caretAtLineEnd: Bool
        let emojiEnabled: Bool
        let emoji: EmojiCompletion?
        let typo: TypoAssessment
        let holdBackOnTypos: Bool
        let contextCapturePendingWithoutContext: Bool
    }

    static func evaluatePrefix(
        _ snapshot: PrefixSnapshot,
        capabilityGate originalGate: FocusCapabilityFlickerGate
    ) -> PrefixEvaluation {
        if !snapshot.forced {
            let idleInput = ActivationPolicy.Input(
                bundleId: snapshot.bundleId,
                terminalText: snapshot.terminalText,
                fieldHeight: snapshot.editorFieldHeight,
                windowHeight: snapshot.editorWindowHeight,
                shellCommandsEnabled: snapshot.shellCommandsEnabled
            )
            if ActivationPolicy.isIdle(idleInput) {
                return PrefixEvaluation(decision: .skip(.idleContext), capabilityGate: originalGate)
            }
        }

        var gate = originalGate
        let hasContext = !(snapshot.prefix ?? "").isEmpty
        if case let .suppress(misses) = gate.evaluate(
            hasContext: hasContext,
            focusSeq: snapshot.focusSeq
        ) {
            return PrefixEvaluation(decision: .holdCapability(misses: misses), capabilityGate: gate)
        }

        guard let prefix = snapshot.prefix, !prefix.isEmpty else {
            return PrefixEvaluation(decision: .skip(.missingPrefix), capabilityGate: gate)
        }

        let shellMode = snapshot.terminalText.map {
            ActivationPolicy.terminalMode($0) == .shellCommand
        } ?? false

        guard shellMode || isMeaningfulBoundary(prefix) || snapshot.emojiTrigger else {
            return PrefixEvaluation(decision: .skip(.notBoundary), capabilityGate: gate)
        }
        guard hasUsefulContext(prefix, minPrefixChars: snapshot.minPrefixChars) else {
            return PrefixEvaluation(decision: .skip(.thinContext), capabilityGate: gate)
        }
        guard shellMode || !endsCompleteStatement(prefix) else {
            return PrefixEvaluation(decision: .skip(.completeStatement), capabilityGate: gate)
        }
        return PrefixEvaluation(
            decision: .continueEvaluation(prefix: prefix, shellMode: shellMode),
            capabilityGate: gate
        )
    }

    static func evaluate(_ snapshot: Snapshot) -> Decision {
        switch evaluateBeforeTypo(snapshot) {
        case let .skip(reason):
            return .skip(reason)
        case let .emoji(value, queryLength):
            return .emoji(value: value, queryLength: queryLength)
        case .continueEvaluation:
            return evaluateAfterTypo(snapshot)
        }
    }

    static func evaluateBeforeTypo(_ snapshot: Snapshot) -> PreTypoDecision {
        if snapshot.nonProseField {
            return .skip(.nonProseField)
        }
        if !snapshot.midLineEnabled, !snapshot.caretAtLineEnd {
            return .skip(.midLineDisabled)
        }

        if let emoji = snapshot.emoji, snapshot.emojiEnabled,
           emoji.isTrigger(prefix: snapshot.prefix),
           let best = emoji.matches(prefix: snapshot.prefix, limit: 1).first,
           let query = emoji.currentQuery(prefix: snapshot.prefix) {
            return .emoji(value: best.emoji, queryLength: query.count + 1)
        }
        return .continueEvaluation
    }

    static func evaluateAfterTypo(_ snapshot: Snapshot) -> Decision {
        if case let .likely(run, correction) = snapshot.typo {
            if let correction {
                return .correction(value: correction, run: run)
            }
            if snapshot.holdBackOnTypos {
                return .skip(.typo)
            }
        }

        if snapshot.shellMode, let terminalText = snapshot.terminalText {
            let current = shellTypedCommand(snapshot.prefix)
            if let remainder = ShellHistory.prefixMatch(currentLine: current, buffer: terminalText),
               !remainder.isEmpty {
                let full = current + remainder
                if redactingSecrets(full) == full,
                   !ShellCommandGuard.isDangerous(fullCommand: full) {
                    return .shellHistory(remainder: remainder)
                }
            }
        }

        if snapshot.contextCapturePendingWithoutContext {
            return .skip(.contextPending)
        }
        return .generate(
            prefix: snapshot.prefix,
            shellMode: snapshot.shellMode,
            terminalText: snapshot.terminalText
        )
    }

    static func assessTypo(
        prefix: String,
        typoGuard: TypoGuard?,
        autocorrectEnabled: Bool,
        autocorrect: Autocorrect?
    ) -> TypoAssessment {
        let run = lastWord(of: prefix)
        guard let typoGuard, typoGuard.looksLikeTypo(lastWord: run) else {
            return .notLikely
        }
        let correction = autocorrectEnabled ? autocorrect?.correction(for: run) : nil
        return .likely(run: run, correction: correction)
    }

    static func isMeaningfulBoundary(_ prefix: String) -> Bool {
        guard let last = prefix.last else { return false }
        if last.isLetter || last.isNumber { return true }
        if last == " " {
            let trimmed = prefix.dropLast()
            if let previous = trimmed.last, !previous.isWhitespace { return true }
        }
        return false
    }

    static func hasUsefulContext(_ prefix: String, minPrefixChars: Int) -> Bool {
        let nonSpace = prefix.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
        if nonSpace >= minPrefixChars { return true }
        return prefix.contains(" ") && nonSpace >= 1
    }

    static func endsCompleteStatement(_ prefix: String) -> Bool {
        guard let last = prefix.last, last.isWhitespace,
              let lastNonSpace = prefix.reversed().first(where: { !$0.isWhitespace }) else {
            return false
        }
        return lastNonSpace == "." || lastNonSpace == "!" || lastNonSpace == "?"
    }

    static func lastWord(of prefix: String) -> String {
        var index = prefix.endIndex
        var word = ""
        while index > prefix.startIndex {
            let previous = prefix.index(before: index)
            let character = prefix[previous]
            if character.isWhitespace { break }
            word.insert(character, at: word.startIndex)
            index = previous
        }
        return word
    }

    static func shellTypedCommand(_ prefix: String) -> String {
        let line = shellCurrentLine(prefix)
        guard let command = shellCommandAfterSigil(line) else { return line }
        guard !command.isEmpty, let range = line.range(of: command, options: .backwards) else {
            return ""
        }
        return String(line[range.lowerBound...])
    }

    private static func shellCurrentLine(_ prefix: String) -> String {
        if let newline = prefix.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return String(prefix[prefix.index(after: newline)...])
        }
        return prefix
    }

    static func redactingSecrets(_ line: String) -> String {
        var tokens = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for index in tokens.indices {
            let token = tokens[index]
            if let equals = token.firstIndex(of: "=") {
                let key = String(token[..<equals]).uppercased()
                let sensitive = ["TOKEN", "SECRET", "KEY", "PASSWORD", "PASSWD", "PWD", "API", "AUTH"]
                if key.hasPrefix("AWS_") || sensitive.contains(where: { key.contains($0) }) {
                    tokens[index] = String(token[..<equals]) + "=•••"
                    continue
                }
            }
            let flag = token.lowercased()
            if (flag == "--password" || flag == "--token" || flag == "-p" || flag == "--secret"
                || flag == "--api-key"), index + 1 < tokens.count {
                tokens[index + 1] = "•••"
            }
            if token == "Bearer", index + 1 < tokens.count {
                tokens[index + 1] = "•••"
            }
        }
        return tokens.joined(separator: " ")
    }

    private static func shellCommandAfterSigil(_ line: String) -> String? {
        let characters = Array(line)
        guard !characters.isEmpty else { return nil }
        for index in stride(from: characters.count - 1, through: 0, by: -1) {
            guard ActivationPolicy.shellPromptSigils.contains(characters[index]) else { continue }
            guard index + 1 < characters.count, characters[index + 1] == " " else { continue }
            if (characters[index] == "#" || characters[index] == "%"), index == 0 { continue }
            return String(characters[(index + 2)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
