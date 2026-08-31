import AppKit
import VitraCore

/// The gutter beside the terminal: one rail per command, and how it ended.
///
/// Drawn over the terminal rather than in it: the marks are chrome, they change
/// only when a command starts or finishes, and keeping them out of the Metal
/// path leaves the glyph renderer a glyph renderer.
final class CommandBlockView: NSView {
    /// How wide a column the marks need. The terminal grid starts after it.
    static let width: CGFloat = 22

    private var blocks: [CommandBlock] = []
    private var statuses: [CommandStatus] = []
    /// How long the command in the newest block has been running, if one is.
    private var running: TimeInterval?
    private var cellHeight: CGFloat = 0
    private var padding: CGFloat = 8

    var railColor: NSColor = NSColor(white: 0.45, alpha: 0.45)
    var currentRailColor: NSColor = .controlAccentColor
    var failureColor: NSColor = NSColor(srgbRed: 0.88, green: 0.33, blue: 0.38, alpha: 1)
    var successColor: NSColor = NSColor(srgbRed: 0.55, green: 0.76, blue: 0.40, alpha: 1)
    var labelColor: NSColor = NSColor(white: 0.55, alpha: 1)
    var runningColor: NSColor = NSColor(srgbRed: 0.84, green: 0.65, blue: 0.36, alpha: 1)
    var separatorColor: NSColor = NSColor(white: 1, alpha: 0.07)

    /// Never takes a click: selecting text through the gutter has to keep working.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Takes this frame's blocks, and redraws only when something moved.
    ///
    /// The terminal redraws on every keystroke; the gutter changes when a
    /// command starts or ends, which is thousands of times less often.
    func update(
        blocks: [CommandBlock],
        statuses: [CommandStatus],
        running: TimeInterval?,
        cellHeight: CGFloat,
        padding: CGFloat
    ) {
        // The running time is rounded to a tenth before comparing, so a command
        // that takes a minute redraws ten times a second at most.
        let rounded = running.map { ($0 * 10).rounded() / 10 }
        guard blocks != self.blocks
            || statuses != self.statuses
            || rounded != self.running
            || cellHeight != self.cellHeight
            || padding != self.padding
        else { return }

        self.blocks = blocks
        self.statuses = statuses
        self.running = rounded
        self.cellHeight = cellHeight
        self.padding = padding
        needsDisplay = true
    }

    /// The status of the block at `index`, counting from the newest.
    ///
    /// The newest block is the prompt waiting for input, so it has no status
    /// yet; the one above it is the command that just finished, and so on back.
    private func status(forBlockAt index: Int) -> CommandStatus? {
        let fromNewest = blocks.count - 1 - index
        guard fromNewest > 0 else { return nil }
        let slot = fromNewest - 1
        return slot < statuses.count ? statuses[slot] : nil
    }

    /// Whether the running command has been going long enough to stop shouting.
    ///
    /// A shell inside `ssh` or `vim` is a command that runs for as long as you
    /// use it, and an amber bar pulsing beside it for an hour is noise. The
    /// clock stays — it is true — but it stops being an alert.
    private var isLongRunning: Bool { (running ?? 0) > Self.calmAfter }

    /// After this long a running command stops being news and starts being
    /// where you live. Short enough that `ssh` calms down before you notice it.
    private static let calmAfter: TimeInterval = 15

    override func draw(_ dirtyRect: NSRect) {
        guard cellHeight > 0, !blocks.isEmpty else { return }

        // Rows count from the top of the terminal, and this view does not.
        func top(ofRow row: Int) -> CGFloat {
            bounds.height - padding - CGFloat(row) * cellHeight
        }

        let railWidth: CGFloat = 3
        let railX = padding + (Self.width - railWidth) / 2
        let contentX = padding + Self.width

        for (index, block) in blocks.enumerated() {
            let isCurrent = index == blocks.count - 1
            let status = status(forBlockAt: index)
            // The rail starts on the line the command is on, not on the blank
            // line the prompt begins with: that blank line is the gap between
            // blocks, and a rail drawn through it both closes the gap and sits
            // a row higher than the text it belongs to.
            let statusRowTop = top(ofRow: block.commandRow)
            let upper = statusRowTop
            let lower = top(ofRow: block.rows.upperBound)

            // Four colours that are not each other, and every other rail a
            // shade down: a screen where every command succeeded is a column of
            // one green otherwise, and you cannot see where a block ends.
            let base: NSColor
            switch (isCurrent, status) {
            case (true, _) where isLongRunning: base = railColor
            case (true, _) where running != nil: base = runningColor
            case (true, _): base = currentRailColor
            case (_, let status?) where status.failed: base = failureColor
            case (_, let status?) where status.exitCode != nil: base = successColor
            default: base = railColor
            }
            let color = isCurrent || index.isMultiple(of: 2)
                ? base
                : base.withAlphaComponent(base.alphaComponent * 0.55)

            // The line that says one command ended and the next began. It goes
            // on the blank row above the command, so it divides without ever
            // crossing output, and only where there is a blank row to take it.
            if index > 0, block.commandRow > block.rows.lowerBound {
                separatorColor.setFill()
                NSRect(
                    x: padding,
                    y: (upper + cellHeight / 2).rounded(),
                    width: max(0, bounds.width - padding * 2),
                    height: 1
                ).fill()
            }

            let rail = NSRect(x: railX, y: lower, width: railWidth, height: max(cellHeight, upper - lower))
            color.setFill()
            NSBezierPath(roundedRect: rail, xRadius: railWidth / 2, yRadius: railWidth / 2).fill()

            if isCurrent, let running {
                draw(
                    label: "running · \(Self.elapsed(running))",
                    color: isLongRunning ? labelColor : runningColor,
                    filled: !isLongRunning,
                    atRowTop: statusRowTop,
                    contentX: contentX
                )
            } else if let status, let label = status.label {
                draw(
                    label: label,
                    color: status.failed ? failureColor : labelColor,
                    filled: status.failed,
                    atRowTop: statusRowTop,
                    contentX: contentX
                )
            }
        }
    }

    /// The exit code and duration, right-aligned on the command's own line.
    ///
    /// On that line and nowhere else: it belongs to the command you typed, and
    /// putting it beside the output would read as part of the output.
    private func draw(
        label: String,
        color: NSColor,
        filled: Bool,
        atRowTop rowTop: CGFloat,
        contentX: CGFloat
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: color,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        let box = NSRect(
            x: bounds.width - padding - size.width - 8,
            y: rowTop - cellHeight + (cellHeight - size.height) / 2,
            width: size.width + 8,
            height: size.height
        )
        guard box.minX > contentX else { return }

        if filled {
            color.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: box.insetBy(dx: -2, dy: -1), xRadius: 4, yRadius: 4).fill()
        }
        text.draw(at: NSPoint(x: box.minX + 4, y: box.minY))
    }

    /// `12.4s`, or `2m 03s` once a command has been going a while.
    private static func elapsed(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60)
    }
}
