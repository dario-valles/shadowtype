// RewriteHUD — a small floating HUD shown under the caret during a selection rewrite. Two states:
//   • working: a spinner + "Rewriting…" while the model generates
//   • hint:    "⏎ keep   ⌘R redo   ⎋ undo" after the result is placed inline
// Non-activating borderless NSPanel so it never steals focus from the host app (the selection/caret must
// stay live for inject + re-select). Panel setup mirrors BadgeRenderer/OverlayRenderer. Main-thread only
// (see memory: Coordinator/OverlayRenderer aren't @MainActor — UI callers must hop to main first).
import Cocoa

final class RewriteHUD {
    private let panel: NSPanel
    private let label: NSTextField
    private let spinner: NSProgressIndicator
    private let stack: NSStackView
    private let hPad: CGFloat = 12
    private let vPad: CGFloat = 7
    private let gapBelowCaret: CGFloat = 6

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 28),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true                 // purely informational; keys come via RewriteKeyTap
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 7
        effect.layer?.masksToBounds = true

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: hPad),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -hPad),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: vPad),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -vPad),
        ])
        panel.contentView = effect
    }

    // Working state: spinner + message, anchored under the caret.
    func showWorking(at caretRect: CGRect, message: String = "Rewriting…") {
        spinner.isHidden = false
        spinner.startAnimation(nil)
        setLabel(message)
        place(under: caretRect)
    }

    // Hint state: the keep/redo/undo affordances, anchored under the caret.
    func showHint(at caretRect: CGRect, text: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        setLabel(text)
        place(under: caretRect)
    }

    func hide() {
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }

    private func setLabel(_ s: String) {
        label.stringValue = s
    }

    // Size to fit and position centred under the caret, clamped on-screen. caretRect is Cocoa
    // bottom-left; the HUD sits just BELOW the caret line (caret.minY - gap - height).
    private func place(under caretRect: CGRect) {
        panel.layoutIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: 160, height: 28)
        let w = max(120, ceil(fitting.width))
        let h = max(26, ceil(fitting.height))

        let screen = NSScreen.screens.first { $0.frame.intersects(caretRect) }?.frame
            ?? NSScreen.main?.frame ?? .zero
        var x = caretRect.midX - w / 2
        x = min(max(screen.minX + 4, x), screen.maxX - w - 4)
        var y = caretRect.minY - gapBelowCaret - h
        if y < screen.minY + 4 { y = caretRect.maxY + gapBelowCaret }   // flip above if no room below

        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
