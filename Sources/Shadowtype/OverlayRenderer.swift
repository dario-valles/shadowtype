// OverlayRenderer — click-through ghost-text overlay following the caret.
// CALayer overlay; validated at ~0.04 ms/frame @120Hz.
import Cocoa
import QuartzCore

final class OverlayRenderer {
    private let panel: NSPanel
    private let textLayer = CATextLayer()
    // Accept-key cue: a keycap drawn to the RIGHT of the ghost the first few times (discoverability),
    // auto-retired by the coordinator after N accepts. Two layers so the label sits truly centered:
    // `hintBg` is the rounded key, `hintLabel` is the text floated on top.
    private let hintBg = CALayer()
    private let hintLabel = CATextLayer()
    private var currentFont: NSFont = .systemFont(ofSize: 16)
    private let hPad: CGFloat = 2
    private let chipFallbackOrigin = CGPoint(x: 80, y: 80) // FR-OV-6: caret rect unavailable
    private let maxGhostChars = 60 // truncate long suggestions so the panel never spans the screen
    private let hintText = "tab ⇥"                          // ⇥ = Tab glyph; lowercase reads as a soft cue
    private let hintGap: CGFloat = 8                        // space between ghost and keycap
    private let hintPadH: CGFloat = 7                       // keycap inner horizontal padding
    private let hintPadV: CGFloat = 3                       // keycap inner vertical padding

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 24),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true                 // FR-OV-1: the click-through switch
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = NSView(frame: panel.frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        textLayer.foregroundColor = NSColor(white: 0.55, alpha: 0.6).cgColor   // faint but readable gray
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.anchorPoint = .zero
        textLayer.position = .zero
        applyFont(currentFont)
        view.layer?.addSublayer(textLayer)

        // Keycap: a faint outlined key (hintBg) with a centered label (hintLabel). Tuned to read on the
        // LIGHT backgrounds the gray ghost already assumes — a subtle gray fill + hairline outline so the
        // key shape is legible without shouting. Hidden until show(showHint:).
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        hintBg.backgroundColor = NSColor(white: 0.5, alpha: 0.10).cgColor
        hintBg.borderColor = NSColor(white: 0.5, alpha: 0.38).cgColor
        hintBg.borderWidth = 1
        hintBg.cornerRadius = 5
        hintBg.contentsScale = scale
        hintBg.anchorPoint = .zero
        hintBg.isHidden = true
        view.layer?.addSublayer(hintBg)

        hintLabel.foregroundColor = NSColor(white: 0.42, alpha: 0.95).cgColor
        hintLabel.alignmentMode = .center
        hintLabel.contentsScale = scale
        hintLabel.anchorPoint = .zero
        hintLabel.isHidden = true
        view.layer?.addSublayer(hintLabel)

        panel.contentView = view
    }

    // Keycap font tracks the ghost size but stays compact and never larger than the host text.
    private func hintFont() -> NSFont {
        .systemFont(ofSize: max(9, min(12, currentFont.pointSize * 0.7)), weight: .medium)
    }

    private func applyFont(_ font: NSFont) {
        // Match the host typeface UPRIGHT (Cotypist parity): the faint gray already reads as a
        // non-committed suggestion, and a forced italic slant just looked mismatched against the
        // host's upright text (e.g. "Perf" + italic "ume de mujer"). Keep whatever traits the host
        // font actually has.
        currentFont = font
        textLayer.font = font as CTFont
        textLayer.fontSize = font.pointSize
    }

    // FR-OV-4: match the host font/size when given; fall back sensibly.
    // `opacity` (FR §4.1) multiplies the ghost's faint base alpha — 1 = normal, lower = the free
    // word-cap fade curve. Default 1 leaves the M1 fixed-string path unchanged.
    func show(text: String, at caretRect: CGRect, font: NSFont?, opacity: CGFloat = 1, rtl: Bool = false,
              showHint: Bool = false) {
        applyFont(font ?? currentFont)

        let display = Self.truncated(text, max: maxGhostChars)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.string = display
        textLayer.opacity = Float(max(0, min(1, opacity)))

        let lineHeight = ceil(currentFont.ascender - currentFont.descender + currentFont.leading)
        let ghostWidth = ceil((display as NSString).size(withAttributes: [.font: currentFont]).width) + hPad * 2
        let h = max(lineHeight, 1)

        // Keycap geometry — only in LTR (RTL would collide with the leftward-flowing continuation).
        // The key sits to the right of the ghost; the panel widens to contain it.
        let drawHint = showHint && !rtl
        let hf = hintFont()
        let labelW = drawHint ? ceil((hintText as NSString).size(withAttributes: [.font: hf]).width) : 0
        let labelH = drawHint ? ceil(hf.ascender - hf.descender) : 0
        let pillW = drawHint ? labelW + hintPadH * 2 : 0
        let pillH = drawHint ? labelH + hintPadV * 2 : 0
        let extra = drawHint ? hintGap + pillW : 0
        let width = ghostWidth + extra

        let origin = caretOrigin(caretRect, height: h, width: width, rtl: rtl)
        // Match the backing scale of the display the ghost actually lands on (not a fixed main-screen
        // scale captured once at init), so text stays crisp on multi-monitor / mixed-Retina setups.
        let targetScale = NSScreen.screens.first { $0.frame.contains(origin) }?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        if textLayer.contentsScale != targetScale { textLayer.contentsScale = targetScale }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: max(width, 1), height: h), display: false)
        panel.contentView?.frame = CGRect(x: 0, y: 0, width: max(width, 1), height: h)
        textLayer.frame = CGRect(x: hPad, y: 0, width: max(ghostWidth - hPad * 2, 1), height: h)

        if drawHint {
            // Keep the keycap at a steady, legible opacity — it shouldn't dim with the free-cap fade,
            // since its whole job is to teach the gesture while suggestions still appear.
            let pillX = ghostWidth + hintGap
            let pillY = ((h - pillH) / 2).rounded()
            hintBg.isHidden = false
            hintBg.contentsScale = targetScale
            hintBg.frame = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)
            // Center the label vertically inside the pill (CATextLayer top-aligns within its own frame).
            hintLabel.isHidden = false
            hintLabel.contentsScale = targetScale
            hintLabel.font = hf as CTFont
            hintLabel.fontSize = hf.pointSize
            hintLabel.string = hintText
            hintLabel.frame = CGRect(x: pillX + hintPadH, y: pillY + hintPadV, width: labelW, height: labelH)
        } else {
            hintBg.isHidden = true
            hintLabel.isHidden = true
        }
        CATransaction.commit()

        if !panel.isVisible { panel.orderFrontRegardless() }
        Diag.log("overlay: show frame=\(Int(origin.x)),\(Int(origin.y)) \(Int(max(width,1)))x\(Int(h)) visible=\(panel.isVisible) screen=\(NSScreen.main.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "?")")
    }

    func hide() {
        panel.orderOut(nil)
    }

    // Cap visible length so a runaway suggestion can't produce a 700px-wide panel; append an ellipsis.
    static func truncated(_ text: String, max: Int) -> String {
        guard text.count > max, max > 0 else { return text }
        return String(text.prefix(max)) + "\u{2026}"
    }

    // Map a caret rect (top-left origin, screen coords) to a bottom-left panel origin.
    // FR-OV-6: fall back to a fixed chip position when the caret rect is null/empty.
    private func caretOrigin(_ caretRect: CGRect, height: CGFloat, width: CGFloat, rtl: Bool) -> CGPoint {
        // A caret (insertion point) is a ZERO-WIDTH rect, so CGRect.isEmpty is true for it — we must
        // NOT treat that as "no caret" or we'd wrongly use the fallback. Only fall back when the rect
        // is genuinely unusable: null, or zero in BOTH dimensions (FR-OV-6).
        let unusable = caretRect.isNull || (caretRect.width <= 0 && caretRect.height <= 0)
        guard !unusable else {
            let screen = NSScreen.main?.frame ?? .zero
            return CGPoint(x: screen.minX + chipFallbackOrigin.x, y: screen.minY + chipFallbackOrigin.y)
        }
        // caretRect.maxY is the caret baseline area; AppKit windows are bottom-left origin.
        // #11: in a right-to-left field the continuation flows leftward, so anchor the panel's RIGHT
        // edge at the caret (origin shifted left by the panel width) instead of its left edge.
        let x = rtl ? caretRect.minX - width : caretRect.minX
        return CGPoint(x: x, y: caretRect.maxY - height)
    }
}
