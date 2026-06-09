// ScreenContextProvider — FR-CTX-1 screen-aware OCR context (Free tier).
// One-shot capture of the FOCUSED window via ScreenCaptureKit (SCScreenshotManager.captureImage,
// no SCStream), then local OCR with the modern async Vision RecognizeTextRequest. Throttled to
// <=1 capture/sec; results held transiently in memory and NEVER written to disk. Degrades to nil
// whenever capture/OCR is unavailable (permission missing, no focused window, old OS, any error).
import AppKit
import Foundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import Vision

final class ScreenContextProvider {
    // Throttle + cache: at most one real capture per second; otherwise serve the cached result.
    private let minInterval: TimeInterval = 1.0
    private var lastCaptureAt: Date?
    private var cachedText: String?
    // recentText() is invoked from a detached Task on every fire(), so calls can overlap; this guards
    // the throttle/cache state against torn cross-thread access (held only around quick accesses,
    // never across an await).
    private let stateLock = NSLock()

    init() {}

    // Returns recent on-screen text from the focused window (capped to maxChars), or nil if
    // unavailable. The modern async Vision text request landed in macOS 15; below that we no-op.
    func recentText(maxChars: Int) async -> String? {
        guard maxChars > 0 else { return nil }

        // Throttle + state access go through synchronous helpers so the lock is never held across an
        // await (which the locked-state accessors below guarantee).
        let gate = beginCaptureOrServeCached()
        guard gate.proceed else { return Self.clamp(gate.cached, to: maxChars) }

        guard #available(macOS 14.0, *) else { return nil }

        guard let image = await captureFocusedWindow() else {
            return Self.clamp(currentCachedText(), to: maxChars)
        }
        guard let text = await Self.recognizeText(in: image) else {
            return Self.clamp(currentCachedText(), to: maxChars)
        }

        // Drop obvious UI chrome (buttons, prices, chips) BEFORE clamp so the budget + tail go to real
        // prose, not noise like "Send" / "$39" / "Become a Founder".
        let cleaned = Self.denoise(text)
        storeCachedText(cleaned)
        return Self.clamp(cleaned, to: maxChars)
    }

    // Throttle decision + state accessors, each holding `stateLock` only for a synchronous critical
    // section (never across an await). `beginCaptureOrServeCached` atomically decides whether to run a
    // fresh capture (marking the throttle window) or to serve the cached text.
    private func beginCaptureOrServeCached() -> (proceed: Bool, cached: String?) {
        stateLock.lock(); defer { stateLock.unlock() }
        if let last = lastCaptureAt, Date().timeIntervalSince(last) < minInterval {
            return (false, cachedText)
        }
        lastCaptureAt = Date()
        return (true, nil)
    }

