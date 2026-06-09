// AXTextProbe — web/Electron/Chromium AX coverage helpers (PRD R2, FR-OV-6, FR-IN-3 hosts).
// Electron/WebKit/Chromium expose editable text through a "web area" using Apple's *private*
// text-marker accessibility attributes rather than kAXValue + kAXSelectedTextRange. None of these
// strings are in the public AX headers, so they're declared here as literals; they've shipped
// unchanged in WebKit/Chromium for years and are the only way to read forward-from-caret text and
// caret bounds in Slack/Warp/VS Code/Discord etc. Everything is best-effort: any failure returns
// nil so the caller falls back or gives up gracefully (never wrong text).
import Cocoa
import ApplicationServices

enum AXTextProbe {
    // Private parameterized/plain attributes used by WebKit & Chromium accessibility.
    static let selectedTextMarkerRange = "AXSelectedTextMarkerRange"
    static let startTextMarker = "AXStartTextMarker"
    static let stringForTextMarkerRange = "AXStringForTextMarkerRange"
    static let boundsForTextMarkerRange = "AXBoundsForTextMarkerRange"
    static let textMarkerRangeForUnorderedTextMarkers = "AXTextMarkerRangeForUnorderedTextMarkers"
    static let startTextMarkerForRange = "AXStartTextMarkerForTextMarkerRange"
    static let attributedStringForTextMarkerRange = "AXAttributedStringForTextMarkerRange"
    static let endTextMarker = "AXEndTextMarker"
    static let textMarkerRangeForUIElement = "AXTextMarkerRangeForUIElement"
    static let nextTextMarker = "AXNextTextMarkerForTextMarker"
    static let previousTextMarker = "AXPreviousTextMarkerForTextMarker"
    static let textMarkerForPosition = "AXTextMarkerForPosition"
    // Visual-line marker ranges: the line containing a marker, and the caret→line-end "right line".
    // Used to read the whole remainder of the current line after the caret (mid-line detection).
    static let lineTextMarkerRangeForTextMarker = "AXLineTextMarkerRangeForTextMarker"
    static let rightLineTextMarkerRangeForTextMarker = "AXRightLineTextMarkerRangeForTextMarker"
    static let endTextMarkerForTextMarkerRange = "AXEndTextMarkerForTextMarkerRange"

    // Roles/subroles that denote an actual editable text node when we descend.
    private static let editableRoles: Set<String> = [
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        "AXWebArea",
    ]

    // MARK: - Web text-marker prefix

    // The string from the start of the document to the caret (start of the selected marker range).
    // Returns nil unless the element genuinely speaks the text-marker protocol AND yields a string.
    static func webPrefix(of element: AXUIElement) -> String? {
        guard let selRange = copyValue(element, selectedTextMarkerRange),
              let caretMarker = startMarker(element, of: selRange),
              let docStart = copyValue(element, startTextMarker),
              let prefixRange = makeMarkerRange(element, start: docStart, end: caretMarker),
              let str = copyParam(element, stringForTextMarkerRange, prefixRange) as? String
        else { return nil }
        return str
    }

    // The START marker of a marker range. WebKit ADVERTISES AXStartTextMarkerForTextMarkerRange (so it
    // shows up on Chromium and is enumerable), but Apple Mail's compose AXWebArea responds only to the
    // underscore-prefixed SPI `_AXStartTextMarkerForTextMarkerRange` — WebKit handles it but deliberately
    // omits it from accessibilityParameterizedAttributeNames, so it never appears in an attribute dump
    // yet still answers when queried by string (confirmed against WebAccessibilityObjectWrapperMac.mm).
    // Try the public name first, then the SPI. This is the exact, lossless way to get the caret marker —
    // preferred over deriving it from the caret's screen point (AXTextMarkerForPosition).
    private static func startMarker(_ element: AXUIElement, of range: CFTypeRef) -> CFTypeRef? {
        copyParam(element, startTextMarkerForRange, range)
            ?? copyParam(element, "_" + startTextMarkerForRange, range)
    }

