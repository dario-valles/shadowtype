import Cocoa

final class GhostPresentationController {
    private let overlay: OverlayRenderer

    var suggestionText = ""
    var suggestionFocusSeq: UInt64?
    var emojiSuggestion: String?
    var emojiQueryLength = 0
    var correctionSuggestion: String?
    var correctionRun: String?
    var isVisible = false
    var currentSuggestionAccepted = false
    var fontStabilizer = GhostFontSizeStabilizer()
    var lastRendered: OverlayStabilityGate.Rendered?
    var lastEmitState: OverlayEmitDedup.State?
    var overlayPresented = false

    private var fontWatchMonitor: Any?

    init(overlay: OverlayRenderer) {
        self.overlay = overlay
    }

    func setVisible(_ visible: Bool, onChange: (Bool) -> Void) {
        guard visible != isVisible else { return }
        isVisible = visible
        onChange(visible)
    }

    func startFontWatch(revalidate: @escaping () -> Void) {
        guard fontWatchMonitor == nil else { return }
        fontWatchMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                revalidate()
            }
        }
    }

    func stopFontWatch() {
        if let fontWatchMonitor {
            NSEvent.removeMonitor(fontWatchMonitor)
        }
        fontWatchMonitor = nil
    }

    func clear(preserveEmitState: Bool) {
        suggestionText = ""
        suggestionFocusSeq = nil
        emojiSuggestion = nil
        emojiQueryLength = 0
        correctionSuggestion = nil
        correctionRun = nil
        overlay.hide()
        overlayPresented = false
        lastRendered = nil
        if !preserveEmitState {
            lastEmitState = nil
        }
    }

    func untrackOverlay() {
        lastRendered = nil
    }

    func shouldPresent(_ candidate: OverlayStabilityGate.Rendered) -> Bool {
        OverlayStabilityGate.shouldRePresent(last: lastRendered, candidate: candidate)
    }

    func refireDecision(for snapshot: String) -> OverlayRefireDecision.Action {
        OverlayRefireDecision.decide(visible: suggestionText, snapshot: snapshot)
    }

    @discardableResult
    func emit(
        text: String,
        at caret: CGRect,
        font: NSFont?,
        opacity: CGFloat,
        rtl: Bool,
        showHint: Bool,
        focusSeq: UInt64,
        now: TimeInterval
    ) -> Bool {
        let presentationKey = Self.presentationFingerprint(
            text: text,
            caret: caret,
            font: font,
            opacity: opacity,
            rtl: rtl,
            showHint: showHint
        )
        if OverlayEmitDedup.shouldDrop(
            last: lastEmitState,
            text: presentationKey,
            focusSeq: focusSeq,
            now: now,
            presented: overlayPresented
        ) {
            Diag.log("emit: dedup presentation-equivalent within window len=\(text.count)")
            return true
        }
        overlay.show(
            text: text,
            at: caret,
            font: font,
            opacity: opacity,
            rtl: rtl,
            showHint: showHint
        )
        overlayPresented = true
        lastEmitState = OverlayEmitDedup.State(
            text: presentationKey,
            focusSeq: focusSeq,
            emittedAt: now
        )
        return true
    }

    func showDirect(
        text: String,
        at caret: CGRect,
        font: NSFont?,
        opacity: CGFloat,
        rtl: Bool,
        showHint: Bool
    ) {
        overlay.show(
            text: text,
            at: caret,
            font: font,
            opacity: opacity,
            rtl: rtl,
            showHint: showHint
        )
        overlayPresented = true
    }

    static func normalizedPayload(_ text: String) -> String {
        OverlayRenderer.normalizedPayload(String(text.drop(while: { $0 == "\n" || $0 == "\r" })))
    }

    static func correctionGhostMinX(
        caretMinX: CGFloat,
        run: String,
        font: NSFont?
    ) -> CGFloat {
        let font = font ?? NSFont.systemFont(ofSize: 13)
        return caretMinX - (run as NSString).size(withAttributes: [.font: font]).width
    }

    static func presentationFingerprint(
        text: String,
        caret: CGRect,
        font: NSFont?,
        opacity: CGFloat,
        rtl: Bool,
        showHint: Bool
    ) -> String {
        let rect = caret.isNull
            ? "null"
            : [caret.origin.x, caret.origin.y, caret.width, caret.height]
                .map { String(format: "%.17g", Double($0)) }
                .joined(separator: ":")
        return [
            text,
            rect,
            OverlayStabilityGate.fontKey(font) ?? "default",
            String(format: "%.17g", Double(opacity)),
            rtl ? "rtl" : "ltr",
            showHint ? "hint" : "nohint"
        ].joined(separator: "\u{001F}")
    }
}
