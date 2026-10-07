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
    // AppKit exposes this Accessibility attribute but does not import a Swift constant for it.
    private static let axWindowNumberAttribute = "AXWindowNumber" as CFString

    // At most one real capture per second. A successful OCR result is only reusable briefly: screen
    // context is volatile and must never follow the user into another focused field.
    private let minInterval: TimeInterval = 1.0
    private let cacheTTL: TimeInterval = 1.0
    private var cacheState = CacheState()
    // recentText() is invoked from a detached Task on every fire(), so calls can overlap; this guards
    // the throttle/cache state against torn cross-thread access (held only around quick accesses,
    // never across an await).
    private let stateLock = NSLock()

    init() {}

    struct CaptureTicket: Equatable {
        fileprivate let generation: UInt64
    }

    enum CacheDecision: Equatable {
        case capture(CaptureTicket)
        case cached(String)
        case suppressed
    }

    struct CacheState {
        private var lastCaptureAt: Date?
        private var cachedText: String?
        private var cachedAt: Date?
        private var generation: UInt64 = 0

        mutating func begin(at now: Date, cacheTTL: TimeInterval,
                            minInterval: TimeInterval) -> CacheDecision {
            if let cachedText, let cachedAt {
                let age = now.timeIntervalSince(cachedAt)
                if age >= 0, age < cacheTTL { return .cached(cachedText) }
                self.cachedText = nil
                self.cachedAt = nil
            }
            if let lastCaptureAt, now.timeIntervalSince(lastCaptureAt) < minInterval {
                return .suppressed
            }
            lastCaptureAt = now
            return .capture(CaptureTicket(generation: generation))
        }

        @discardableResult
        mutating func store(_ text: String, for ticket: CaptureTicket, at now: Date) -> Bool {
            guard ticket.generation == generation else { return false }
            cachedText = text
            cachedAt = now
            return true
        }

        mutating func captureFailed(for ticket: CaptureTicket) {
            guard ticket.generation == generation else { return }
            cachedText = nil
            cachedAt = nil
        }

        mutating func focusDidChange() {
            generation &+= 1
            lastCaptureAt = nil
            cachedText = nil
            cachedAt = nil
        }
    }

    /// What one capture attempt came back with. Only `.noWindow` and `.unavailable` mean "this focus session
    /// cannot be captured at all"; `.empty` and `.throttled` are ordinary (a blank chat, a second capture
    /// inside `minInterval`) and must never switch OCR context off for the field.
    enum RecentTextOutcome: Equatable {
        case text(String)
        case empty          // Vision found nothing, or denoise stripped everything (e.g. a new chat with only UI)
        case throttled      // a capture less than minInterval after the previous one
        case noWindow       // the focused window could not be resolved at all
        case unavailable    // ScreenCaptureKit failed (Screen Recording missing, window gone, ...)

        var text: String? { if case .text(let t) = self { return t }; return nil }
        var cannotCapture: Bool { self == .noWindow || self == .unavailable }
    }

    private enum CaptureResult {
        case image(CGImage)
        case noWindow
        case unavailable
    }

    // Returns recent on-screen text from the focused window (capped to maxChars), or nil if
    // unavailable. The modern async Vision text request landed in macOS 15; below that we no-op.
    func recentText(maxChars: Int) async -> String? {
        await recentTextOutcome(maxChars: maxChars).text
    }

    // Same capture, but says WHY there is no text (see `RecentTextOutcome`).
    func recentTextOutcome(maxChars: Int) async -> RecentTextOutcome {
        guard maxChars > 0 else { return .empty }

        // Throttle + state access go through synchronous helpers so the lock is never held across an
        // await (which the locked-state accessors below guarantee).
        let gate = beginCaptureOrServeCached()
        switch gate {
        case .cached(let text):
            guard let clamped = Self.clamp(text, to: maxChars) else { return .empty }
            return .text(clamped)
        case .suppressed:
            return .throttled
        case .capture(let ticket):
            guard #available(macOS 14.0, *) else {
                captureFailed(ticket)
                return .unavailable
            }

            let captured = await captureFocusedWindow()
            guard case .image(let image) = captured else {
                captureFailed(ticket)
                if case .noWindow = captured { return .noWindow }
                return .unavailable
            }
            guard let text = await Self.recognizeText(in: image) else {
                Diag.log("ocr: capture yielded no text")
                captureFailed(ticket)
                return .empty
            }

            // Drop obvious UI chrome (buttons, prices, chips) BEFORE clamp so the budget + tail go to
            // real prose, not noise like "Send" / "$39" / "Become a Founder".
            let cleaned = Self.denoise(text)
            guard !cleaned.isEmpty else {
                captureFailed(ticket)
                return .empty
            }
            storeCachedText(cleaned, for: ticket)
            guard let clamped = Self.clamp(cleaned, to: maxChars) else { return .empty }
            return .text(clamped)
        }
    }

    // Called by the focus owner as soon as it observes a new focused field/window. In-flight captures
    // are generation-tagged, so a capture that finishes after this reset cannot repopulate this cache.
    func focusDidChange() {
        stateLock.lock(); defer { stateLock.unlock() }
        cacheState.focusDidChange()
    }

    // State accessors hold `stateLock` only for their short synchronous critical sections, never across
    // an await. `CacheState` is deliberately pure so its expiry/failure/focus behavior stays unit-testable.
    private func beginCaptureOrServeCached() -> CacheDecision {
        stateLock.lock(); defer { stateLock.unlock() }
        return cacheState.begin(at: Date(), cacheTTL: cacheTTL, minInterval: minInterval)
    }

    private func storeCachedText(_ text: String, for ticket: CaptureTicket) {
        stateLock.lock(); defer { stateLock.unlock() }
        _ = cacheState.store(text, for: ticket, at: Date())
    }

    private func captureFailed(_ ticket: CaptureTicket) {
        stateLock.lock(); defer { stateLock.unlock() }
        cacheState.captureFailed(for: ticket)
    }

    // MARK: Capture

    // Captures the exact AX-focused on-screen window. Tight crop matters: OCR latency is dominated
    // by region size (per FR-CTX-1).
    private func captureFocusedWindow() async -> CaptureResult {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let window = focusedWindow(in: content.windows) ?? focusedWindowByFrame(in: content.windows) else {
                Diag.log("ocr: no focused window (windows=\(content.windows.count))")
                return .noWindow
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

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            Diag.log("ocr: capture window=\(Int(window.frame.width))x\(Int(window.frame.height))pt image=\(image.width)x\(image.height)px")
            return .image(image)
        } catch {
            // Screen Recording permission missing, window gone, etc. -> degrade.
            Diag.log("ocr: capture FAILED \(error)")
            return .unavailable
        }
    }

    // Resolve the AX-focused element's enclosing AXWindow to its CG window number, then require the
    // exact ScreenCaptureKit window owned by the frontmost process. Do not guess by size/layer: a wrong
    // window can leak unrelated text into a completion, so unresolved AX data fails closed.
    // The ONE exception is a host that exposes no AXWindowNumber at all (Chromium/Electron): see
    // `focusedWindowByFrame`, which accepts only the frontmost process's single on-screen layer-0 window
    // whose frame equals the AX focused window's frame, and still fails closed otherwise.
    private func focusedWindow(in windows: [SCWindow]) -> SCWindow? {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let focusedWindowID = Self.focusedAXWindowID(for: frontmostPID) else { return nil }
        let candidates = windows.map {
            WindowCandidate(windowID: $0.windowID, owningPID: $0.owningApplication?.processID,
                            isOnScreen: $0.isOnScreen)
        }
        guard let selectedID = Self.resolvedFocusedWindowID(
            focusedWindowID: focusedWindowID, frontmostPID: frontmostPID, candidates: candidates) else {
            return nil
        }
        return windows.first { $0.windowID == selectedID }
    }

    // Chromium/Electron windows (the Claude desktop app, Codex) expose NO `AXWindowNumber`, so the
    // exact-id match above can never succeed and OCR would fail forever. Fall back to matching the AX
    // focused window of the frontmost process by pid + frame. Still fails closed: it needs exactly one
    // on-screen layer-0 window of that process at that frame, so another app's text can never leak in.
    private func focusedWindowByFrame(in windows: [SCWindow]) -> SCWindow? {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let axFrame = Self.focusedAXWindowFrame(for: frontmostPID) else { return nil }
        let candidates = windows.map {
            FrameCandidate(windowID: $0.windowID, owningPID: $0.owningApplication?.processID,
                           isOnScreen: $0.isOnScreen, layer: Int($0.windowLayer), frame: $0.frame)
        }
        guard let id = Self.resolvedWindowIDByFrame(
            axFrame: axFrame, frontmostPID: frontmostPID, candidates: candidates) else { return nil }
        return windows.first { $0.windowID == id }
    }

    private static func focusedAXWindowFrame(for pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRef, CFGetTypeID(winRef) == AXUIElementGetTypeID() else { return nil }
        let win = winRef as! AXUIElement
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &sz), sz.width > 0, sz.height > 0 else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    struct FrameCandidate: Equatable {
        let windowID: CGWindowID
        let owningPID: pid_t?
        let isOnScreen: Bool
        let layer: Int
        let frame: CGRect
    }

    /// Pure (testable): the single on-screen, layer-0 window of `frontmostPID` whose frame equals the
    /// AX focused window's frame (within `tolerance` points). nil if none or more than one.
    static func resolvedWindowIDByFrame(axFrame: CGRect, frontmostPID: pid_t, candidates: [FrameCandidate],
                                        tolerance: CGFloat = 2) -> CGWindowID? {
        let matches = candidates.filter {
            $0.owningPID == frontmostPID && $0.isOnScreen && $0.layer == 0
                && abs($0.frame.minX - axFrame.minX) <= tolerance
                && abs($0.frame.minY - axFrame.minY) <= tolerance
                && abs($0.frame.width - axFrame.width) <= tolerance
                && abs($0.frame.height - axFrame.height) <= tolerance
        }
        return matches.count == 1 ? matches[0].windowID : nil
    }

    private static func focusedAXWindowID(for frontmostPID: pid_t,
                                          system: AXUIElement = AXUIElementCreateSystemWide()) -> CGWindowID? {
        var elementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &elementRef) == .success,
              let elementRef, CFGetTypeID(elementRef) == AXUIElementGetTypeID() else { return nil }
        let element = elementRef as! AXUIElement

        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success,
              elementPID == frontmostPID else { return nil }

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }

        var numberRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            windowRef as! AXUIElement, Self.axWindowNumberAttribute, &numberRef) == .success,
              let number = numberRef as? NSNumber, number.int64Value > 0 else { return nil }
        return CGWindowID(number.uint32Value)
    }

    struct WindowCandidate: Equatable {
        let windowID: CGWindowID
        let owningPID: pid_t?
        let isOnScreen: Bool
    }

    static func resolvedFocusedWindowID(focusedWindowID: CGWindowID?, frontmostPID: pid_t?,
                                        candidates: [WindowCandidate]) -> CGWindowID? {
        guard let focusedWindowID, let frontmostPID else { return nil }
        return candidates.first {
            $0.windowID == focusedWindowID && $0.owningPID == frontmostPID && $0.isOnScreen
        }?.windowID
    }

    static func preferredWindowIndex(in candidates: [(layer: Int, area: Double)]) -> Int? {
        let normal = candidates.indices.filter { candidates[$0].layer == 0 }
        let eligible = normal.isEmpty ? Array(candidates.indices) : normal
        return eligible.max { candidates[$0].area < candidates[$1].area }
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

    // Keep the most recent text by clamping to the tail (most recently typed/visible context), CUT ON A
    // LINE BOUNDARY. A raw character suffix slid by one character per keystroke as the draft grew, so the
    // kept window — and with it the `Context:` block that sits in FRONT of the prefix — changed
    // byte-for-byte on every fire. The engine's KV reuse is a longest-common-PREFIX match, so that cost a
    // full cold re-prefill on every single fire. Dropping whole leading lines instead holds the block's
    // head still until an entire line falls out of the budget. Only a single line longer than the whole
    // budget falls back to a character cut (there is no boundary left to cut on).
    static func clamp(_ text: String?, to maxChars: Int) -> String? {
        guard let text, !text.isEmpty, maxChars > 0 else { return nil }
        if text.count <= maxChars { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var total = 0
        for line in lines.reversed() {
            let cost = line.count + (kept.isEmpty ? 0 : 1)   // +1 for the newline that rejoins it
            if total + cost > maxChars { break }
            total += cost
            kept.append(line)
        }
        guard !kept.isEmpty else { return String(text.suffix(maxChars)) }
        return kept.reversed().joined(separator: "\n")
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
    // ghost the OCR captured AFTER the draft, e.g. "Lighter apple pieIngredients…") — AND, in the other
    // direction, a captured line the draft now starts with.
    //
    // That reverse case is the one that leaked: the capture is STALE between shots (≤1/s), so the instant
    // the user types past the captured point the captured line is SHORTER than `tail`,
    // `t.hasPrefix(tail)` goes false, the line stops being filtered, and the draft echo flows back into
    // the `Context:` block — the documented doc-echo word-salad, and (since the prompt-head work) a
    // per-keystroke mutation of the prompt FRONT that also destroys anchored KV reuse. The reverse match
    // needs its own floor (`minStaleLen`): a short generic captured line ("Hi", "Thanks") is a prefix of
    // half the drafts on screen and would over-filter genuine context. No-op for drafts under 3 chars
    // (too short to match safely). Pure + testable.
    static func removingDraftEcho(_ text: String?, draft: String, minStaleLen: Int = 8) -> String? {
        guard let text else { return nil }
        let tail = (draft.split(whereSeparator: \.isNewline).last.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard tail.count >= 3 else { return text }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == tail || t.hasPrefix(tail) { return false }
            // Stale capture: the line is an earlier, shorter state of the line being typed.
            return !(t.count >= minStaleLen && tail.hasPrefix(t))
        }
        let out = kept.joined(separator: "\n")
        return out.isEmpty ? nil : out
    }
}
