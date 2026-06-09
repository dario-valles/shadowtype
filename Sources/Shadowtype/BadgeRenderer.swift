// BadgeRenderer — a small "active field" chip pinned to the left edge of the focused editable field
// whenever Shadowtype is active. It never steals focus (nonactivating panel) and the ghost-text
// suggestion still renders at the caret via OverlayRenderer, but a left-click opens a scoped
// disable/settings menu (Cotypist parity) supplied by `menuProvider`. Panel setup mirrors
// OverlayRenderer's overlay NSPanel.
import Cocoa
import QuartzCore

// The chip's content view: forwards a left-click up to the renderer's `onMouseDown` so it can pop the
// context menu. Layer drawing lives here too (the renderer configures the layers after init).
private final class BadgeView: NSView {
    var onMouseDown: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onMouseDown?() }
}

final class BadgeRenderer {
    private let panel: NSPanel
    private let view: BadgeView
    private let size: CGFloat = 20          // chip diameter (pt)
    private let gap: CGFloat = 6            // space between the chip and the field's left edge

    // Supplies a freshly-built menu per click (so it reflects the current app/domain). Set by AppDelegate.
    var menuProvider: (() -> NSMenu)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true                          // a floating chip, unlike the shadowless ghost
        panel.ignoresMouseEvents = false                // clickable: opens the scoped disable menu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        view = BadgeView(frame: panel.frame)
        view.wantsLayer = true
        if let layer = view.layer {
            layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer.cornerRadius = size / 2                // circular chip
            layer.borderWidth = 1
            layer.borderColor = NSColor.separatorColor.cgColor
            layer.addSublayer(Self.makeGlyphLayer(in: CGRect(x: 0, y: 0, width: size, height: size)))
        }
        panel.contentView = view
        view.onMouseDown = { [weak self] in self?.popUpMenu() }
    }

    // Pop the provider's menu at the chip's bottom-left, in the chip's coordinate space.
    private func popUpMenu() {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: view)
    }

    // Place the chip just left of the focused field and reveal it. When a usable `caret` rect is given
    // the chip is anchored to the caret LINE (a tall compose box's own midpoint sits far below where
    // the user is actually typing — the Gmail "chip floats mid-box in the avatar gutter" bug).
    func show(at fieldRect: CGRect, caret: CGRect? = nil) {
        let screen = NSScreen.screens.first { $0.frame.intersects(fieldRect) }?.frame
            ?? NSScreen.main?.frame ?? .zero
        let origin = Self.badgeOrigin(for: fieldRect, caret: caret, size: size, gap: gap, screen: screen)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: size, height: size), display: false)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel.orderOut(nil)
    }

    // Pure geometry: chip sits in the gutter just left of the field, vertically centred on the CARET
    // line when we have one (else on the field). Clamp so a field flush against the left screen edge
    // keeps the chip on-screen (it then overlaps the field's left edge rather than disappearing past
    // the bezel). Cocoa bottom-left coords.
    static func badgeOrigin(for fieldRect: CGRect, caret: CGRect? = nil,
                            size: CGFloat, gap: CGFloat, screen: CGRect) -> CGPoint {
        let x = max(screen.minX, fieldRect.minX - size - gap)
        // Anchor to the caret line so the chip sits beside the text being typed, not at the centre of a
        // tall (mostly empty) compose box. Fall back to the field centre when no usable caret is known.
        let anchorMidY: CGFloat = {
            if let c = caret, !c.isNull, c.height > 0 { return c.midY }
            return fieldRect.midY
        }()
        let y = anchorMidY - size / 2
        return CGPoint(x: x, y: y)
    }

    // The brand I-beam caret, tinted, centred in the chip. Polygon mirrors the menu-bar silhouette
    // in StatusItemController.makeGlyph() (web/assets/logo.svg, model space 196×460).
    private static func makeGlyphLayer(in rect: CGRect) -> CALayer {
        let glyphHeight = rect.height * 0.62            // leave padding inside the chip
        let scale = glyphHeight / 460
        let pts: [(CGFloat, CGFloat)] = [
            (-98, -230), (98, -230), (98, -180), (26, -180), (26, 180), (98, 180),
            (98, 230), (-98, 230), (-98, 180), (-26, 180), (-26, -180), (-98, -180),
        ]
        let path = CGMutablePath()
        for (i, p) in pts.enumerated() {
            let pt = CGPoint(x: rect.midX + p.0 * scale, y: rect.midY + p.1 * scale)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()

        let layer = CAShapeLayer()
        layer.path = path
        // Brand purple (matches logo-small-256.png); fall back to the system accent if unavailable.
        let brand = NSColor(srgbRed: 0.36, green: 0.29, blue: 0.86, alpha: 1)
        layer.fillColor = brand.cgColor
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        return layer
    }
}