    // WebKit fallback for hosts that expose the selected marker RANGE, doc-start marker, per-position
    // marker lookup, and the unordered-markers range builder — but NOT AXStartTextMarkerForTextMarkerRange
    // (modern Apple Mail's compose AXWebArea: the marker chain dead-ends because the range→start-marker
    // accessor is absent, AND there's no index API/kAXValue). Derive the caret marker from the caret's
    // on-screen point instead, then read document-start→caret. All four attributes used here are present
    // on Mail's web area per a live AX attribute dump. nil if any step is unsupported/empty.
    static func webPrefixViaPosition(of element: AXUIElement) -> String? {
        guard let caretRect = webCaretBounds(of: element),
              let docStart = copyValue(element, startTextMarker) else { return nil }
        // A point inside the caret line: caret X, vertical middle of its line box (top-left AX coords —
        // self-consistent with the bounds we just read, so the flip convention doesn't matter).
        var pt = CGPoint(x: caretRect.minX, y: caretRect.midY)
        guard let pv = AXValueCreate(.cgPoint, &pt),
              let caretMarker = copyParam(element, textMarkerForPosition, pv),
              let prefixRange = makeMarkerRange(element, start: docStart, end: caretMarker),
              let str = copyParam(element, stringForTextMarkerRange, prefixRange) as? String
        else { return nil }
        return str
    }

