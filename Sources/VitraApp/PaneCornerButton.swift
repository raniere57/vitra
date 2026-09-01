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
        /// Moves the pane out into a tab of its own.
        case tab
    }

    var onClick: (() -> Void)?

    /// The button was dragged rather than clicked. Only `.tab` uses it: the
    /// pane goes wherever it is dropped.
    var onDrag: ((NSEvent) -> Void)?

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
    /// Set once a press turns into a drag, so the release is not also a click.
    private var dragged = false

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
        case .tab: return "Move this terminal to a new tab"
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
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let onDrag, !dragged else { return }
        // Three points, so a click with an unsteady hand is still a click.
        let start = convert(event.locationInWindow, from: nil)
        guard !bounds.insetBy(dx: -3, dy: -3).contains(start) || abs(event.deltaX) + abs(event.deltaY) > 3
        else { return }
        dragged = true
        onDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
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
        case .tab: drawTab(in: plate, ink: ink)
        }
    }

    private var plateColor: NSColor {
        guard hovering else { return NSColor(white: 0.30, alpha: 0.55) }
        switch kind {
        case .close: return NSColor(srgbRed: 0.78, green: 0.28, blue: 0.32, alpha: 0.92)
        case .zoom, .tab: return NSColor(white: 0.45, alpha: 0.92)
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

    /// A pane leaving its window: a box, and an arrow going out of the top.
    private func drawTab(in plate: NSRect, ink: NSColor) {
        let box = plate.insetBy(dx: plate.width * 0.28, dy: plate.height * 0.28)
        ink.setStroke()

        // The box is drawn short of the top-right, where the arrow leaves it.
        let frame = NSBezierPath(
            roundedRect: NSRect(
                x: box.minX,
                y: box.minY,
                width: box.width * 0.7,
                height: box.height * 0.7
            ),
            xRadius: 1.5,
            yRadius: 1.5
        )
        frame.lineWidth = 1.3
        frame.stroke()

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: box.midX, y: box.midY))
        arrow.line(to: NSPoint(x: box.maxX, y: box.maxY))
        arrow.move(to: NSPoint(x: box.maxX - box.width * 0.34, y: box.maxY))
        arrow.line(to: NSPoint(x: box.maxX, y: box.maxY))
        arrow.line(to: NSPoint(x: box.maxX, y: box.maxY - box.height * 0.34))
        arrow.lineWidth = 1.4
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()
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
