import AppKit
import VitraCore

extension Harness {
    /// The mark in the title bar for this agent's sidebar.
    ///
    /// Drawn rather than borrowed from SF Symbols, because the two buttons sit
    /// next to each other and a clock beside a pair of angle brackets says only
    /// that neither icon was about the thing it opens. These are the same two
    /// marks the sessions themselves carry — the spark and the diamond — at the
    /// weight of the system's own title-bar glyphs, so the button and the list
    /// under it are recognisably one thing.
    var icon: NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            switch self {
            case .claudeCode: Harness.drawSpark(in: rect)
            case .openCode: Harness.drawDiamond(in: rect)
            }
            return true
        }
        // A template image takes the button's own tint, which is what makes the
        // open sidebar's button light up in the accent colour like the others.
        image.isTemplate = true
        return image
    }

    /// Eight rays from a hollow centre: the spark this app has always put in
    /// front of a Claude Code session.
    private static func drawSpark(in rect: NSRect) {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let inner: CGFloat = 1.1
        let outer: CGFloat = 6.6
        let path = NSBezierPath()
        for ray in 0 ..< 8 {
            let angle = CGFloat(ray) * .pi / 4
            path.move(to: NSPoint(x: centre.x + cos(angle) * inner, y: centre.y + sin(angle) * inner))
            path.line(to: NSPoint(x: centre.x + cos(angle) * outer, y: centre.y + sin(angle) * outer))
        }
        path.lineWidth = 1.7
        path.lineCapStyle = .round
        NSColor.black.setStroke()
        path.stroke()
    }

    /// A diamond around a diamond: the mark opencode's sessions carry, opened
    /// out so it reads at the same size as the spark beside it.
    private static func drawDiamond(in rect: NSRect) {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let outer = NSBezierPath()
        let radius: CGFloat = 6.4
        outer.move(to: NSPoint(x: centre.x, y: centre.y + radius))
        outer.line(to: NSPoint(x: centre.x + radius, y: centre.y))
        outer.line(to: NSPoint(x: centre.x, y: centre.y - radius))
        outer.line(to: NSPoint(x: centre.x - radius, y: centre.y))
        outer.close()
        outer.lineWidth = 1.7
        outer.lineJoinStyle = .round
        outer.stroke()

        let core = NSBezierPath()
        let heart: CGFloat = 2.4
        core.move(to: NSPoint(x: centre.x, y: centre.y + heart))
        core.line(to: NSPoint(x: centre.x + heart, y: centre.y))
        core.line(to: NSPoint(x: centre.x, y: centre.y - heart))
        core.line(to: NSPoint(x: centre.x - heart, y: centre.y))
        core.close()
        core.fill()
    }
}