    // Diagnostic only: what the index-based text API reports on `element` — selected-range location,
    // char count, and whether kAXStringForRange(0..<caret) yields text. Pins down Mail's real surface.
    static func indexCapabilities(of element: AXUIElement) -> String {
        var sel = "selRange=-"
        var selRef: CFTypeRef?
        var caret = -1
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRef) == .success,
           let s = selRef, CFGetTypeID(s) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(s as! AXValue, .cfRange, &r) { caret = r.location; sel = "selRange=\(r.location):\(r.length)" }
        }
        var nChars = "nChars=-"
        var nRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &nRef) == .success,
           let n = nRef as? Int { nChars = "nChars=\(n)" }
        var strFor = "strForRange=-"
        if caret > 0 {
            var range = CFRange(location: 0, length: caret)
            if let rv = AXValueCreate(.cfRange, &range) {
                var strRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString, rv, &strRef) == .success,
                   let str = strRef as? String { strFor = "strForRange=len\(str.utf16.count)" }
                else { strFor = "strForRange=nil" }
            }
        }
        return "\(sel) \(nChars) \(strFor)"
    }

    // Diagnostic only: which step of the webPrefix marker chain first returns nil, for a live diag in a
    // failing host (Mail). Mirrors webPrefix exactly; never on the hot path.
    static func webPrefixFailureStep(of element: AXUIElement) -> String {
        guard let selRange = copyValue(element, selectedTextMarkerRange) else { return "noSelMarkerRange" }
        guard let caretMarker = startMarker(element, of: selRange) else { return "noCaretMarker" }
        guard let docStart = copyValue(element, startTextMarker) else { return "noDocStart" }
        guard let prefixRange = makeMarkerRange(element, start: docStart, end: caretMarker) else { return "noPrefixRange" }
        guard let str = copyParam(element, stringForTextMarkerRange, prefixRange) as? String else { return "noString" }
        return "ok(len=\(str.utf16.count))"
    }

    // The currently SELECTED text in a web/Electron/Chromium field, for the rewrite feature. The
    // selected marker range is read directly (no document-start walk needed) and stringified. nil unless
    // the element speaks the text-marker protocol and a non-empty selection exists.
    static func webSelectedText(of element: AXUIElement) -> String? {
        guard let selRange = copyValue(element, selectedTextMarkerRange),
              let str = copyParam(element, stringForTextMarkerRange, selRange) as? String,
              !str.isEmpty
        else { return nil }
        return str
    }

    // The host font at the caret for a web/Chromium field (FR-OV-4). Reads the attributed string for the
    // document-start→caret marker range (same range webPrefix uses) and returns the font of its last
    // character. Chromium exposes font via AXAttributedStringForTextMarkerRange but NOT via the
    // range-based kAXAttributedStringForRange that native fields use — so the native caretFont path
    // can't see it and the ghost fell back to a too-small estimate. nil unless a real font is present.
    static func webFont(of element: AXUIElement) -> NSFont? {
        guard let selRange = copyValue(element, selectedTextMarkerRange),
              let caretMarker = startMarker(element, of: selRange),
              let docStart = copyValue(element, startTextMarker),
              let prefixRange = makeMarkerRange(element, start: docStart, end: caretMarker),
              let attr = copyParam(element, attributedStringForTextMarkerRange, prefixRange) as? NSAttributedString,
              attr.length > 0 else { return nil }
        return attr.attribute(.font, at: attr.length - 1, effectiveRange: nil) as? NSFont
    }

    // Build a text-marker *range* spanning [start, end] via the unordered-markers parameterized call,
    // which takes a 2-element CFArray of markers and returns an AXTextMarkerRange.
    private static func makeMarkerRange(_ element: AXUIElement, start: CFTypeRef, end: CFTypeRef) -> CFTypeRef? {
        let markers = [start, end] as CFArray
        return copyParam(element, textMarkerRangeForUnorderedTextMarkers, markers)
    }

    // MARK: - Web caret bounds

    // Bounds of the zero-length caret marker range, in AX top-left global coords. The caret is a
    // ZERO-WIDTH rect (FR-OV-3 gotcha) — callers must NOT reject it via CGRect.isEmpty.
    static func webCaretBounds(of element: AXUIElement) -> CGRect? {
        guard let selRange = copyValue(element, selectedTextMarkerRange) else { return nil }
        // (1) Bounds of the selection's own (caret) range — the clean case (Safari, many WebKit fields).
        // A caret is zero-WIDTH but has the line height; reject a fully degenerate (0,y,0x0) rect, which
        // Chromium/contenteditable (Gmail, Slack) returns here, and fall through to the marker fallbacks.
        if let r = markerRangeBounds(element, range: selRange) { return r }

        // The caret marker is the START of the selection range; both fallbacks below hang off it.
        guard let caretMarker = startMarker(element, of: selRange) else { return nil }

        // (2) Some Chromium builds answer bounds only for an EXPLICIT zero-length range built at the
        // caret marker, not for the raw selection range — try that.
        if let zero = makeMarkerRange(element, start: caretMarker, end: caretMarker),
           let r = markerRangeBounds(element, range: zero) { return r }

        // (3) Last resort: the glyph rect of the character immediately BEFORE the caret always has a
        // real height even when the empty-caret rect collapses to 0×0 (the Gmail case). Anchor the
        // caret at that glyph's trailing edge (maxX) so the ghost seats inline at the caret instead of
        // the field's top-left frame estimate.
        if let prevMarker = copyParam(element, previousTextMarker, caretMarker),
           let prevRange = makeMarkerRange(element, start: prevMarker, end: caretMarker),
           let glyph = markerRangeBounds(element, range: prevRange) {
            return CGRect(x: glyph.maxX, y: glyph.minY, width: 0, height: glyph.size.height)
        }
        return nil
    }

    // Bounds of a text-marker range as an AX top-left CGRect, accepting only a real rect (finite origin
    // AND positive height — a caret/glyph always has the line height). Returns nil for the degenerate
    // (0,y,0x0) that contenteditable hands back, so callers can try the next fallback.
    private static func markerRangeBounds(_ element: AXUIElement, range: CFTypeRef) -> CGRect? {
        var boundsRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, boundsForTextMarkerRange as CFString, range, &boundsRef)
        guard err == .success, let bRef = boundsRef,
              CFGetTypeID(bRef) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bRef as! AXValue, .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.size.height > 0 else { return nil }
        return rect
    }

    // Three definite outcomes for "where is the caret on its visual line?" The crucial distinction vs a
    // plain Bool?: `.unavailable` means the marker protocol genuinely isn't here (caller keeps firing,
    // preserving non-marker surfaces), while `.lineEnd`/`.midLine` are KNOWN answers the caller trusts —
    // a successful marker read must never be conflated with "unavailable".
    enum CaretLineProbe { case lineEnd, midLine, unavailable }

    // The text from a caret to the end of its visual line. End-of-line iff empty, a line break, or only
    // trailing whitespace before the break; any other character ⇒ mid-line (the ghost would overlap it).
    static func classifyLineRemainder(_ remainder: String) -> CaretLineProbe {
        for u in remainder.unicodeScalars {
            if u == "\n" || u == "\r" { return .lineEnd }
            if u == " " || u == "\t" { continue }   // trailing spaces aren't text → still end of line
            return .midLine
        }
        return .lineEnd   // empty remainder → end of line
    }

    // Best-effort: where is the caret on its visual line in a web/marker field? Prefers reading the whole
    // line REMAINDER after the caret (caret → visual-line end), falling back to a single next-marker hop.
    // Returns `.unavailable` only when the marker protocol truly can't answer, so the caller never
    // suppresses on a surface it genuinely can't read (and never fires mid-line when it CAN read).
    static func webCaretLinePosition(of element: AXUIElement) -> CaretLineProbe {
        guard let selRange = copyValue(element, selectedTextMarkerRange),
              let caretMarker = startMarker(element, of: selRange) else { return .unavailable }
        // (1) Preferred: remainder of the current VISUAL line after the caret (handles soft-wrap).
        if let lineEnd = lineEndMarker(element, from: caretMarker),
           let range = makeMarkerRange(element, start: caretMarker, end: lineEnd),
           let s = copyParam(element, stringForTextMarkerRange, range) as? String {
            if Diag.isEnabled { Diag.log("webLine: rem=\"\(s.prefix(40))\" via=line") }
            return classifyLineRemainder(s)
        }
        // (2) Fallback: single next-marker hop (the original behavior) — still a DEFINITE answer.
        // No marker after the caret → caret sits at the very end of the document → end of line.
        guard let nextMarker = copyParam(element, nextTextMarker, caretMarker) else { return .lineEnd }
        if let range = makeMarkerRange(element, start: caretMarker, end: nextMarker),
           let s = copyParam(element, stringForTextMarkerRange, range) as? String {
            if Diag.isEnabled { Diag.log("webLine: rem=\"\(s.prefix(40))\" via=next") }
            return classifyLineRemainder(s)
        }
        // Had a caret marker but couldn't read forward → protocol half-present; don't suppress.
        return .unavailable
    }

    // The caret → end-of-visual-line marker, via the rightLine SPI (caret to line end) then the
    // full-line SPI; nil if neither is supported. Each tries the public name then the underscore SPI.
    private static func lineEndMarker(_ element: AXUIElement, from caret: CFTypeRef) -> CFTypeRef? {
        for name in [rightLineTextMarkerRangeForTextMarker, lineTextMarkerRangeForTextMarker] {
            if let lineRange = copyParam(element, name, caret) ?? copyParam(element, "_" + name, caret),
               let end = copyParam(element, endTextMarkerForTextMarkerRange, lineRange)
                      ?? copyParam(element, "_" + endTextMarkerForTextMarkerRange, lineRange) {
                return end
            }
        }
        return nil
    }

    // MARK: - Descend to a real editable text node

    // Some hosts (Slack composer, Electron toolbars) focus a wrapper/group whose kAXValue and
    // selection are empty, while the actual text lives in a descendant AXTextArea / settable-value
    // node. BFS up to `maxDepth` levels (bounded — must stay fast, never block) to find it.
    static func descendToEditable(_ element: AXUIElement, maxDepth: Int = 4) -> AXUIElement? {
        var frontier: [(AXUIElement, Int)] = [(element, 0)]
        var visited = 0
        let visitCap = 64  // hard cap on nodes inspected; keeps the hot loop cheap.
        while !frontier.isEmpty {
            let (node, depth) = frontier.removeFirst()
            visited += 1
            if visited > visitCap { break }
            if node != element, isEditableLeaf(node) { return node }
            if depth >= maxDepth { continue }
            for child in children(of: node) {
                frontier.append((child, depth + 1))
            }
        }
        return nil
    }

    // Public editable check (same logic as the descend's leaf test), valid on the focused element
    // directly — used to decide whether to anchor the active-field badge here or descend first.
    static func isEditable(_ element: AXUIElement) -> Bool { isEditableLeaf(element) }

    private static func isEditableLeaf(_ element: AXUIElement) -> Bool {
        // A node we can read text from: it has a kAXValue string AND a usable selection, OR it's a
        // known editable role, OR kAXValue is settable.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, editableRoles.contains(role) {
            return true
        }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        return false
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    // MARK: - Field descriptors + chip detection (web-mail recipient/subject suppression)

    // Best-effort: the label/description strings an element exposes — kAXDescription,
    // kAXRoleDescription, kAXTitle, kAXPlaceholderValue. Empty values dropped. Used by
    // ActivationPolicy.isWebMailRecipientOrSubject to identify Gmail/Outlook/Superhuman recipient
    // and subject fields across hosts (the host-list short-circuit can't enumerate every web mail
    // client; the visible label is stable).
    static func fieldDescriptors(of element: AXUIElement) -> [String] {
        let attrs: [CFString] = [
            kAXDescriptionAttribute as CFString,
            kAXRoleDescriptionAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXPlaceholderValueAttribute as CFString,
        ]
        var out: [String] = []
        for a in attrs {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, a, &v) == .success,
               let s = v as? String, !s.isEmpty {
                out.append(s)
            }
        }
        return out
    }

    // Role-descriptions of AXButton descendants of `element`, for Gmail-style recipient-chip
    // detection. Bounded BFS — mirrors descendToEditable's depth/visit caps so the hot keystroke
    // path stays cheap on a real Gmail compose tree. Skips `element` itself; only collects
    // descendants whose role == AXButton.
    static func buttonChildRoleDescriptions(of element: AXUIElement,
                                            maxDepth: Int = 2,
                                            visitCap: Int = 32) -> [String] {
        var out: [String] = []
        var frontier: [(AXUIElement, Int)] = [(element, 0)]
        var visited = 0
        while !frontier.isEmpty {
            let (node, depth) = frontier.removeFirst()
            visited += 1
            if visited > visitCap { break }
            if node != element, isButton(node), let d = roleDescription(of: node), !d.isEmpty {
                out.append(d)
            }
            if depth >= maxDepth { continue }
            for child in children(of: node) {
                frontier.append((child, depth + 1))
            }
        }
        return out
    }

    private static func isButton(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success,
              let role = ref as? String else { return false }
        return role == (kAXButtonRole as String)
    }

    private static func roleDescription(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    // MARK: - Browser active-tab URL (optional, P2 per-domain rules)

    // Best-effort: the frontmost browser tab's URL via the web area's kAXDocument attribute (a URL
    // string the AX tree exposes for Safari/Chrome content). nil for non-browser hosts.
    // INTEGRATOR-NOTE: EditContextTracker.frontmostDomainHost() reduces this URL to its host and
    // feeds the per-domain gate in CompletionCoordinator.fire() (FR-PA-2).
    static func documentURL(near element: AXUIElement) -> String? {
        // Try the focused element, then walk up to a parent that carries kAXDocument.
        var node: AXUIElement? = element
        var hops = 0
        while let n = node, hops < 6 {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(n, kAXDocumentAttribute as CFString, &value) == .success,
               let url = value as? String, !url.isEmpty {
                return url
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(n, kAXParentAttribute as CFString, &parentRef) == .success,
               CFGetTypeID(parentRef!) == AXUIElementGetTypeID() {
                node = (parentRef as! AXUIElement)
            } else {
                node = nil
            }
            hops += 1
        }
        return nil
    }

    // MARK: - Whole-page web text (thread-aware reply context)

    // The top-most AXWebArea at or above `element`. Walking UP from a focused compose field crosses
    // the Gmail/email compose IFRAME (its own web area) to the parent PAGE's web area — the one that
    // contains the conversation being replied to. Returns the highest web area seen within maxHops
    // (the page), or nil for native (non-web) hosts.
    static func topWebArea(from element: AXUIElement, maxHops: Int = 12) -> AXUIElement? {
        var node: AXUIElement? = element
        var hops = 0
        var best: AXUIElement?
        while let n = node, hops < maxHops {
            if role(of: n) == "AXWebArea" { best = n }
            node = parent(of: n)
            hops += 1
        }
        return best
    }

    // Full visible text of a web area (the whole page), capped. Used as exact, permission-free,
    // synchronous context — strictly better fidelity than OCR where a web area exists. Best-effort
    // with three fallbacks; nil if none yields text.
    static func webAreaFullText(of webArea: AXUIElement, maxChars: Int = 20_000) -> String? {
        // (1) The element's own full text-marker range (the clean Chromium/WebKit way).
        if let range = copyParam(webArea, textMarkerRangeForUIElement, webArea),
           let s = copyParam(webArea, stringForTextMarkerRange, range) as? String, !s.isEmpty {
            return String(s.prefix(maxChars))
        }
        // (2) Document start→end markers.
        if let docStart = copyValue(webArea, startTextMarker),
           let docEnd = copyValue(webArea, endTextMarker),
           let range = makeMarkerRange(webArea, start: docStart, end: docEnd),
           let s = copyParam(webArea, stringForTextMarkerRange, range) as? String, !s.isEmpty {
            return String(s.prefix(maxChars))
        }
        // (3) Fallback: bounded BFS gathering descendant text values.
        return gatherText(webArea, maxChars: maxChars)
    }

    // Bounded BFS collecting kAXValue strings from descendants (AXStaticText etc.). Visit-capped so a
    // huge page can't stall the hot path; stops once maxChars of text is gathered.
    private static func gatherText(_ root: AXUIElement, maxChars: Int, visitCap: Int = 4000) -> String? {
        var out = ""
        var frontier = children(of: root)
        var visited = 0
        while !frontier.isEmpty, out.count < maxChars, visited < visitCap {
            let node = frontier.removeFirst()
            visited += 1
            if let v = stringValue(node), !v.isEmpty { out += v; out += "\n" }
            frontier.append(contentsOf: children(of: node))
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxChars))
    }

    private static func role(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &ref) == .success,
              let r = ref, CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
        return (r as! AXUIElement)
    }

    private static func stringValue(_ element: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &v) == .success,
              let s = v as? String else { return nil }
        return s
    }

    // MARK: - Low-level AX accessors (defensive: handle apiDisabled / nil)

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    private static func copyParam(_ element: AXUIElement, _ attribute: String, _ param: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, param, &value)
        guard err == .success else { return nil }
        return value
    }
}
