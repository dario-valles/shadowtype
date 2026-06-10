// EditContextTracker — implemented in P1 (FR-KC-2/4, FR-OV-3).
// Tracks the focused AX text element: caret rect, prefix text, secure-field & frontmost app.
import Cocoa
import ApplicationServices
import Carbon.HIToolbox

final class EditContextTracker {
    var frontmostBundleId: String?

    // Fired on every focus/value/app change (see refreshFocus) so the active-field badge can
    // re-anchor or hide. Called on the main run loop.
    var onFocusChange: (() -> Void)?

    private let system = AXUIElementCreateSystemWide()

    // Monotonic counter that increments whenever the focused element actually changes (a different
    // element, or focus dropping to nil). Distinct from CompletionCoordinator's `generation` (a
    // newest-wins completion counter). Used as a per-focus-session key by the ghost-font stabilizer
    // and the capability-flicker gate so they can reset/scope state to one focused field.
    private(set) var focusChangeSequence: UInt64 = 0

    // Focused element + the AXObserver bound to its owning app pid. Re-created on focus/app change.
    private var focused: AXUIElement?
    private var observer: AXObserver?
    private var observerPid: pid_t = 0
    private var observedElement: AXUIElement?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false

    // Forces lazy Electron/Chromium AX trees to materialize (once per app) so text-marker reads work
    // in VS Code/Cursor/Windsurf/Slack/Arc/Dia without VoiceOver. Harmless on native apps.
    private let electronA11y = ElectronAccessibility()
    // The pid we've already nil-prefix-rewaked during the current focus session. Cleared on
    // refreshFocus so a fresh focus (or app switch) is eligible again. Prevents `rewakeBrowserAXIfPossible`
    // from firing per keystroke on a Gmail tab that's permanently failing to expose its AX tree.
    private var rewakedPidThisFocus: pid_t?

    // Focus seq we last emitted the diagnostic AX-attribute dump for, so the prefix-nil branch dumps
    // a host's attribute surface at most once per focus session (not per keystroke). Diagnostics only.
    private var lastAttrDumpFocusSeq: UInt64 = .max

    // Frame-anchor line-height guards (FR-OV-3/4). A real text line is small; anything taller is a
    // multi-line box whose full height must NOT be used as the line height (it sized a 775pt ghost
    // over a textarea). Above the threshold we fall back to a sane default single-line height.
    static let maxPlausibleLineHeight: CGFloat = 40
    static let defaultLineHeight: CGFloat = 20

    init() {}

    func start() {
        guard !started else { return }
        started = true

        // FR-KC-1 stale-cache bug: AXIsProcessTrusted can report a stale "not trusted" across
        // OS updates / re-signature (Sequoia→Tahoe). CGEvent.tapCreate(.listenOnly) consults live
        // state, so use it to re-validate before relying on AX. We don't keep the tap.
        let live = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                     place: .headInsertEventTap,
                                     options: .listenOnly,
                                     eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                     callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                     userInfo: nil)
        if live == nil && !AXIsProcessTrusted() {
            NSLog("Shadowtype: AX/Input access not granted — EditContextTracker inert until trusted")
        }

