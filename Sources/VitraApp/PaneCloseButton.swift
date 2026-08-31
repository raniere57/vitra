import AppKit

/// The × in a pane's top-right corner, shown while the pointer is in the pane.
///
/// Closing a terminal by typing `exit` means going into it first, which is two
/// moves for something the pointer is already over. Hidden at rest because a
/// button sitting permanently over the top-right corner of every pane is a
/// button covering the text that scrolls past it.
final class PaneCloseButton: NSView {
    var onClose: (() -> Void)?

    /// The button is 18pt, laid out `margin` in from the pane's corner.
    static let size: CGFloat = 18
    static let margin: CGFloat = 6

    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        toolTip = "Close this terminal"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        // Swallowed rather than passed on: a click meant for the button is not
        // a click in the grid, and must not move the selection.
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClose?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let plate = bounds.insetBy(dx: 0.5, dy: 0.5)
        (hovering
            ? NSColor(srgbRed: 0.78, green: 0.28, blue: 0.32, alpha: 0.92)
            : NSColor(white: 0.30, alpha: 0.55)
        ).setFill()
        NSBezierPath(roundedRect: plate, xRadius: plate.width / 2, yRadius: plate.height / 2).fill()

        let inset = plate.insetBy(dx: plate.width * 0.32, dy: plate.height * 0.32)
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: inset.minX, y: inset.minY))
        cross.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
        cross.move(to: NSPoint(x: inset.minX, y: inset.maxY))
        cross.line(to: NSPoint(x: inset.maxX, y: inset.minY))
        cross.lineWidth = 1.5
        cross.lineCapStyle = .round
        (hovering ? NSColor.white : NSColor(white: 0.88, alpha: 0.9)).setStroke()
        cross.stroke()
    }
}
