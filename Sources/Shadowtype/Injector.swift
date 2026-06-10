// Injector — inserts accepted completion text into the focused field.
// Primary (FR-IN-2): AX set-value — write into the element's model atomically, no synthetic events.
// Fallback (FR-IN-3): post the string as Unicode via CGEventKeyboardSetUnicodeString + CGEventPost.
//   Bare characters only — never synthesize modifier combos (macOS 26 Tahoe WindowServer filter).
import ApplicationServices
import Cocoa

final class Injector {
    // #10: opt-in (default OFF, so the common case is unchanged and the clipboard is never touched).
    // When on, the synthetic-input fallback pastes long/multi-line chunks via Cmd-V instead of posting
    // one large Unicode string — steadier in hosts that mishandle long synthetic strings or drop a
    // synthesized `\n`. The atomic AX path (preferred for native fields) is unaffected.
    var pasteEnabled = false

    // Returns true if the text was placed. `element` is the live focused AXUIElement (from
    // EditContextTracker.focusedElement()); the direct-AX path is tried first and we fall back to
    // Unicode posting when it's nil or the element refuses AX writes. Pass nil to force the fallback.
    func inject(_ rawText: String, into element: AXUIElement?) -> Bool {
        // #11: enforce insertion safety at the boundary, not only on the display path — any caller
        // (completion, future queued/rewrite paths) gets detokenizer junk (U+FFFD, stray C0 controls/DEL;
        // tab + line feed preserved) stripped before it can reach the host field.
        let text = TextSanitizer.removingControlJunk(rawText)
        guard !text.isEmpty else { return true }
        if let element = element {
            // Chromium/WebKit contenteditable hosts (Slack, Discord, VS Code, web fields) accept AX
            // value writes as SILENT NO-OPS — the renderer owns the DOM and ignores kAXValue /
            // kAXSelectedText, yet AXUIElementSetAttributeValue still returns .success. That makes
            // axInsert falsely report success and Tab inserts nothing. Detect a web node via the
            // WebKit-only text-marker attribute and type the text as Unicode events instead.
            if Self.isWebTextNode(element) { Diag.log("inject: web -> synthetic"); return synthesize(text) }
            if axInsert(text, into: element) { Diag.log("inject: ax ok"); return true }
            Diag.log("inject: ax failed -> synthetic")
        } else {
            Diag.log("inject: no element -> synthetic")
        }
        return synthesize(text)
    }

    // Commit `text` via synthesized input, choosing paste vs keystroke per InsertionStrategySelector.
    private func synthesize(_ text: String) -> Bool {
        switch InsertionStrategySelector.strategy(forChunk: text, pasteEnabled: pasteEnabled) {
        case .paste:
            Diag.log("inject: synthetic -> paste")
            return pasteType(text)
        case .keystroke:
            return unicodeType(text)
        }
    }

    // Atomically replace the run of `utf16Length` UTF-16 units immediately BEFORE the caret with `text`
    // (used to swap a mistyped token for its correction, FR-AC-1, and a typed `:shortcode` for its emoji,
    // FR-EM-1). Native AX fields: select [caret-len, len] and write it in ONE set-value op — no async
    // backspaces racing a synchronous value read (the bug a "postBackspaces then inject" sequence has:
    // the AX value is read BEFORE the queued Delete events are processed, so the splice lands on the
    // still-mistyped text). Web/Electron nodes ignore AX writes, so they (and any AX failure) fall back
    // to ORDERED CGEvents — `keystrokeCount` bare Deletes then Unicode typing, delivered in order on the
    // session tap. `utf16Length` is the AX range unit; `keystrokeCount` is the Delete-press count (they
    // differ only for multi-scalar graphemes; equal for the ASCII shortcodes/words in practice).
    func replaceBeforeCaret(utf16Length: Int, keystrokeCount: Int,
                            with text: String, in element: AXUIElement?) -> Bool {
        if let element, !Self.isWebTextNode(element),
           axReplaceBeforeCaret(utf16Length: utf16Length, with: text, in: element) {
            Diag.log("replace: ax atomic ok")
            return true
        }
        // Ordered fallback: backspaces THEN typed text, both async CGEvents on the session tap (FIFO).
        Diag.log("replace: ordered CGEvent fallback")
        postBackspaces(keystrokeCount)
        return unicodeType(text)
    }

