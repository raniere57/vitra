import AppKit

/// The little round buttons in a pane's top-right corner, shown while the
/// pointer is in the pane.
///
/// Closing a terminal by typing `exit` means going into it first, and giving a
/// pane the whole window has no gesture at all; both are one move for a pointer
/// that is already over the pane. Hidden at rest because buttons sitting
/// permanently over the top-right corner of every pane are buttons covering the
/// text that scrolls past them.
final class PaneCornerButton: NSView {
    enum Kind {
        /// Closes the pane. Red under the pointer, because it destroys.
        case close
        /// Gives the pane the whole window, and gives it back.
        case zoom
    }

    var onClick: (() -> Void)?

    /// Each button is 18pt, laid out `margin` in from the pane's corner.
    static let size: CGFloat = 18
    static let margin: CGFloat = 6

    /// Only meaningful for `.zoom`: the glyph and the tooltip say which way the
    /// click goes.
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            toolTip = tooltip
            needsDisplay = true
        }
    }

    private let kind: Kind

    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    private var tracking: NSTrackingArea?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        toolTip = tooltip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private var tooltip: String {
        switch kind {
        case .close: return "Close this terminal"
        case .zoom: return isOn ? "Back to the other terminals (esc)" : "Give this terminal the window"
        }
    }

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
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let plate = bounds.insetBy(dx: 0.5, dy: 0.5)
        plateColor.setFill()
        NSBezierPath(roundedRect: plate, xRadius: plate.width / 2, yRadius: plate.height / 2).fill()

        let ink = hovering ? NSColor.white : NSColor(white: 0.88, alpha: 0.9)
        switch kind {
        case .close: drawCross(in: plate, ink: ink)
        case .zoom: drawCorners(in: plate, ink: ink)
        }
    }

    private var plateColor: NSColor {
        guard hovering else { return NSColor(white: 0.30, alpha: 0.55) }
        switch kind {
        case .close: return NSColor(srgbRed: 0.78, green: 0.28, blue: 0.32, alpha: 0.92)
        case .zoom: return NSColor(white: 0.45, alpha: 0.92)
        }
    }

    private func drawCross(in plate: NSRect, ink: NSColor) {
        let inset = plate.insetBy(dx: plate.width * 0.32, dy: plate.height * 0.32)
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: inset.minX, y: inset.minY))
        cross.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
        cross.move(to: NSPoint(x: inset.minX, y: inset.maxY))
        cross.line(to: NSPoint(x: inset.maxX, y: inset.minY))
        cross.lineWidth = 1.5
        cross.lineCapStyle = .round
        ink.setStroke()
        cross.stroke()
    }

    /// Two brackets pointing out to maximise, in to come back: the same shape
    /// the rest of the Mac uses for full screen, at eighteen points.
    private func drawCorners(in plate: NSRect, ink: NSColor) {
        let box = plate.insetBy(dx: plate.width * 0.28, dy: plate.height * 0.28)
        let arm = box.width * 0.42
        let path = NSBezierPath()

        if isOn {
            // Pointing in: the corners sit at the outside, arms reaching back.
            path.move(to: NSPoint(x: box.minX, y: box.minY + arm))
            path.line(to: NSPoint(x: box.minX + arm, y: box.minY + arm))
            path.line(to: NSPoint(x: box.minX + arm, y: box.minY))
            path.move(to: NSPoint(x: box.maxX, y: box.maxY - arm))
            path.line(to: NSPoint(x: box.maxX - arm, y: box.maxY - arm))
            path.line(to: NSPoint(x: box.maxX - arm, y: box.maxY))
        } else {
            path.move(to: NSPoint(x: box.minX, y: box.minY + arm))
            path.line(to: NSPoint(x: box.minX, y: box.minY))
            path.line(to: NSPoint(x: box.minX + arm, y: box.minY))
            path.move(to: NSPoint(x: box.maxX, y: box.maxY - arm))
            path.line(to: NSPoint(x: box.maxX, y: box.maxY))
            path.line(to: NSPoint(x: box.maxX - arm, y: box.maxY))
        }

        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        ink.setStroke()
        path.stroke()
    }
}
