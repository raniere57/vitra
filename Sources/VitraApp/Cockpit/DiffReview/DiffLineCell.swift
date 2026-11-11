import AppKit

/// Where everything on a diff line sits. One per diff: the gutters are as
/// wide as the longest line number needs, so the code column never moves
/// from one line to the next.
struct DiffGeometry {
    static let lineHeight: CGFloat = 18
    /// Past this many characters a line is cut when drawn; minified files
    /// have lines of megabytes, and nobody comments on column 30 000.
    static let longestDrawn = 2_000

    let font = CockpitStyle.source
    let advance: CGFloat
    let digits: Int

    init(largestNumber: Int) {
        advance = ("0" as NSString).size(withAttributes: [.font: CockpitStyle.source]).width
        digits = max(3, String(largestNumber).count)
    }

    var numberWidth: CGFloat { CGFloat(digits) * advance }
    var oldX: CGFloat { CockpitStyle.inset }
    var newX: CGFloat { oldX + numberWidth + CockpitStyle.Space.md }
    /// The two number columns: a click in here comments on the line.
    var gutterWidth: CGFloat { newX + numberWidth + CockpitStyle.Space.md }
    var signX: CGFloat { gutterWidth + CockpitStyle.Space.md }
    var textX: CGFloat { signX + advance + CockpitStyle.Space.sm }

    /// How wide the table must be for a line of `columns` characters.
    func width(columns: Int) -> CGFloat {
        textX + CGFloat(min(columns, Self.longestDrawn)) * advance + CockpitStyle.inset
    }
}

/// One line of code with its two numbers. Drawn by hand rather than built of
/// labels: a screenful of these is redrawn on every scroll step.
final class DiffLineCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("diff.line")

    var geometry = DiffGeometry(largestNumber: 0)
    var line = DiffLine(kind: .context, text: "", old: nil, new: nil) {
        didSet { needsDisplay = true }
    }
    var hasComment = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let font = geometry.font
        let top = (bounds.height - (font.ascender - font.descender)) / 2
        let muted: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CockpitStyle.muted.withAlphaComponent(0.7)]

        CockpitStyle.softLine.setFill()
        NSRect(x: geometry.gutterWidth, y: 0, width: 1, height: bounds.height).fill()

        for (number, x) in [(line.old, geometry.oldX), (line.new, geometry.newX)] {
            guard let number else { continue }
            let text = String(number) as NSString
            let width = text.size(withAttributes: muted).width
            text.draw(at: NSPoint(x: x + geometry.numberWidth - width, y: top), withAttributes: muted)
        }
        if hasComment {
            // A comment hangs under this line: a dot in the gutter says so
            // even when the note itself is scrolled out of view.
            CockpitStyle.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: geometry.oldX - 9, y: bounds.midY - 2.5, width: 5, height: 5)).fill()
        }

        let (sign, signColor): (String, NSColor) = switch line.kind {
        case .added: ("+", CockpitStyle.success)
        case .removed: ("−", CockpitStyle.dangerText)
        case .context: (" ", CockpitStyle.muted)
        }
        (sign as NSString).draw(at: NSPoint(x: geometry.signX, y: top), withAttributes: [.font: font, .foregroundColor: signColor])

        let code = String(line.text.prefix(DiffGeometry.longestDrawn)).replacingOccurrences(of: "\t", with: "    ")
        let text = NSMutableAttributedString(string: code, attributes: [
            .font: font, .foregroundColor: line.kind == .context ? CockpitStyle.code : CockpitStyle.text,
        ])
        if line.missingNewline {
            text.append(NSAttributedString(string: "  ⏎ sem quebra de linha no fim", attributes: [
                .font: CockpitStyle.caption, .foregroundColor: CockpitStyle.muted,
            ]))
        }
        text.draw(at: NSPoint(x: geometry.textX, y: top))
    }
}

/// A row's ground: the wash of an added or removed line, and the selection
/// drawn as a lit band with an amber edge rather than the system's blue.
final class DiffRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("diff.row")

    var wash: NSColor = CockpitStyle.panel {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        wash.setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        wash.setFill()
        bounds.fill()
        NSColor.white.withAlphaComponent(0.06).setFill()
        bounds.fill()
        CockpitStyle.accent.setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
}
