import AppKit

/// The measurements both sidebars are drawn to.
///
/// One place for them because the two lists sit in the same 260pt column and
/// the eye reads them as one surface: a folder row and a session row that start
/// at different margins look like a mistake, and they were.
enum SidebarStyle {
    /// The margin everything lines up to: the search field, the rows, the
    /// footer.
    static let inset: CGFloat = 10
    /// How far the plate behind a row is inset from the sidebar's edges.
    static let plateInset: CGFloat = 6
    static let corner: CGFloat = 6

    static let folderRow: CGFloat = 26
    static let sessionRow: CGFloat = 46
    static let projectRow: CGFloat = 30

    static var hover: NSColor { NSColor(white: 1, alpha: 0.06) }
    static var selection: NSColor { NSColor(white: 1, alpha: 0.10) }
    /// The rail marking the session a pane is in, and anything else that means
    /// "you are here".
    static var accent: NSColor { NSColor(srgbRed: 0.486, green: 0.753, blue: 1, alpha: 1) }
}

/// A row that lights under the pointer and keeps its corners.
///
/// The stock selection is a full-bleed blue bar, which in a dark sidebar reads
/// as a scar across the column. This is a plate inset from both edges, in the
/// same shape as everything else here.
final class SidebarRowView: NSTableRowView {
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    /// Set on rows that are headers rather than items: they take no plate.
    var isPlain = false

    /// A hairline along the top, inset like everything else. What separates one
    /// project from the next without a full-bleed rule cutting the column.
    var topRule = false

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if topRule {
            NSColor.separatorColor.withAlphaComponent(0.28).setFill()
            NSRect(
                x: SidebarStyle.plateInset,
                // The row is flipped, so the top of it is y zero.
                y: 0,
                width: bounds.width - SidebarStyle.plateInset * 2,
                height: 1
            ).fill()
        }
        guard isHovered, !isSelected, !isPlain else { return }
        SidebarStyle.hover.setFill()
        plate.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isPlain else { return }
        SidebarStyle.selection.setFill()
        plate.fill()
    }

    private var plate: NSBezierPath {
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: SidebarStyle.plateInset, dy: 1),
            xRadius: SidebarStyle.corner,
            yRadius: SidebarStyle.corner
        )
    }
}

/// Keeps the row under the pointer lit, for a table that is not scrolling.
///
/// The tracking lives in the view around the table rather than in a subclass of
/// it, so an outline view and a plain table can share one implementation.
enum SidebarHover {
    static func update(_ table: NSTableView, at point: NSPoint?) {
        let row = point.map { table.row(at: table.convert($0, from: nil)) } ?? -1
        for index in table.rows(in: table.visibleRect).indexes {
            guard let view = table.rowView(atRow: index, makeIfNecessary: false) as? SidebarRowView
            else { continue }
            view.isHovered = index == row
        }
    }
}

private extension NSRange {
    /// The rows of a range, as something to iterate.
    var indexes: Range<Int> { location ..< (location + length) }
}
