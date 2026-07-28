import Foundation
import NaturalLanguage

final class CompletionContextAssembler {
    enum CaptureState {
        case idle
        case pending
        case ready
    }

    struct PreparedPrompt {
        let prompt: String
        let byteBudget: Int?
        let cacheKey: PromptSectionBudget.CacheKey?
    }

    private let ocrLock = NSLock()
    private var ocrCache: String?
    var ocrLanguage: NLLanguage?
    var pendingWarm: (prefix: String, postCaret: String?)?
    var captureState: CaptureState = .idle
    var refireCount = 0

    private let styleLock = NSLock()
    private var styleHint: String?

    private let tokenizerBudgetLock = NSLock()
    private var tokenizerValidatedBudgets: [PromptSectionBudget.CacheKey: Int] = [:]

    var cachedOCR: String? {
        ocrLock.lock()
        let value = ocrCache
        ocrLock.unlock()
        return value
    }

    var cachedStyleHint: String? {
        styleLock.lock()
        let value = styleHint
        styleLock.unlock()
        return value
    }

    func setStyleHint(_ value: String?) {
        styleLock.lock()
        styleHint = value
        styleLock.unlock()
    }

    func markCapturePendingIfEmpty() {
        if cachedOCR == nil {
            captureState = .pending
        }
    }

    @discardableResult
    func storeOCR(
        _ text: String?,
        detectLanguage: (String) -> NLLanguage?
    ) -> Bool {
        ocrLock.lock()
        let changed = !Self.ocrTextEquivalent(ocrCache, text)
        if changed {
            ocrCache = text
        }
        ocrLock.unlock()
        if changed {
            ocrLanguage = text.flatMap(detectLanguage)
        }
        return changed
    }

    func clearOCR() {
        _ = storeOCR(nil) { _ in nil }
    }

    func tokenizerBudgetedPrompt(
        defaultBudget: Int,
        effectiveTokenCap: Int,
        assemble: (Int) -> String
    ) -> PreparedPrompt {
        let initial = assemble(defaultBudget)
        let key = PromptSectionBudget.CacheKey(
            profile: PromptSectionBudget.tokenDensityProfile(initial),
            tokenCap: effectiveTokenCap
        )
        tokenizerBudgetLock.lock()
        let cachedBudget = tokenizerValidatedBudgets[key]
        tokenizerBudgetLock.unlock()
        guard let cachedBudget, cachedBudget < defaultBudget else {
            return PreparedPrompt(prompt: initial, byteBudget: defaultBudget, cacheKey: key)
        }
        return PreparedPrompt(
            prompt: assemble(cachedBudget),
            byteBudget: cachedBudget,
            cacheKey: key
        )
    }

    func storeTokenizerValidatedBudget(_ budget: Int, for key: PromptSectionBudget.CacheKey) {
        tokenizerBudgetLock.lock()
        tokenizerValidatedBudgets[key] = min(tokenizerValidatedBudgets[key] ?? budget, budget)
        tokenizerBudgetLock.unlock()
    }

    static func captureLatchMatches(
        capturedGeneration: Int,
        currentGeneration: Int,
        capturedFocusSeq: UInt64,
        currentFocusSeq: UInt64,
        capturedBundleId: String?,
        currentBundleId: String?
    ) -> Bool {
        capturedGeneration == currentGeneration
            && capturedFocusSeq == currentFocusSeq
            && capturedBundleId == currentBundleId
    }

    static func dedupedCapture(_ text: String?, prefix: String) -> String? {
        let withoutDocument = ScreenContextProvider.removingDocumentEcho(text, prefix: prefix)
        return ScreenContextProvider.removingDraftEcho(withoutDocument, draft: prefix)
    }

    static func ocrTextEquivalent(_ lhs: String?, _ rhs: String?) -> Bool {
        normalizeOCRForCompare(lhs) == normalizeOCRForCompare(rhs)
    }

