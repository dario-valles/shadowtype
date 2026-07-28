import ApplicationServices
import Foundation

struct SuggestionAcceptor {
    private let injector: Injector?
    private let context: EditContextTracker

    init(injector: Injector?, context: EditContextTracker) {
        self.injector = injector
        self.context = context
    }

    func acceptanceTarget(
        suggestionFocusSeq: UInt64?,
        onStale: () -> Void
    ) -> AXUIElement? {
        guard let target = context.focusedElement(),
              suggestionFocusSeq == context.focusChangeSequence else {
            onStale()
            return nil
        }
        return target
    }

    func inject(_ text: String, into target: AXUIElement) -> Bool {
        injector?.inject(text, into: target) ?? false
    }

    func replaceBeforeCaret(
        utf16Length: Int,
        keystrokeCount: Int,
        with replacement: String,
        in target: AXUIElement
    ) -> Bool {
        injector?.replaceBeforeCaret(
            utf16Length: utf16Length,
            keystrokeCount: keystrokeCount,
            with: replacement,
            in: target
        ) ?? false
    }

    static func nextWord(from text: String) -> String {
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        while index < text.endIndex, !text[index].isWhitespace {
            index = text.index(after: index)
        }
        return String(text[text.startIndex..<index])
    }

    static func firstLine(from text: String) -> String {
        guard let newline = text.firstIndex(of: "\n") else { return text }
        return String(text[..<newline])
    }
}