    // Atomic AX delete-and-insert before the caret. Returns false (caller falls back) if the caret can't
    // be read, something is selected, the run would underflow the field, or the write is a no-op.
    private func axReplaceBeforeCaret(utf16Length: Int, with text: String, in element: AXUIElement) -> Bool {
        guard utf16Length > 0 else { return false }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let r = rangeRef, CFGetTypeID(r) == AXValueGetTypeID() else { return false }
        var caret = CFRange()
        guard AXValueGetValue(r as! AXValue, .cfRange, &caret), caret.length == 0 else { return false }
        let start = caret.location - utf16Length
        guard start >= 0 else { return false }
        let before = readValue(element)
        var sel = CFRange(location: start, length: utf16Length)
        guard let selVal = AXValueCreate(.cfRange, &sel),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, selVal) == .success,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        // Verify the write took (some hosts accept-but-ignore): trust it only if unreadable or changed.
        if before == nil { return true }
        if let after = readValue(element), after != before { return true }
        return false
    }

    // Post `count` bare Delete (keycode 51, no modifiers — Tahoe synthetic-event-filter safe) key events.
    // Used only by the ORDERED fallback above (web/Electron/AX-refused fields).
    private func postBackspaces(_ count: Int) {
        guard count > 0, let source = CGEventSource(stateID: .hidSystemState) else { return }
        for _ in 0..<count {
            if let d = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true) {
                d.setIntegerValueField(.eventSourceUserData, value: InputMonitor.injectedEventMagic)
                d.post(tap: .cgSessionEventTap)
            }
            if let u = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) {
                u.setIntegerValueField(.eventSourceUserData, value: InputMonitor.injectedEventMagic)
                u.post(tap: .cgSessionEventTap)
            }
        }
    }

    // AXSelectedTextMarkerRange is a private attribute exposed ONLY by WebKit/Chromium accessibility
    // nodes (see AXTextProbe) — its mere presence reliably flags a web/Electron editable, where AX
    // writes are no-ops and synthetic typing is the only path that actually lands text.
    static func isWebTextNode(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &value) == .success
    }

    // MARK: - Primary: AX set-value at the caret/selection (FR-IN-2)
    private func axInsert(_ text: String, into element: AXUIElement) -> Bool {
        // Collapse selection to the caret so we replace selected text (if any) or insert at the caret.
        // If we can read the current selected range, target it explicitly; otherwise rely on the
        // element's own selection state and just write kAXSelectedTextAttribute.
        let cf = text as CFString

        // Snapshot the field value first so we can VERIFY the write actually landed. Catalyst/UIKit
        // fields (e.g. WhatsApp) accept kAXSelectedText writes and return .success but apply nothing;
        // without verification we'd report success and Tab would insert nothing.
        let before = readValue(element)
        // Snapshot the live selection too: a SUCCESSFUL replace collapses it to a caret, while an
        // IGNORED write leaves it intact — that's how we tell the two "value unchanged" cases apart.
        let selBefore = selectedRange(of: element)

        // Try the direct, model-level insert first: replace the current selection with our text.
        if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, cf) == .success {
            // Trust it only if we can't read the value (nothing to verify) or the value changed.
            if before == nil { return true }
            if let after = readValue(element), after != before { return true }
            // .success but the value is unchanged: either we replaced the selection with IDENTICAL
            // text (a clean rewrite that returns ≈the same words) or the host ignored the write. The
            // value can't tell them apart, but the selection state can — a real replace collapses the
            // selection to a caret at selStart+len. If it collapsed, the write took; returning here is
            // critical, because falling through to the splice would re-insert `text` at that now-caret
            // and APPEND a duplicate copy. If the selection is still live, the write was ignored — fall
            // through, where the splice path replaces it correctly (the selection is still there).
            if let sb = selBefore, sb.length > 0,
               let sa = selectedRange(of: element), sa.length == 0,
               sa.location == sb.location + (text as NSString).length {
                Diag.log("inject: ax identical-replace took")
                return true
            }
            // .success but the value is unchanged and the selection didn't collapse -> genuine no-op;
            // fall through to the splice path.
        }

        // Some elements expose only kAXValueAttribute and a settable selected range. Read the value
        // and current caret, splice the text in, and write the whole value back.
        var rangeRef: CFTypeRef?
        var valueRef: CFTypeRef?
        let haveValue = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success
        guard haveValue, let current = valueRef as? String else { return false }

        var insertAt = current.utf16.count   // default: append
        var selLen = 0
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let r = rangeRef, CFGetTypeID(r) == AXValueGetTypeID() {
            var cfRange = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &cfRange) {
                insertAt = max(0, min(cfRange.location, current.utf16.count))
                selLen = max(0, min(cfRange.length, current.utf16.count - insertAt))
            }
        }

        let u = Array(current.utf16)
        let prefix = String(utf16CodeUnits: u, count: insertAt)
        let suffixStart = insertAt + selLen
        let suffix = String(utf16CodeUnits: Array(u[suffixStart...]), count: u.count - suffixStart)
        let newValue = prefix + text + suffix

        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString,
                                           newValue as CFString) == .success else { return false }

        // Verify the write actually took: some hosts return .success but ignore the write (the model
        // re-renders from their own state). If the value didn't change, report failure so the caller
        // falls back to Unicode typing rather than silently dropping the text.
        var checkRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &checkRef) == .success,
           let after = checkRef as? String, after != newValue {
            return false
        }

        // Move the caret to just after the inserted text (best-effort).
        var caret = CFRange(location: insertAt + text.utf16.count, length: 0)
        if let newRange = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newRange)
        }
        return true
    }

    // The element's current selected range (UTF-16), or nil if it doesn't expose a readable
    // kAXSelectedTextRange. Used to distinguish a real selection-replace (collapses to a caret) from a
    // host that accepts-but-ignores the write (selection stays put).
    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let r = ref, CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var cf = CFRange()
        guard AXValueGetValue(r as! AXValue, .cfRange, &cf) else { return nil }
        return cf
    }

    // Current kAXValue string, or nil if the element doesn't expose a readable string value.
    private func readValue(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    // MARK: - Fallback: Unicode character posting (FR-IN-3)
    // No keycode synthesis, no modifiers. Down+up events carrying the Unicode string land in the
    // focused field; Developer-ID-signed + notarized builds pass the Tahoe synthetic-event filter.
    private func unicodeType(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.setIntegerValueField(.eventSourceUserData, value: InputMonitor.injectedEventMagic)
        up.setIntegerValueField(.eventSourceUserData, value: InputMonitor.injectedEventMagic)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    // #10 paste path: place `text` on the pasteboard, synthesize Cmd-V, then restore the prior
    // pasteboard contents. Only reached for long/multi-line chunks when `pasteEnabled` is on. Cmd-V is
    // a modifier combo, which the Tahoe synthetic-event filter only passes for Developer-ID-signed +
    // notarized builds — the same constraint the keystroke fallback already documents.
    private func pasteType(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        // Snapshot ALL pasteboard items and every flavor (not just .string) so images / files / RTF are
        // preserved, not destroyed by clearContents (#9). An empty/non-restorable clipboard yields [].
        let savedItems = Self.snapshotPasteboard(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)
        // changeCount immediately AFTER our write: the restore only runs if nothing else has touched the
        // pasteboard since (so a copy the user makes during the window is NOT clobbered) (#10).
        let ourChangeCount = pb.changeCount

        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),  // 'v'
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            Self.restorePasteboard(pb, items: savedItems)   // synth failed: put the user's clipboard back now
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: InputMonitor.injectedEventMagic)
        up.setIntegerValueField(.eventSourceUserData, value: InputMonitor.injectedEventMagic)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)

        // Restore the user's clipboard after the paste has been delivered. The session-tap events are
        // queued FIFO ahead of this main-thread hop, so a short delay keeps us from clobbering the
        // pasteboard before the host reads it. 350 ms (was 200): slow Electron/web hosts service the
        // Cmd-V on their renderer loop well after the event lands, and a 200 ms restore raced them —
        // the host then pasted the RESTORED clipboard and the accepted text was lost. Tradeoff: the
        // longer delay widens the window where the user's clipboard briefly holds our completion text;
        // the changeCount guard below still protects any NEWER copy they make meanwhile, and there is
        // no general way to detect that the host actually consumed the paste. Residual race: a host
        // that reads even later sees the restored contents — unavoidable with synthetic paste.
        // Restoring [] (nothing was saved) clears our completion text rather than stranding it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard pb.changeCount == ourChangeCount else { return }   // user/app copied since: leave it
            Self.restorePasteboard(pb, items: savedItems)
        }
        return true
    }

    // Deep-copy every item/type currently on `pb` so it can be restored verbatim after a paste.
    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy.types.isEmpty ? nil : copy
        }
    }

    // Replace the pasteboard contents with `items` (clears to empty when items is empty).
    private static func restorePasteboard(_ pb: NSPasteboard, items: [NSPasteboardItem]) {
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