    static func normalizeOCRForCompare(_ text: String?) -> String {
        guard let text else { return "" }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func shouldRefire(count: Int, maximum: Int) -> Bool {
        count < maximum
    }

    static func prefixAfterEmailQuoteStrip(_ prefix: String?, host: String?) -> String? {
        guard let prefix, ActivationPolicy.isWebMailHost(host) else { return prefix }
        let stripped = ScreenContextProvider.stripTrailingQuotedBlock(prefix)
        return stripped == prefix ? prefix : stripped
    }

    static func styleHintChars(forStrength strength: Int) -> Int {
        switch max(0, min(3, strength)) {
        case 0: return 0
        case 1: return 100
        case 2: return 200
        default: return 400
        }
    }

    static func promptBudgetBytes(forContextTokens tokens: Int) -> Int {
        let clampedTokens = min(max(0, tokens), 32_768)
        return max(256, Int(Double(clampedTokens) * 3.5) - 64)
    }

    static let postCaretContextBytes = 240

    static func postCaretBlock(
        _ suffix: String?,
        maxBytes: Int = postCaretContextBytes
    ) -> String? {
        guard let suffix else { return nil }
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let windowed = PromptSectionBudget.headWithinCost(trimmed, maxCost: maxBytes)
        return windowed.isEmpty ? nil : "After the cursor:\n" + windowed
    }

    static func assemblePrompt(
        prefix: String,
        instruction: String?,
        styleHint: String?,
        styleEnabled: Bool,
        clipboard: String?,
        clipboardEnabled: Bool,
        ocr: String?,
        ocrEnabled: Bool,
        postCaret: String?,
        steerLanguageName: String?,
        totalChars: Int,
        trimmingPrefix: (String) -> String
    ) -> (prompt: String, ocrKept: Bool) {
        let prefix = trimmingPrefix(prefix)
        var sections: [PromptSection] = []

        func add(
            _ content: String?,
            name: String = "ctx",
            priority: Int,
            atomic: Bool = false
        ) {
            guard let content, !content.isEmpty else { return }
            let cost = PromptSectionBudget.cost(content)
            sections.append(
                PromptSection(
                    name: name,
                    content: content,
                    priority: priority,
                    minChars: atomic ? cost : 0,
                    maxChars: cost,
                    truncation: atomic ? .preserveStart : .preserveEnd
                )
            )
        }

        add(instruction, priority: 80, atomic: true)
        if styleEnabled { add(styleHint, priority: 10, atomic: true) }
        if clipboardEnabled { add(clipboard, priority: 40) }
        if ocrEnabled { add(ocr, name: "ocr", priority: 20) }
        add(postCaretBlock(postCaret), name: "postCaret", priority: 30, atomic: true)

        let prefixCap = sections.isEmpty ? totalChars : max(1, totalChars / 100 * 65)
        let windowed = PromptSectionBudget.anchoredTail(prefix, maxCost: prefixCap)
        let outputPrefix = windowed.isEmpty && !prefix.isEmpty ? String(prefix.suffix(1)) : windowed
        let prefixReserve = PromptSectionBudget.quantizedReservation(
            cost: PromptSectionBudget.cost(outputPrefix),
            maxCost: prefixCap
        )
        let contextBudget = sections.isEmpty ? 0 : max(0, totalChars - prefixReserve)
        let allocated = PromptSectionBudget.allocate(sections, totalChars: contextBudget)
        let blocks = allocated.map(\.content)
        let ocrKept = allocated.contains { $0.name == "ocr" }
        guard !blocks.isEmpty else { return (outputPrefix, ocrKept) }
        let marker = steerLanguageName.map { "\n\nText (in \($0)):\n" } ?? "\n\nText:\n"
        return (
            "Context:\n" + blocks.joined(separator: "\n\n") + marker + outputPrefix,
            ocrKept
        )
    }
}
