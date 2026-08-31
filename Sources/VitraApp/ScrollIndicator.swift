import AppKit
import VitraCore

/// A thumb on the right edge saying where the viewport sits in the scrollback.
///
/// Overlaid, never reserved: the width of a terminal belongs to its text. It
/// shows itself only while the viewport is off the live screen — at the bottom,
/// which is where a terminal spends its life, there is nothing to say and
/// nothing is drawn. No timer, no fade: it appears and disappears with the
/// scroll position it is reporting.
final class ScrollIndicator: NSView {
    private static let thumbWidth: CGFloat = 4
    private static let margin: CGFloat = 3
    private static let minimumThumb: CGFloat = 24

    var color: NSColor = .white {
        didSet { needsDisplay = true }
    }

    private var position = ScrollPosition()

    func update(_ position: ScrollPosition) {
        guard position != self.position else { return }
        self.position = position
        isHidden = !position.isScrollable || position.isAtBottom
        needsDisplay = true
    }

    /// Clicks belong to the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard position.isScrollable, !position.isAtBottom else { return }

        let track = bounds.height
        let visible = CGFloat(position.visible) / CGFloat(position.total)
        let height = max(Self.minimumThumb, (track * visible).rounded())
        // The thumb travels the track minus its own height, so its top edge at
        // the top of the scrollback and its bottom edge at the live screen.
        let travel = max(0, track - height)
        let progress = CGFloat(position.offset) / CGFloat(max(1, position.total - position.visible))
        let top = travel * min(1, max(0, progress))

        let thumb = NSRect(
            x: bounds.maxX - Self.margin - Self.thumbWidth,
            y: bounds.maxY - top - height,
            width: Self.thumbWidth,
            height: height
        )
        color.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: Self.thumbWidth / 2, yRadius: Self.thumbWidth / 2).fill()
    }
}