        // Track frontmost app for bundle id and to refresh focus when the app switches.
        frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let wc = NSWorkspace.shared.notificationCenter
        let activated = wc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            self?.refreshFocus()
        }
        workspaceObservers.append(activated)

        refreshFocus()
    }

    func stop() {
        guard started else { return }
        started = false
        let wc = NSWorkspace.shared.notificationCenter
        for o in workspaceObservers { wc.removeObserver(o) }
        workspaceObservers.removeAll()
        teardownObserver()
        focused = nil
    }

    func currentPrefix() -> String? {
        return resolvePrefix().map(Self.normalizingSpaces)
    }

    // WebKit contenteditable (Apple Mail's compose, web mail) stores a significant trailing/embedded
    // space as a NON-BREAKING space (U+00A0) and sometimes a narrow/figure NBSP — so a prefix that
    // visually ends in a space actually ends in U+00A0. Downstream gates compare against a literal
    // U+0020 (isMeaningfulBoundary, the trailing-space trim, glue-guard), so an NBSP read as "not a
    // space" silently suppressed the ghost the instant the user pressed space (the Mail bug). Fold the
    // NBSP family to a regular space at the single read chokepoint so every consumer sees U+0020.
    static func normalizingSpaces(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { nbspScalars.contains($0) }) else { return s }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        for u in s.unicodeScalars { out.append(nbspScalars.contains(u) ? " " : u) }
        return String(out)
    }
    private static let nbspScalars: Set<Unicode.Scalar> = [
        "\u{00A0}",  // NO-BREAK SPACE (WebKit contenteditable's trailing-space substitute)
        "\u{202F}",  // NARROW NO-BREAK SPACE
        "\u{2007}",  // FIGURE SPACE
    ]

    private func resolvePrefix() -> String? {
        guard let element = currentFocusedElement(), !isSecure(element) else { return nil }

        // (1) Native path: kAXValue + kAXSelectedTextRange (Cocoa/AppKit fields).
        if let caret = caretLocation(of: element), let text = elementString(element) {
            let p = prefixBeforeCaret(text, caret: caret)
            Diag.log("prefix: ok via=native len=\(p.utf16.count) role=\(roleSubrole(element))")
            return p
        }

        // (2) Web/Electron/Chromium path (Slack/Warp/VS Code): text-marker string before the caret
        // (PRD R2). Read forward-from-caret only — webPrefix is document-start→caret (FR-KC-2).
        if let webText = AXTextProbe.webPrefix(of: element) {
            Diag.log("prefix: ok via=web len=\(webText.utf16.count) role=\(roleSubrole(element))")
            return webText
        }

        // (3) Descend to the real editable text node and retry the native path on it.
        let descended = AXTextProbe.descendToEditable(element)
        if let editable = descended, !isSecure(editable) {
            if let caret = caretLocation(of: editable), let text = elementString(editable) {
                let p = prefixBeforeCaret(text, caret: caret)
                Diag.log("prefix: ok via=descend-native len=\(p.utf16.count) role=\(roleSubrole(editable))")
                return p
            }
            if let webText = AXTextProbe.webPrefix(of: editable) {
                Diag.log("prefix: ok via=descend-web len=\(webText.utf16.count) role=\(roleSubrole(editable))")
                return webText
            }
        }

        // (3.5) Position-derived marker prefix: modern Apple Mail's compose AXWebArea omits
        // AXStartTextMarkerForTextMarkerRange (so the marker chain in webPrefix dead-ends) but DOES
        // answer the caret bounds, AXTextMarkerForPosition, AXStartTextMarker and the unordered-range
        // builder. Derive the caret marker from its on-screen point and read document-start→caret.
        if let s = AXTextProbe.webPrefixViaPosition(of: element), !s.isEmpty {
            Diag.log("prefix: ok via=web-position len=\(s.utf16.count) role=\(roleSubrole(element))")
            return s
        }

        // (4) Give up gracefully rather than feed the model wrong text. The per-step marker probe, index
        // probe and full attribute dump are AX-IPC heavy, so build them ONLY when diag is enabled — on a
        // permanently-unreadable host (Google Docs canvas) this branch fires every keystroke, and in a
        // shipping build (diag off) the eagerly-built Diag.log argument would otherwise still pay for them.
        if Diag.isEnabled {
            Diag.log("prefix: nil role=\(roleSubrole(element)) web=\(AXTextProbe.webPrefixFailureStep(of: element)) idx=[\(AXTextProbe.indexCapabilities(of: element))] descend=\(descended.map { roleSubrole($0) } ?? "none") url=\(frontmostDomainHost() ?? "?")")
            // One-shot per focus session: dump the full AX attribute surface of the focused element, its
            // descended node, and its ancestors — the supported-attribute lists reveal which read path a
            // hollow-proxy web area (modern Mail) actually implements. Gated so it logs once, not per key.
            if lastAttrDumpFocusSeq != focusChangeSequence {
                lastAttrDumpFocusSeq = focusChangeSequence
                dumpAXAttributes(element, descended: descended)
            }
        }
        return nil
    }

    // Diagnostics only: dump the plain + parameterized AX attribute names supported by the focused
    // element, its descended node, and its first few ancestors. The supported-attribute lists reveal
    // which text-read API a hollow-proxy host (modern Mail's AXWebArea) actually implements, so we can
    // target it directly instead of probing attribute names blindly across beta cycles.
    private func dumpAXAttributes(_ element: AXUIElement, descended: AXUIElement?) {
        func attrs(_ el: AXUIElement) -> String {
            var names: CFArray?
            let plain = (AXUIElementCopyAttributeNames(el, &names) == .success ? (names as? [String]) : nil) ?? []
            var pnames: CFArray?
            let param = (AXUIElementCopyParameterizedAttributeNames(el, &pnames) == .success ? (pnames as? [String]) : nil) ?? []
            return "attrs=[\(plain.joined(separator: ","))] param=[\(param.joined(separator: ","))]"
        }
        Diag.log("axdump focused \(roleSubrole(element)) \(attrs(element))")
        if let d = descended { Diag.log("axdump descend \(roleSubrole(d)) \(attrs(d))") }
        var node = parent(of: element)
        var hop = 0
        while let n = node, hop < 4 {
            Diag.log("axdump anc\(hop) \(roleSubrole(n)) \(attrs(n))")
            node = parent(of: n)
            hop += 1
        }
    }

    // Role/subrole of an element as "role/subrole" for diagnostics only (mirrors the role read in
    // AXTextProbe.isEditableLeaf). Cheap; called only on the diag paths above.
    private func roleSubrole(_ element: AXUIElement) -> String {
        var roleRef: CFTypeRef?
        let role = (AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
                    ? roleRef as? String : nil) ?? "?"
        var subRef: CFTypeRef?
        let sub = (AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subRef) == .success
                   ? subRef as? String : nil) ?? "-"
        return "\(role)/\(sub)"
    }

    /// True when the caret is at end-of-line — nothing, or only a line break, follows it. Drives the
    /// per-app "mid-line completions" gate. Best-effort: only the native value+range path can see
    /// post-caret text; the web/marker path (prefix-only) returns true so we never suppress on a
    /// surface where we genuinely can't tell (preserves current behavior there).
    func caretAtLineEnd() -> Bool {
        guard let element = currentFocusedElement(), !isSecure(element) else { return true }
        // Chromium/WebKit contenteditables (Gmail in a browser) expose a flat kAXValue whose newline
        // counting drifts from kAXSelectedTextRange the moment the body has a line break: the native
        // post-caret read then lands mid-string and falsely reports "mid-line", so the ghost dies on
        // line 2+ (the Gmail bug — line 1 has no newline and escapes it). The text-marker protocol
        // reads the actual character after the caret and stays aligned, so trust it in browsers and
        // never suppress when it can't tell. Off the web the native value+range is authoritative.
        if ActivationPolicy.isBrowser(bundleId: frontmostBundleId) {
            // Probe the focused element AND the descended editable; Reddit/Lexical focuses a wrapper whose
            // marker range is nil, so the real answer often lives on the descended text node. Take the
            // first DEFINITE (non-.unavailable) answer; only a definite mid-line suppresses.
            let focused = AXTextProbe.webCaretLinePosition(of: element)
            let descend = AXTextProbe.descendToEditable(element).flatMap { isSecure($0) ? nil : $0 }
                .map { AXTextProbe.webCaretLinePosition(of: $0) } ?? .unavailable
            let probe = focused != .unavailable ? focused : descend
            switch probe {
            case .midLine:
                Diag.log("caretEOL: browser midLine -> SUPPRESS f=\(focused) d=\(descend)")
                return false
            case .lineEnd:
                Diag.log("caretEOL: browser lineEnd f=\(focused) d=\(descend)")
                return true
            case .unavailable:
                Diag.log("caretEOL: browser markers unavailable -> assume EOL f=\(focused) d=\(descend)")
                return true
            }
        }
        if let caret = caretLocation(of: element), let text = elementString(element) {
            let eol = Self.isCaretAtLineEnd(text, caret: caret)
            if !eol { Diag.log("caretEOL: native=false caret=\(caret) count=\(text.utf16.count)") }
            return eol
        }
        // Electron/Chromium NATIVE apps (Slack desktop etc.): native value+range empty, but the
        // text-marker protocol can report the line remainder. .unavailable → fall through to default.
        switch AXTextProbe.webCaretLinePosition(of: element) {
        case .lineEnd: return true
        case .midLine: return false
        case .unavailable: break
        }
        if let editable = AXTextProbe.descendToEditable(element), !isSecure(editable) {
            if let caret = caretLocation(of: editable), let text = elementString(editable) {
                return Self.isCaretAtLineEnd(text, caret: caret)
            }
            switch AXTextProbe.webCaretLinePosition(of: editable) {
            case .lineEnd: return true
            case .midLine: return false
            case .unavailable: break
            }
        }
        return true
    }

    // Pure end-of-line test on a UTF-16 caret offset: at/after the end, or the next code unit is CR/LF.
    static func isCaretAtLineEnd(_ text: String, caret: Int) -> Bool {
        let chars = Array(text.utf16)
        let i = min(max(caret, 0), chars.count)
        if i >= chars.count { return true }
        return chars[i] == 10 || chars[i] == 13   // LF / CR
    }

    // Run of text immediately BEFORE the caret only (FR-KC-2). Never read post-caret text —
    // forward-from-caret keeps inference on the cached prefix-growth path (FINDINGS Spike 2).
    private func prefixBeforeCaret(_ text: String, caret: Int) -> String {
        let chars = Array(text.utf16)
        let end = min(max(caret, 0), chars.count)
        guard end > 0 else { return "" }
        return String(utf16CodeUnits: Array(chars[0..<end]), count: end)
    }

    func caretRectOnScreen() -> CGRect? {
        guard let element = currentFocusedElement(), !isSecure(element) else { return nil }
        // (a) Real caret geometry on the focused element (native kAXBoundsForRange or web markers).
        if let rect = caretBounds(of: element) { return rect }

        // (b) Web/Electron often keep the editable node a level down; retry caret geometry there.
        let editable = AXTextProbe.descendToEditable(element)
        if let editable, !isSecure(editable), let rect = caretBounds(of: editable) { return rect }

        // (c) Last resort (Chromium/Electron expose no usable caret rect): anchor on the editable
        // element's own frame — the actual text line — and ESTIMATE the caret X by measuring the
        // rendered width of the current line's prefix in the line's font. This lands the ghost right
        // after the typed text instead of at the box's left edge. Prefer the descended editable node
        // (the real text box) over the focused wrapper.
        let anchorEl: AXUIElement = (editable.flatMap { isSecure($0) ? nil : $0 }) ?? element
        if let frame = elementFrame(anchorEl) {
            // The frame height is the element BOX. For a single-line field that's ≈ the text line, but
            // for a MULTI-LINE field (textarea / web area, hundreds of px tall) it is NOT a line —
            // using it as the line height blew the ghost up to the whole box (the 775pt "Da" over a
            // textarea). A real text line is small, so cap: a tall frame falls back to a sane default
            // line height; a short frame is trusted as a genuine single line.
            let frameH = max(frame.size.height, 1)
            let lineHeight: CGFloat = frameH > Self.maxPlausibleLineHeight ? Self.defaultLineHeight : frameH
            // System font sized to the line; Slack/Electron composers render ≈0.7·lineHeight. SF Pro
            // measures noticeably WIDER than the fonts Chromium/Electron actually render with, so the
            // raw measured width overshoots the caret. Calibrated against Slack (pixel-measured: real
            // prefix width 162pt vs SF Pro's 192pt for the same string → ~0.84; use 0.86 to leave a
            // hair of gap rather than overlap the typed text) — seats the ghost right at the caret.
            let font = NSFont.systemFont(ofSize: max(11, round(lineHeight * 0.70)))
            // Only the last visual line's text contributes to the caret X (text after the last newline).
            let prefix = currentPrefix() ?? ""
            let lastLine = prefix.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            // When the last logical line is wider than the box it SOFT-WRAPS. The caret then sits at the end
            // of the *last visual* line — partway along it, holding the overflow text. Measuring the whole
            // string and resetting X to the box's left edge on overflow painted the ghost on top of that
            // wrapped text (Claude Code's 2-line composer: 124-char prefix, caretX pinned to minX). Greedy
            // word-wrap (mirrors how Chromium/Electron break on spaces) gives the last visual line's width
            // and how many soft-wraps occurred, so the ghost lands after the wrapped text, not over it.
            let (lastLineWidth, softWraps) = Self.lastVisualLineWidth(
                lastLine, font: font, width: frame.size.width, calibration: 0.86)
            // The caret sits `priorLines` lines BELOW the field top: hard \n breaks before it PLUS the soft
            // wraps within the last logical line. Without this the fallback parks every multi-line caret on
            // the first line — a genuine 2nd-line ghost (Gmail: type, Enter, type) renders on line 1 and
            // reads as "nothing happened". Cap to the lines that physically fit so a tall paragraph can't
            // push it off-field.
            let newlineCount = prefix.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            let maxLines = max(0, Int(frame.size.height / lineHeight) - 1)
            let priorLines = CGFloat(min(newlineCount + softWraps, maxLines))
            let caretX = frame.minX + lastLineWidth
            let lineTop = frame.minY + lineHeight * priorLines
            Diag.log("caret: path=frame axFrame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) lastW=\(Int(lastLineWidth)) wraps=\(softWraps) caretX=\(Int(caretX))")
            let anchor = CGRect(x: caretX, y: lineTop, width: 0, height: lineHeight)
            return convertAXRectToCocoa(anchor)
        }
        return nil
    }

    // Reject a caret rect that sits well outside the element's own frame. Chromium hands back an
    // off-screen caret (observed Y=-466 on a multi-line Gmail compose) for a contenteditable once the
    // body wraps/breaks — painting the ghost there puts it nowhere on screen. Returning false drops the
    // caller to the next path, ultimately the frame-anchored estimate (which is now multi-line aware).
    // Trust the rect when we can't read the frame.
    private func caretRectIsPlausible(_ axRect: CGRect, element: AXUIElement) -> Bool {
        guard let frame = elementFrame(element), frame.height > 0 else { return true }
        let slop = max(frame.height, 24)
        return axRect.midY >= frame.minY - slop && axRect.midY <= frame.maxY + slop
    }

    // AX caret rect (top-left origin) for one element, native path then web fallbacks, converted to
    // Cocoa bottom-left. A caret is a ZERO-WIDTH rect — never reject it via CGRect.isEmpty.
    private func caretBounds(of element: AXUIElement) -> CGRect? {
        // (1) Native kAXBoundsForRange at the selected-range caret.
        if let caret = caretLocation(of: element) {
            var range = CFRange(location: caret, length: 0)
            if let rangeValue = AXValueCreate(.cfRange, &range) {
                var boundsRef: CFTypeRef?
                let err = AXUIElementCopyParameterizedAttributeValue(
                    element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsRef)
                if err == .success, let bRef = boundsRef {
                    var axRect = CGRect.zero
                    // Accept only a real caret rect: finite origin AND positive height (a caret is
                    // zero-WIDTH but has the line height). Chromium/Electron returns a degenerate
                    // (0,y,0x0) here for contenteditable — reject it so we fall through to the
                    // text-marker path (2), which gives the true caret bounds. (Slack mispositioning.)
                    if CFGetTypeID(bRef) == AXValueGetTypeID(),
                       AXValueGetValue(bRef as! AXValue, .cgRect, &axRect),
                       axRect.origin.x.isFinite, axRect.size.height > 0 {
                        let endFixed = correctEndOfTextCaret(axRect, element: element, caret: caret)
                        let fixed = correctSingleLineCaretX(endFixed, element: element, caret: caret)
                        if caretRectIsPlausible(fixed, element: element) {
                            Diag.log("caret: path=native axRect=\(Int(fixed.minX)),\(Int(fixed.minY)) \(Int(fixed.width))x\(Int(fixed.height))")
                            return convertAXRectToCocoa(fixed)
                        }
                        Diag.log("caret: native implausible y=\(Int(fixed.midY)) -> fall through")
                    }
                }
            }
        }

        // (2) Web text-marker bounds (PRD R2, FR-OV-6).
        if let axRect = AXTextProbe.webCaretBounds(of: element), caretRectIsPlausible(axRect, element: element) {
            Diag.log("caret: path=web axRect=\(Int(axRect.minX)),\(Int(axRect.minY)) \(Int(axRect.width))x\(Int(axRect.height))")
            return convertAXRectToCocoa(axRect)
        }
        // No usable caret geometry; caller falls back to the element-frame anchor.
        return nil
    }

    private func elementFrame(_ element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        // "AXFrame" has no public kAX… constant; it's the element's bounds in top-left global coords.
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
              let v = value else { return nil }
        var rect = CGRect.zero
        guard CFGetTypeID(v) == AXValueGetTypeID(),
              AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.origin.x.isFinite else { return nil }
        return rect
    }

    func isSecureField() -> Bool {
        guard let element = currentFocusedElement() else { return false }
        return isSecure(element)
    }

    // IME composition probe (best-effort): a non-empty "AXMarkedTextRange" on the focused element means
    // the user is mid-composition (CJK/preedit), where an inline ghost fights the candidate UI and an
    // accept would corrupt the composition buffer. There is no public kAX… constant for it; Cocoa text
    // views (NSTextView / NSTextInputClient hosts) expose the attribute by this name. Known limitation:
    // many hosts (Chromium/Electron web fields, Catalyst) don't surface marked text through AX at all —
    // there this returns false and callers behave as today (fail-open). Single AX call, no descend.
    func hasMarkedText() -> Bool {
        guard let element = currentFocusedElement() else { return false }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXMarkedTextRange" as CFString, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID() else { return false }
        var range = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &range) else { return false }
        return range.length > 0
    }

    // FR-IN-2: the live focused AX element, for direct-AX text injection at accept time. nil when
    // nothing editable is focused or AX is untrusted (Injector then falls back to Unicode posting).
    // Injection into secure fields is gated upstream — the coordinator never shows, and so never
    // accepts, a suggestion in a secure field — so no secure-field check is needed here.
    func focusedElement() -> AXUIElement? {
        return currentFocusedElement()
    }

    // MARK: - Selection (rewrite feature)

    // A live text selection: the selected string, the element that owns it (for injection), and the
    // native AX range when readable. `range` is nil on web/Electron/Chromium fields (the text-marker
    // protocol exposes the string but no settable kAXSelectedTextRange) — the rewrite HUD then degrades
    // to no in-place re-select / undo-via-⌘Z there.
    struct CurrentSelection {
        let text: String
        let element: AXUIElement
        let range: CFRange?
    }

    // The current non-empty selection in the focused field, or nil (nothing selected / secure / not
    // editable). Native path first (kAXSelectedText + range), then the web text-marker path, then a
    // descend to the real editable node — mirroring currentPrefix()'s resolution order.
    func currentSelection() -> CurrentSelection? {
        guard let element = currentFocusedElement(), !isSecure(element) else { return nil }
        if let sel = nativeSelection(of: element) { return sel }
        if let text = AXTextProbe.webSelectedText(of: element) {
            return CurrentSelection(text: text, element: element, range: nil)
        }
        if let editable = AXTextProbe.descendToEditable(element), !isSecure(editable) {
            if let sel = nativeSelection(of: editable) { return sel }
            if let text = AXTextProbe.webSelectedText(of: editable) {
                return CurrentSelection(text: text, element: editable, range: nil)
            }
        }
        return nil
    }

    private func nativeSelection(of element: AXUIElement) -> CurrentSelection? {
        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRef) == .success,
              let text = textRef as? String, !text.isEmpty else { return nil }
        var range: CFRange?
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let r = rangeRef, CFGetTypeID(r) == AXValueGetTypeID() {
            var cf = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &cf), cf.length > 0 { range = cf }
        }
        return CurrentSelection(text: text, element: element, range: range)
    }

    // Select `range` (UTF-16) on `element` so the rewrite HUD can re-replace or restore it. Best-effort;
    // native AX fields only (web/marker fields pass range == nil and never call this).
    func selectRange(_ range: CFRange, in element: AXUIElement) {
        var r = range
        // Clamp to the element's CURRENT length when readable: the captured location/length may be stale
        // (the document changed between capture and re-select), and asking AX to select out of bounds
        // can land the selection at the wrong place or be silently rejected (the keep/undo/redo model
        // then operates on the wrong text). A clamp keeps it inside the live content.
        if let n = characterCount(of: element) {
            let loc = max(0, min(r.location, n))
            let len = max(0, min(r.length, n - loc))
            r = CFRange(location: loc, length: len)
        }
        guard let v = AXValueCreate(.cfRange, &r) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, v)
    }

    // The element's current character count (UTF-16) for bounds-clamping a selection, or nil if AX
    // doesn't expose it. Prefers the cheap kAXNumberOfCharacters; falls back to the value's length.
    private func characterCount(of element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref) == .success,
           let n = ref as? Int { return n }
        if let s = elementString(element) { return (s as NSString).length }
        return nil
    }

    // Self-heal: re-apply AXManualAccessibility on the frontmost BROWSER app to wake a Chromium AX
    // tree that wasn't built when refreshFocus first set the attribute (cold start, slow SPA, web area
    // not yet rendered). Cheap (one AX write) and idempotent; the next currentPrefix() read picks up
    // the freshly-built tree. No-op for non-browser apps. Called by the coordinator when a prefix read
    // returns nil on a web-mail host — the symptom that matches an unprimed AX tree.
    /// Per-focus-session debounce: fires at most once per pid until the next focus change, so a
    /// keystroke storm on a tab whose AX tree never materializes doesn't IPC-spam Chrome.
    func rewakeBrowserAXIfPossible() {
        guard ActivationPolicy.isBrowser(bundleId: frontmostBundleId),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              rewakedPidThisFocus != pid else { return }
        rewakedPidThisFocus = pid
        electronA11y.apply(pid: pid)
    }

    // Best-effort active-tab HOST of the frontmost browser/web host (via the web area's kAXDocument),
    // for FR-PA-2 per-domain rules. AppRules stores bare hosts (e.g. "docs.google.com") while
    // kAXDocument exposes a FULL url ("https://docs.google.com/document/d/…"), so the URL must be
    // reduced to its host or the gate's string compare never matches. nil for non-web hosts.
    func frontmostDomainHost() -> String? {
        guard let element = currentFocusedElement(),
              let url = AXTextProbe.documentURL(near: element) else { return nil }
        return Self.host(fromDocumentURL: url)
    }

    // Whole visible page text of the focused web host, for thread-aware reply context (FR-CTX-1, AX
    // backend). Walks up to the top-level AXWebArea (crossing the compose iframe to the page that
    // holds the conversation) and reads its full text. nil for native apps / no web area / secure
    // fields — the caller then falls back to OCR. Best-effort: never throws, never returns wrong text.
    func pageContextText() -> String? {
        guard let element = currentFocusedElement(), !isSecure(element),
              let webArea = AXTextProbe.topWebArea(from: element) else { return nil }
        return AXTextProbe.webAreaFullText(of: webArea)
    }

    // True when the focused field is STRUCTURED input (a search box, or a browser's address/omnibox /
    // find bar) where prose autocomplete is wrong — e.g. "aelo.com" ghosted into the address bar.
    // Gathers the AX facts and defers the decision to the pure ActivationPolicy.isNonProseField.
    // Bypassable by force-activate at the call site. Returns false when nothing is focused.
    func focusedFieldIsNonProse() -> Bool {
        guard let element = currentFocusedElement() else { return false }
        let searchSub = subrole(of: element) == (kAXSearchFieldSubrole as String)
        let editable = AXTextProbe.isEditable(element) || AXTextProbe.descendToEditable(element) != nil
        // A reachable kAXDocument is positive evidence the focus is WEB CONTENT (it's how per-domain
        // rules read the host); the omnibox/find bar carry none. Combine with the parent-walk so a
        // composer counts as "in a web area" even when Chromium hides the AXWebArea from kAXParent.
        let hasWebArea = AXTextProbe.topWebArea(from: element) != nil
            || AXTextProbe.documentURL(near: element) != nil
        // The focused (or descended) editable's role. AXTextArea / AXWebArea = prose content, not chrome.
        let r = role(of: element)
            ?? AXTextProbe.descendToEditable(element).flatMap { role(of: $0) }
        let proseRole = r == (kAXTextAreaRole as String) || r == "AXWebArea"
        // Web-mail header inputs (Gmail/Outlook To/Cc/Bcc/Subject) are AXTextField/AXComboBox inside a
        // page web area — they pass the prose-role check (they aren't a prose role) but the host's own
        // contact autocomplete owns those rows, so a ghost there clashes. Gate by host + role.
        let host = frontmostDomainHost()
        let structuredMail = ActivationPolicy.isStructuredWebMailField(host: host, role: r)
        let nonProse = ActivationPolicy.isNonProseField(
            isBrowser: ActivationPolicy.isBrowser(bundleId: frontmostBundleId),
            subroleIsSearch: searchSub, isEditable: editable,
            hasWebAreaAncestor: hasWebArea, isProseContentRole: proseRole,
            isStructuredWebMailField: structuredMail)
        if nonProse {
            Diag.log("nonProse: role=\(r ?? "?") search=\(searchSub) editable=\(editable) webArea=\(hasWebArea) host=\(host ?? "?") structuredMail=\(structuredMail)")
            return true
        }
        // Web-mail recipient/subject suppression — broader than the host+role short-circuit above
        // (covers Superhuman/Shortwave/Front/Missive + any new client that isn't in webMailHosts).
        // Browser-gated so native apps pay nothing. Reads label descriptors + child AXButton chips on
        // the focused element and its descended editable (Gmail focuses the wrapper sometimes; Outlook
        // the field itself). Either signal = non-prose.
        guard ActivationPolicy.isBrowser(bundleId: frontmostBundleId) else { return false }
        let descended = AXTextProbe.descendToEditable(element)
        let targets: [AXUIElement] = descended.map { [element, $0] } ?? [element]
        let descriptors = targets.flatMap { AXTextProbe.fieldDescriptors(of: $0) }
        if ActivationPolicy.isWebMailRecipientOrSubject(descriptors: descriptors) {
            Diag.log("nonProse: webMail field descriptors=\(descriptors)")
            return true
        }
        let chipDescs = targets.flatMap { AXTextProbe.buttonChildRoleDescriptions(of: $0) }
        if ActivationPolicy.hasRecipientChip(buttonRoleDescriptions: chipDescs) {
            Diag.log("nonProse: webMail chips=\(chipDescs)")
            return true
        }
        return false
    }

    private func role(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func subrole(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    // Pure (testable): reduce an AXDocument URL string to its lowercased host. Returns nil for URLs
    // without a network host (e.g. file://) — those aren't web domains a user scopes by. Falls back to
    // the trimmed string when it is already a bare host (no scheme, dotted, single token).
    static func host(fromDocumentURL urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let host = URLComponents(string: trimmed)?.host, !host.isEmpty {
            return host.lowercased()
        }
        if !trimmed.contains("/"), !trimmed.contains(" "), trimmed.contains(".") {
            return trimmed.lowercased()
        }
        return nil
    }

    // Full text value of the focused element (or a near relative), e.g. a terminal's visible screen
    // buffer — used by ActivationPolicy to detect an AI-agent prompt. Unlike currentPrefix this returns
    // the WHOLE value (markers can sit anywhere on screen) and skips secure fields. Some terminals focus
    // an inner line node whose value is just the prompt while the visible buffer lives in an enclosing
    // AXTextArea, so we try the editable descendant first, then walk a few PARENTS for a non-empty value.
    // nil when no readable text is reachable.
    func focusedElementText() -> String? {
        guard let element = currentFocusedElement(), !isSecure(element) else { return nil }
        if let editable = AXTextProbe.descendToEditable(element), !isSecure(editable),
           let s = elementString(editable), !s.isEmpty { return s }
        var node: AXUIElement? = element
        var hops = 0
        while let n = node, hops < 4 {
            if let s = elementString(n), !s.isEmpty { return s }
            node = parent(of: n)
            hops += 1
        }
        return nil
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &ref) == .success,
              let r = ref, CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
        return (r as! AXUIElement)
    }

    // Heights (in screen points) of the focused editable field and its window, for ActivationPolicy's
    // editor chat-input heuristic (a small composer vs the full-height code surface). nil when either
    // can't be measured — the policy then stays conservatively idle. Skips secure fields.
    func focusedFieldAndWindowHeights() -> (field: CGFloat, window: CGFloat)? {
        guard let element = currentFocusedElement(), !isSecure(element) else { return nil }
        let target = AXTextProbe.isEditable(element) ? element : (AXTextProbe.descendToEditable(element) ?? element)
        guard let fieldFrame = elementFrame(target), fieldFrame.height > 0,
              let windowHeight = windowHeight(of: target), windowHeight > 0 else { return nil }
        return (fieldFrame.height, windowHeight)
    }

    // Height of the AXWindow containing `element` (top-left AX coords; height is orientation-agnostic).
    private func windowHeight(of element: AXUIElement) -> CGFloat? {
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &winRef) == .success,
              let w = winRef, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        let window = w as! AXUIElement
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let s = sizeRef, CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return size.height
    }

    // MARK: - Focus + AXObserver

    private func refreshFocus() {
        let front = NSWorkspace.shared.frontmostApplication
        frontmostBundleId = front?.bundleIdentifier
        // Nudge Electron/Chromium to expose its AX tree before we read it (once per app). The write is
        // unsupported (no-op) on native apps, so this is safe to attempt for every frontmost app.
        if let pid = front?.processIdentifier { electronA11y.forceIfNeeded(pid: pid) }
        // Re-arm the per-focus-session browser-AX rewake (a stale pid from a prior focus must not
        // block re-priming when the user lands on a fresh Gmail tab in the same browser process).
        rewakedPidThisFocus = nil

        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else {
            // kAXErrorAPIDisabled or no focus: keep last known but drop the stale element defensively.
            if err == .apiDisabled {
                if focused != nil { focusChangeSequence &+= 1 }
                teardownObserver(); focused = nil
            }
            return
        }
        let element = v as! AXUIElement
        if focused == nil || !cfEqual(focused!, element) { focusChangeSequence &+= 1 }
        focused = element
        attachObserver(to: element)
        onFocusChange?()
    }

    // Frame (Cocoa bottom-left coords) of the focused editable field, for anchoring the active-field
    // badge at its left edge. nil when nothing editable is focused, the field is secure, or AX can't
    // report a frame. Resolves the editable node (the focused element if editable, else descend).
    func focusedFieldFrameOnScreen() -> CGRect? {
        guard let element = currentFocusedElement(), !isSecure(element) else { return nil }
        let target = AXTextProbe.isEditable(element) ? element : AXTextProbe.descendToEditable(element)
        guard let target, !isSecure(target), let frame = elementFrame(target) else { return nil }
        return convertAXRectToCocoa(frame)
    }

    // Re-read the focused element on demand so currentPrefix/caretRect always reflect live state,
    // even if a notification was missed. Cheap (one AX round-trip).
    private func currentFocusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        if err == .success, let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() {
            let element = v as! AXUIElement
            // Keep the focus-session counter consistent with refreshFocus(): this per-keystroke read can
            // observe a focus change (a new same-app field) before the async AXObserver notification runs,
            // and the overlay/font/flicker gates key off this counter. Bump on a real element change so
            // they don't attribute the new field's state to the previous session.
            if focused == nil || !cfEqual(focused!, element) { focusChangeSequence &+= 1 }
            focused = element
            return element
        }
        if err == .apiDisabled { focused = nil }
        // Transient error: we may fall back to the cached element, but ONLY if it still belongs to the
        // frontmost app. Otherwise focus has moved and returning it would read/inject into a field in
        // a previously-focused app.
        if let cached = focused, !belongsToFrontmostApp(cached) { focused = nil }
        return focused
    }

    private func belongsToFrontmostApp(_ element: AXUIElement) -> Bool {
        guard let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        return pid == frontPid
    }

    private func attachObserver(to element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return }

        // Reuse the observer if it already targets this app and element.
        if observer != nil && observerPid == pid && observedElement != nil {
            // Re-register value-changed on the new element only.
            if let obs = observer, let prev = observedElement, !cfEqual(prev, element) {
                AXObserverRemoveNotification(obs, prev, kAXValueChangedNotification as CFString)
                AXObserverAddNotification(obs, element, kAXValueChangedNotification as CFString,
                                          UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
                observedElement = element
            }
            return
        }

        teardownObserver()

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<EditContextTracker>.fromOpaque(refcon).takeUnretainedValue()
            // Focus or value changed: refresh on the main run loop (we're already on it).
            me.refreshFocus()
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let observer = obs else { return }
        self.observer = observer
        self.observerPid = pid

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, appElement,
                                  kAXFocusedUIElementChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, element,
                                  kAXValueChangedNotification as CFString, refcon)
        observedElement = element

        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer),
                           .defaultMode)
    }

    private func teardownObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer),
                                  .defaultMode)
        }
        observer = nil
        observerPid = 0
        observedElement = nil
    }

    // MARK: - AX reads

    private func caretLocation(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let v = value else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard CFGetTypeID(v) == AXValueGetTypeID(),
              AXValueGetValue(v as! AXValue, .cfRange, &range) else { return nil }
        // Caret = start of selection (works for both an insertion point and an active selection).
        return range.location
    }

    // FR-OV-4: the host text font at the caret, so the ghost matches the field's typeface and size.
    // Reads the AX attributed string around the caret (native NSText-backed apps expose it); nil when
    // the app doesn't (web/Electron) — the caller then falls back to sizing by the caret line height.
    func caretFont() -> NSFont? {
        guard let element = currentFocusedElement(), !isSecure(element) else { return nil }
        if let f = fontAtCaret(element) { return f }
        // Web/Chromium (Gmail etc.) don't answer the range-based attributed-string query fontAtCaret
        // uses; read the font via the text-marker attributed string instead so browser ghosts match.
        if let f = AXTextProbe.webFont(of: element) { return f }
        if let editable = AXTextProbe.descendToEditable(element), !isSecure(editable) {
            return fontAtCaret(editable) ?? AXTextProbe.webFont(of: editable)
        }
        return nil
    }

    private func fontAtCaret(_ element: AXUIElement) -> NSFont? {
        guard let caret = caretLocation(of: element) else { return nil }
        // Sample the character just before the caret (the text being extended); fall back to the char
        // at the caret for an empty/at-start field.
        for loc in [max(0, caret - 1), caret] {
            var range = CFRange(location: loc, length: 1)
            guard let rv = AXValueCreate(.cfRange, &range) else { continue }
            var ref: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                    element, kAXAttributedStringForRangeParameterizedAttribute as CFString, rv, &ref) == .success,
                  let attr = ref as? NSAttributedString, attr.length > 0 else { continue }
            if let font = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { return font }
        }
        return nil
    }

    // Raw AX kAXBoundsForRange (top-left global) for an arbitrary UTF-16 range, or nil.
    private func axBoundsForRange(_ element: AXUIElement, _ loc: Int, _ len: Int) -> CGRect? {
        var range = CFRange(location: loc, length: len)
        guard let rv = AXValueCreate(.cfRange, &range) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &ref) == .success,
              let r = ref, CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(r as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    // NSTextView (TextEdit/Mail/Notes/many native fields) misreports kAXBoundsForRange for a ZERO-LENGTH
    // caret at the END OF A LINE: it returns the caret rect one line ABOVE the trailing character, so the
    // ghost renders a line too high. Originally this only bit at end-of-TEXT, but it also fires on the
    // caret of any non-last line — e.g. the Apple Notes TITLE once a body exists below it: the title
    // caret lands one line up, painting the ghost over the date header. The last real character on the
    // line, by contrast, AX reports on the correct line, so re-anchor to its trailing edge (fixes both Y
    // and X). Fires only when the caret sits at a line end AND follows a real char (a caret on a fresh
    // empty line genuinely is on its own line) AND the prev char is on a DIFFERENT line than the reported
    // caret (the misreport signature — a correctly-anchored caret matches and is left untouched).
    private func correctEndOfTextCaret(_ axRect: CGRect, element: AXUIElement, caret: Int) -> CGRect {
        guard caret > 0, let s = elementString(element), Self.isCaretAtLineEnd(s, caret: caret) else { return axRect }
        let units = Array(s.utf16)
        let c = min(caret, units.count)
        guard c > 0, units[c - 1] != 10, units[c - 1] != 13,   // caret follows a real char, not an empty line
              let prev = axBoundsForRange(element, c - 1, 1),
              prev.size.height > 0, prev.origin.y.isFinite,
              prev.minY != axRect.minY else { return axRect }   // already on the right line: leave it
        return CGRect(x: prev.maxX, y: prev.minY, width: 0, height: prev.size.height)
    }

    // Single-line fields (SwiftUI grouped-Form TextFields, many AppKit NSTextFields) can report the
    // caret's kAXBoundsForRange at the field's TRAILING edge rather than just past the typed text, so a
    // short value (e.g. an email) parks the ghost at the far right of the row instead of at the caret.
    // When the field is single-line, re-anchor the caret X to frame.left + measured-prefix width.
    //
    // TWO conditions, both required (the second added after a Notes-title regression): the caret is
    // (1) implausibly far past where the text ends (≥ one em of slop) AND (2) actually in the field's
    // far-RIGHT region — the trailing-edge-park signature. Condition (2) matters because a title-only
    // Notes note has no newline, so it looks "single-line", and its enlarged BOLD title is wider than
    // our height-derived measuring font estimates — making the (correct, mid-field) AX caret look
    // "drifted right" and yanking the ghost left, painting it OVER the title. A real trailing-edge park
    // sits at the row's right edge; the Notes caret sits mid-row, so (2) excludes it. AX-space in/out.
    private func correctSingleLineCaretX(_ axRect: CGRect, element: AXUIElement, caret: Int) -> CGRect {
        guard let text = elementString(element), !text.contains("\n"), !text.contains("\r"),
              let frame = elementFrame(element), frame.width > 0 else { return axRect }
        let prefix = prefixBeforeCaret(text, caret: caret)
        let font = fontAtCaret(element)
            ?? NSFont.systemFont(ofSize: max(11, axRect.height > 0 ? axRect.height * 0.7 : 13))
        let measured = (prefix as NSString).size(withAttributes: [.font: font]).width
        let expectedX = frame.minX + measured
        let slop = max(font.pointSize, 8)
        // Right-region tolerance: a true trailing-edge park lands within a small inset of frame.maxX.
        // Scale by field width so a narrow login row and a wide field both qualify, but a full-width
        // editor (Notes) does not unless the caret is genuinely near its right edge.
        let trailingTolerance = max(font.pointSize * 2, frame.width * 0.15)
        guard Self.isTrailingEdgePark(axMinX: axRect.minX, expectedX: expectedX,
                                      frameMaxX: frame.maxX, slop: slop,
                                      trailingTolerance: trailingTolerance) else { return axRect }
        return CGRect(x: min(expectedX, frame.maxX), y: axRect.minY, width: 0, height: axRect.size.height)
    }

    // Pure (testable) decision for correctSingleLineCaretX: the caret is parked at the field's trailing
    // edge — both implausibly past the measured text end (slop) AND within the field's right-edge region.
    static func isTrailingEdgePark(axMinX: CGFloat, expectedX: CGFloat, frameMaxX: CGFloat,
                                   slop: CGFloat, trailingTolerance: CGFloat) -> Bool {
        return axMinX > expectedX + slop && axMinX >= frameMaxX - trailingTolerance
    }

    // Greedy word-wrap of one logical line into `width`, using `font` and the same calibration the caret
    // estimate applies (SF Pro measures wider than the font Chromium/Electron actually renders). Returns
    // the width of the LAST visual line — the caret's X offset from the line's left edge — and how many
    // soft-wraps occurred (extra visual lines below the first). Used by the frame-anchored caret estimate
    // on hosts that expose no kAXBoundsForRange (Electron AXTextArea): measuring the whole string and
    // resetting X to the box's left edge on overflow put the ghost at the wrapped line's start, over the
    // overflow text. Breaks on spaces like the browsers do; a single token wider than the box gets its own
    // line and its width is clamped to the box so the caret never lands off-field. Pure/testable.
    static func lastVisualLineWidth(_ line: String, font: NSFont, width: CGFloat,
                                    calibration: CGFloat) -> (lastWidth: CGFloat, wraps: Int) {
        guard width > 0 else { return (0, 0) }
        func measure(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width * calibration }
        let space = measure(" ")
        // Keep empty subsequences so runs of consecutive spaces still advance the line width.
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var cur: CGFloat = 0
        var wraps = 0
        for (i, token) in tokens.enumerated() {
            let tokenWidth = measure(token)
            let advance = (i == 0 ? 0 : space) + tokenWidth
            if cur > 0 && cur + advance > width {
                wraps += 1
                cur = tokenWidth            // token starts the new visual line; leading space is dropped
            } else {
                cur += advance
            }
        }
        return (min(cur, width), wraps)
    }

    private func elementString(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let s = value as? String else { return nil }
        return s
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        // FR-KC-4: never read or suggest in secure fields. The SDK exposes the secure text field
        // via the AX *subrole* (kAXSecureTextFieldSubrole == "AXSecureTextField"), plus the global
        // secure-event-input flag as a belt-and-suspenders signal.
        var sub: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &sub) == .success,
           let subrole = sub as? String, subrole == (kAXSecureTextFieldSubrole as String) {
            return true
        }
        return IsSecureEventInputEnabled()
    }

    // MARK: - Geometry (FR-OV-3)

    // AX reports rects in a top-left-origin global space (origin = top-left of the main display).
    // Cocoa/NSScreen use a bottom-left-origin space. Flip y about the *primary* display height
    // (NSScreen.screens[0]); this is correct across multiple monitors because both AX and Cocoa
    // share the same primary-display anchor. Backing scale needs no manual handling here: AX rects
    // are already in points (the same unit NSScreen/overlay layers use), so we must NOT divide by
    // backingScaleFactor or the rect shrinks on Retina.
    private func convertAXRectToCocoa(_ axRect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return axRect }
        let primaryHeight = primary.frame.maxY  // primary.frame.origin is (0,0); maxY == height
        let cocoaY = primaryHeight - axRect.origin.y - axRect.size.height
        return CGRect(x: axRect.origin.x, y: cocoaY, width: axRect.size.width, height: axRect.size.height)
    }

    private func cfEqual(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        CFEqual(a, b)
    }
}