    private func currentCachedText() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return cachedText
    }

    private func storeCachedText(_ text: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        cachedText = text
    }

    // MARK: Capture

    // Picks the frontmost app's frontmost on-screen window and captures just that window's bounds.
    // Tight crop matters: OCR latency is dominated by region size (per FR-CTX-1).
    private func captureFocusedWindow() async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let window = focusedWindow(in: content.windows) else {
                Diag.log("ocr: no focused window (windows=\(content.windows.count))")
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            // Crop tightly to the window's pixel bounds (Retina-aware via scaleFactor).
            let scale = window.windowID == 0 ? 1.0 : Self.pointScale(for: window)
            config.width = max(1, Int(window.frame.width * scale))
            config.height = max(1, Int(window.frame.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.scalesToFit = true

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            // Screen Recording permission missing, window gone, etc. -> degrade to nil.
            Diag.log("ocr: capture FAILED \(error)")
            return nil
        }
    }

    // Best-effort "focused window": the frontmost regular app's frontmost window. Falls back to the
    // first on-screen window owned by the frontmost app. nil if nothing matches.
    private func focusedWindow(in windows: [SCWindow]) -> SCWindow? {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let candidates = windows.filter { win in
            guard win.isOnScreen, win.frame.width > 1, win.frame.height > 1 else { return false }
            if let pid = frontPid, let owner = win.owningApplication {
                return owner.processID == pid
            }
            return false
        }
        // Higher windowLayer == frontmost; prefer the largest among the topmost layer.
        return candidates
            .sorted { lhs, rhs in
                if lhs.windowLayer != rhs.windowLayer { return lhs.windowLayer > rhs.windowLayer }
                return (lhs.frame.width * lhs.frame.height) > (rhs.frame.width * rhs.frame.height)
            }
            .first
    }

    private static func pointScale(for window: SCWindow) -> CGFloat {
        // Map the window's screen to its backing scale; default to main screen / 2.0 on Retina.
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) {
            return screen.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    // MARK: OCR (classic Vision — VNRecognizeTextRequest)

    // The newer Swift `RecognizeTextRequest.perform(on:)` returned 0 observations on a valid
    // text-rich frame here, so use the long-stable VNImageRequestHandler + VNRecognizeTextRequest
    // path (available since macOS 10.15). Synchronous perform runs on the caller's background Task.
    private static func recognizeText(in image: CGImage) async -> String? {
        let request = makeRecognizeTextRequest(preferredLanguages: Locale.preferredLanguages)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            // Order observations into reading order (top→bottom, then left→right). Vision uses a
            // bottom-left normalized origin, so higher y == higher on screen == earlier. This makes
            // the joined text coherent and, since clamp() keeps the TAIL, leaves the bottom-of-screen
            // text — the most recent messages nearest the composer — as the surviving context.
            let sorted = observations.sorted { a, b in
                let ay = a.boundingBox.origin.y, by = b.boundingBox.origin.y
                if abs(ay - by) > 0.012 { return ay > by }
                return a.boundingBox.origin.x < b.boundingBox.origin.x
            }
            let joined = sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            Diag.log("ocr: vision observations=\(observations.count) chars=\(joined.count)")
            return joined.isEmpty ? nil : joined
        } catch {
            Diag.log("ocr: vision perform threw \(error)")
            return nil
        }
    }

    // Build the Vision text request. OCR runs only on focus-in (throttled <=1/s, off the keystroke hot
    // path), so .accurate + language correction are affordable and stop multilingual prose (e.g. Spanish
    // accents) from being mangled into digit/symbol noise that would poison the prompt context.
    // `preferredLanguages` are passed in (Locale.preferredLanguages in prod) so this stays pure + testable.
    static func makeRecognizeTextRequest(preferredLanguages: [String]) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Bias recognition toward the user's languages; fall back to detection when the list is empty.
        let langs = preferredLanguages.filter { !$0.isEmpty }
        if !langs.isEmpty { request.recognitionLanguages = langs }
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
        return request
    }

    // MARK: Helpers

    // Keep the most recent text by clamping to the tail (most recently typed/visible context).
    static func clamp(_ text: String?, to maxChars: Int) -> String? {
        guard let text, !text.isEmpty, maxChars > 0 else { return nil }
        if text.count <= maxChars { return text }
        return String(text.suffix(maxChars))
    }

    // Conservative chrome filter: drop short, punctuation-free lone-token lines — the shape of buttons,
    // prices, tab chips, and badges ("Send", "$39", "Tranche 1"). Anything with sentence punctuation or
    // more than two words is kept, so real prose (even short) survives. Pure + testable.
    // `dropShortLines` removes lone-token lines (the OCR-chrome rule). The AX page-text path passes
    // false: that text is EXACT (no OCR noise to guard against), and the short lines it drops are often
    // real signature/name rows ("Jane Appleseed", "VP Sales") that the model needs to complete a
    // name — the exact case a competitor's screen read handles. URLs/ellipsis/digit chrome are still
    // dropped regardless of source.
    static func denoise(_ text: String, dropShortLines: Bool = true) -> String {
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return false }
            // Drop truncated UI list rows (sidebar previews, menu items, recents): they end in an
            // ellipsis and are chrome, not prose the user is composing.
            if t.hasSuffix("...") || t.hasSuffix("…") { return false }
            // Drop bare URLs / link-list rows — noise that primes odd continuations.
            if t.lowercased().hasPrefix("http") { return false }
            // Drop date/time/number chrome — timestamps, date headers ("3 June 2026 at 08:20"),
            // dd/mm/yyyy, prices, "25 notes", ID chips. A base model fed this numeric noise as
            // `Context:` emits stray-digit garbage continuations ("2 el 2 es un salto"), the exact
            // bug we hunt. The ≤2-word rule below already catches "$39"/"25 notes"; this also kills
            // multi-word date lines the word-count rule keeps.
            if isDigitHeavy(t) { return false }
            guard dropShortLines else { return true }
            let words = t.split(separator: " ").count
            let hasSentencePunct = t.contains { ".?!,:;".contains($0) }
            return !(words <= 2 && t.count <= 16 && !hasSentencePunct)
        }
        return kept.joined(separator: "\n")
    }

    // True when digits make up more than 30% of the line's non-whitespace characters — the shape of
    // date/time headers, timestamps, prices, and ID chips, not prose. Real sentences that merely
    // mention a year or count stay well under the threshold ("We met in 2019 at the conference" ≈ 11%).
    // Pure + testable.
    static func isDigitHeavy(_ line: String) -> Bool {
        var digits = 0, visible = 0
        for ch in line where !ch.isWhitespace {
            visible += 1
            if ch.isNumber { digits += 1 }
        }
        guard visible > 0 else { return false }
        return Double(digits) / Double(visible) > 0.30
    }

    // Drop the OCR block entirely when, after dedup + denoise, it carries no substantial prose — only
    // truncated nav chrome (sidebar rows, section headers, "Ad 8-"). For AX-readable apps the useful
    // text is already the prompt `prefix`, so a chrome-only block just primes garbage continuations;
    // returning nil falls the prompt back to prefix-only (KV-reuse-safe and proven clean). "Substantial"
    // = at least `minProseChars` of characters living on lines of >= 3 whitespace-delimited words. A
    // chat history (full-sentence messages) clears this easily; a Notes sidebar does not. Pure + testable.
    static func substantialContextOrNil(_ text: String?, minProseChars: Int = 40) -> String? {
        guard let text else { return nil }
        var proseChars = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.split(whereSeparator: { $0.isWhitespace }).count >= 3 { proseChars += t.count }
        }
        return proseChars >= minProseChars ? text : nil
    }

    // Strip the focused document itself from the OCR context. In AX-readable apps (Notes, mail, docs)
    // the text-before-caret already arrives as the prompt `prefix`, and the SAME text is also visible
    // on screen — so OCR re-captures it. Feeding that duplicate back as `Context:` makes the base model
    // regurgitate the on-screen copy ("…una noche va a un baile…" -> ghost loops "y el baile y esa es
    // una historia"). Drop any OCR line the prefix already contains, leaving only genuinely-new screen
    // text (a chat history above the composer, another window). Lines under `minEchoLen` are left to
    // denoise — too short to be a meaningful echo and risky to match. Pure + testable.
    static func removingDocumentEcho(_ text: String?, prefix: String, minEchoLen: Int = 10) -> String? {
        guard let text else { return nil }
        let hay = prefix.lowercased()
        guard !hay.isEmpty else { return text }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.count < minEchoLen { return true }
            return !hay.contains(t.lowercased())
        }
        let out = kept.joined(separator: "\n")
        return out.isEmpty ? nil : out
    }

    // Strip the trailing quoted-reply block (Gmail/Outlook/etc.) — the "On <date>, <name> wrote:"
    // attribution line plus subsequent ">"-quoted lines, AND the Outlook-style
    // "-----Original Message-----" separator + everything after it (From:/Sent:/To:/Subject: header
    // and quoted body). The quoted text is a verbatim duplicate of the message being replied to,
    // which already appears as fresh prose ABOVE in the AX page text; leaving it in primes the model
    // to keep quoting instead of write a reply. Covers EN/ES/FR/DE/NL/IT/PT attribution-suffix
    // wording plus the canonical Outlook separators. Pure + testable. NOTE: caller MUST host-gate to
    // web mail — ">"-prefixed lines are valid Markdown blockquotes / shell prompts elsewhere.
    static func removingQuotedReplyBlock(_ text: String?) -> String? {
        guard let text else { return nil }
        var lines = Array(text.split(separator: "\n", omittingEmptySubsequences: false))
        // Outlook separator marks a hard boundary — everything below is the original message header
        // ("From: …", "Sent: …", "To: …", "Subject: …") followed by the quoted body. Cut at the marker.
        if let cut = lines.firstIndex(where: { isOriginalMessageSeparator(String($0).trimmingCharacters(in: .whitespaces)) }) {
            lines = Array(lines[..<cut])
        }
        let kept = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return true }
            if t.hasPrefix(">") { return false }
            if isQuotedReplyAttribution(t) { return false }
            return true
        }
        let out = kept.joined(separator: "\n")
        return out.isEmpty ? nil : out
    }

    // True when a trimmed line looks like an email-client attribution prologue ("On Mon, Alice
    // <a@x.com> wrote:" / "El lunes, Alicia <a@x.com> escribió:" / "Le ... a écrit :" …). Conservative:
    // requires both the trailing colon AND one of the language-specific verb suffixes, so a random
    // sentence ending in "wrote:" still has to lead with one of those terminator forms. Pure + testable.
    static func isQuotedReplyAttribution(_ trimmed: String) -> Bool {
        let l = trimmed.lowercased()
        // Multi-line attributions also end the FIRST line without a colon ("On Mon, Jun 4, 2026,") and
        // close on the next; this rule fires on the closer line, which is the one carrying "wrote:".
        let needles = [
            "wrote:",          // English
            "escribió:",       // Spanish
            "a écrit :",       // French (NBSP-safe colon split)
            "a écrit:",
            "schrieb:",        // German
            "schreef:",        // Dutch
            "ha scritto:",     // Italian
            "escreveu:",       // Portuguese
        ]
        return needles.contains { l.hasSuffix($0) }
    }

    // True when a trimmed line is an Outlook "Original Message" separator — a row of dashes wrapping
    // a localized "Original Message" / "Mensaje original" / "Message d'origine" / "Ursprüngliche
    // Nachricht" / "Messaggio originale" / "Mensagem original" label. Pure + testable.
    static func isOriginalMessageSeparator(_ trimmed: String) -> Bool {
        let l = trimmed.lowercased()
        guard l.hasPrefix("---") && l.hasSuffix("---") else { return false }
        let labels = [
            "original message",            // English
            "mensaje original",            // Spanish
            "message d'origine",           // French
            "ursprüngliche nachricht",     // German
            "oorspronkelijk bericht",      // Dutch
            "messaggio originale",         // Italian
            "mensagem original",           // Portuguese
        ]
        return labels.contains { l.contains($0) }
    }

    // The trailing quoted block of a user's typed prefix. Strips ">"-quoted + attribution lines + the
    // Outlook "Original Message" separator AND every line after it, at the TAIL only — so a user who
    // already typed real prose after the quote keeps that prose. Used to recover an empty/ignorable
    // prefix when the caret is parked inside the quoted history (Gmail "Show trimmed content" reveal
    // or Outlook reply). Pure + testable.
    static func stripTrailingQuotedBlock(_ prefix: String) -> String {
        var lines = Array(prefix.split(separator: "\n", omittingEmptySubsequences: false))
        let originalCount = lines.count
        // If the prefix contains an Outlook separator, EVERYTHING from it onward is quoted history —
        // truncate first so the line-by-line walk below sees a clean tail.
        if let sep = lines.firstIndex(where: { isOriginalMessageSeparator(String($0).trimmingCharacters(in: .whitespaces)) }) {
            lines = Array(lines[..<sep])
        }
        var cut = lines.count
        var i = lines.count - 1
        while i >= 0 {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix(">") || isQuotedReplyAttribution(t) {
                cut = i
                i -= 1
            } else {
                break
            }
        }
        // Nothing trimmed (no separator + clean tail) → preserve the input byte-for-byte so the
        // caller's identity check (== input) holds and the prompt KV stays warm.
        if lines.count == originalCount && cut == lines.count { return prefix }
        return lines[..<cut].joined(separator: "\n")
    }

    // Strip the user's own current draft from the OCR so it isn't duplicated with the prompt prefix.
    // Removes any line equal to, or starting with, the draft's trailing line (the latter also catches a
    // ghost the OCR captured AFTER the draft, e.g. "Lighter apple pieIngredients…"). No-op for drafts
    // under 3 chars (too short to match safely). Pure + testable.
    static func removingDraftEcho(_ text: String?, draft: String) -> String? {
        guard let text else { return nil }
        let tail = (draft.split(whereSeparator: \.isNewline).last.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard tail.count >= 3 else { return text }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !(t == tail || t.hasPrefix(tail))
        }
        let out = kept.joined(separator: "\n")
        return out.isEmpty ? nil : out
    }
}
