import AppKit

/// Leitura's look: the reading measure, the faces and the colours, all from
/// the cockpit's theme. Prose is set in the UI face, larger and looser than
/// anywhere else in the cockpit, because it is read at length; only code is
/// monospaced.
@MainActor
enum ReadingStyle {
    // MARK: Measure

    /// The widest the text column gets: about 90 characters of body text.
    static let maxColumn: CGFloat = 720
    /// The least space either side of the column, in a narrow pane.
    static let minSide: CGFloat = 20

    /// The column's frame inside a row `width` wide.
    static func column(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let column = max(min(maxColumn, width - 2 * minSide), 120)
        return ((width - column) / 2, column)
    }

    // MARK: Faces

    static let bodySize: CGFloat = 14
    static var body: NSFont { CockpitStyle.ui(bodySize) }
    static var bodyBold: NSFont { CockpitStyle.ui(bodySize, .semibold) }
    static var inlineCode: NSFont { CockpitStyle.mono(12.5) }
    static var code: NSFont { CockpitStyle.mono(12.5) }
    static var small: NSFont { CockpitStyle.ui(12.5) }
    static var smallMedium: NSFont { CockpitStyle.ui(12.5, .medium) }

    static func heading(_ level: Int) -> NSFont {
        switch level {
        case 1: CockpitStyle.ui(19, .semibold)
        case 2: CockpitStyle.ui(16.5, .semibold)
        default: CockpitStyle.ui(14.5, .semibold)
        }
    }

    // MARK: Colours

    static let page = CockpitStyle.ground
    static let text = CockpitStyle.text
    static let quiet = CockpitStyle.muted
    /// Fainter than muted: footers and the "pensou" marker.
    static let faint = NSColor(srgbRed: 0x6C / 255, green: 0x72 / 255, blue: 0x7C / 255, alpha: 1)
    static let link = NSColor(srgbRed: 0x8F / 255, green: 0xB8 / 255, blue: 0xE8 / 255, alpha: 1)
    nonisolated static let chip = NSColor(srgbRed: 0x23 / 255, green: 0x27 / 255, blue: 0x2E / 255, alpha: 1)
    static let codePanel = CockpitStyle.panel
    static let codeLine = CockpitStyle.line
    static let tableRule = CockpitStyle.line
    static let tableHeader = NSColor(srgbRed: 0x1A / 255, green: 0x1D / 255, blue: 0x22 / 255, alpha: 1)
    /// The user's block: the graphite warmed by a breath of the amber.
    static let mine = NSColor(srgbRed: 0x22 / 255, green: 0x1F / 255, blue: 0x1B / 255, alpha: 1)
    static let mineEdge = CockpitStyle.accent.withAlphaComponent(0.20)

    // MARK: Paragraphs

    static let lineHeight: CGFloat = 1.24
    static let paragraphGap: CGFloat = 11

    static func paragraphStyle(
        indent: CGFloat = 0, firstIndent: CGFloat? = nil, before: CGFloat = 0, after: CGFloat = paragraphGap,
        alignment: NSTextAlignment = .natural, tabs: [CGFloat] = []
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.headIndent = indent
        style.firstLineHeadIndent = firstIndent ?? indent
        style.alignment = alignment
        style.tabStops = tabs.map { NSTextTab(textAlignment: .left, location: $0) }
        style.defaultTabInterval = 18
        return style
    }

    /// Plain text in the reading face: a user's message, say.
    static func plain(_ text: String, font: NSFont = body, color: NSColor = text) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color,
            .paragraphStyle: paragraphStyle(after: 6),
        ])
    }
}
