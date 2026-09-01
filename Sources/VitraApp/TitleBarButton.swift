import AppKit

/// A borderless icon button in the title bar that answers the pointer.
///
/// The icons here are small and unlabelled, and a control that does not change
/// under the pointer reads as decoration: the plate that lights on hover is how
/// the row says which of them is about to be pressed. The open one keeps the
/// accent plate it already had, and hover only deepens it.
final class TitleBarButton: NSButton {
    /// Whether what this button opens is open — the accent plate.
    var isLit = false {
        didSet { if isLit != oldValue { refresh() } }
    }

    private var hovering = false {
        didSet { if hovering != oldValue { refresh() } }
    }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// A window that loses the pointer without an exit event — one closing
    /// under it, or a menu opening over it — would keep the plate lit.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovering = false
    }

    private func refresh() {
        wantsLayer = true
        layer?.cornerRadius = 6
        let colour: NSColor
        switch (isLit, hovering) {
        case (true, true): colour = NSColor.controlAccentColor.withAlphaComponent(0.32)
        case (true, false): colour = NSColor.controlAccentColor.withAlphaComponent(0.20)
        case (false, true): colour = NSColor.labelColor.withAlphaComponent(0.12)
        case (false, false): colour = .clear
        }
        layer?.backgroundColor = colour.cgColor
    }
}
