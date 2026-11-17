import AppKit

/// A file's header, which stays at the top while its lines scroll under it:
/// what happened to the file, its path, and its count of lines.
final class DiffFileCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("diff.file")
    static let height = CockpitStyle.headerHeight

    private let status = NSTextField.label(font: CockpitStyle.micro, color: CockpitStyle.muted)
    private let path = NSTextField.label(font: CockpitStyle.mono(12, .semibold), color: CockpitStyle.text)
    private let counts = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        path.lineBreakMode = .byTruncatingHead
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The counts follow the path instead of sitting at the far edge: the
        // table is as wide as its longest line, often far wider than the view.
        let row = NSStackView(views: [path, counts, status, NSView()])
        row.spacing = CockpitStyle.Space.md
        row.edgeInsets = NSEdgeInsets(top: 0, left: CockpitStyle.inset, bottom: 0, right: CockpitStyle.inset)
        let top = NSView.rule(CockpitStyle.line)
        let bottom = NSView.rule(CockpitStyle.softLine)
        for view in [row, top, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ file: DiffFile) {
        path.stringValue = file.path
        let word: String? = switch file.status {
        case .added: "NOVO"
        case .deleted: "REMOVIDO"
        case let .renamed(from): "RENOMEADO DE \(from)"
        case .modified: nil
        }
        status.stringValue = [word, file.isBinary ? "BINÁRIO" : nil].compactMap { $0 }.joined(separator: " · ")
        status.isHidden = status.stringValue.isEmpty
        let text = NSMutableAttributedString(string: "+\(file.added)", attributes: [.foregroundColor: CockpitStyle.success, .font: CockpitStyle.meta])
        text.append(NSAttributedString(string: " −\(file.removed)", attributes: [.foregroundColor: CockpitStyle.dangerText, .font: CockpitStyle.meta]))
        counts.attributedStringValue = text
        counts.isHidden = file.isBinary
        setAccessibilityLabel(file.path)
    }
}

/// A quiet line of text across the table: a hunk's `@@` context, a note
/// that the diff was cut, or why a file has no lines to show.
final class DiffTextCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("diff.text")
    static let hunkHeight: CGFloat = 26
    static let noteHeight: CGFloat = 30

    private let label = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
    private let rule = NSView.rule(CockpitStyle.softLine)
    private var leading: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        for view in [label, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let leading = label.leadingAnchor.constraint(equalTo: leadingAnchor)
        self.leading = leading
        NSLayoutConstraint.activate([
            leading,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -CockpitStyle.inset),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// `ruled` draws the hairline over the row that separates two hunks.
    func show(_ text: String, at x: CGFloat, ruled: Bool, color: NSColor = CockpitStyle.muted) {
        label.stringValue = text
        label.textColor = color
        leading?.constant = x
        rule.isHidden = !ruled
    }
}
