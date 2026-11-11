import AppKit

/// Where a comment's plate sits under its line: aligned with the code it is
/// about, and never wider than a comfortable line of prose.
enum CommentPlate {
    static let widest: CGFloat = 560
    static let padding = CockpitStyle.Space.md
    /// Room above and below the plate inside its row.
    static let margin = CockpitStyle.Space.xs
    static let editorHeight: CGFloat = 36
    static var font: NSFont { CockpitStyle.body }

    static func width(visible: CGFloat, geometry: DiffGeometry) -> CGFloat {
        max(200, min(widest, visible - geometry.textX - CockpitStyle.inset))
    }

    /// The row height for a saved comment's text in a plate this wide.
    static func height(of text: String, width: CGFloat) -> CGFloat {
        let room = width - 2 * padding - CockpitStyle.iconSize - CockpitStyle.Space.md
        let box = (text as NSString).boundingRect(
            with: NSSize(width: room, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(box.height) + 2 * padding + 2 * margin
    }

    static func plate() -> NSView {
        let plate = NSView.filled(CockpitStyle.raised, cornerRadius: CockpitStyle.Radius.control)
        plate.layer?.borderWidth = 1
        plate.layer?.borderColor = CockpitStyle.raisedLine.cgColor
        return plate
    }
}

/// A saved comment under its line: its text, which reopens it for editing
/// when clicked, and an × that removes it.
final class DiffNoteCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("diff.note")

    var onEdit: (() -> Void)?
    var onRemove: (() -> Void)?

    private let plate = CommentPlate.plate()
    private let text = NSTextField.wrapping("", font: CommentPlate.font, color: CockpitStyle.text)
    private let remove = NSButton()
    private var leading: NSLayoutConstraint?
    private var width: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remover comentário")
        remove.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        remove.contentTintColor = CockpitStyle.muted
        remove.isBordered = false
        remove.bezelStyle = .inline
        remove.target = self
        remove.action = #selector(removeClicked)
        remove.toolTip = "Remover comentário"
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plate)
        plate.addSubview(text)
        plate.addSubview(remove)
        plate.toolTip = "Clique para editar"
        let leading = plate.leadingAnchor.constraint(equalTo: leadingAnchor)
        let width = plate.widthAnchor.constraint(equalToConstant: CommentPlate.widest)
        (self.leading, self.width) = (leading, width)
        let pad = CommentPlate.padding
        NSLayoutConstraint.activate([
            leading, width,
            plate.topAnchor.constraint(equalTo: topAnchor, constant: CommentPlate.margin),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CommentPlate.margin),
            text.topAnchor.constraint(equalTo: plate.topAnchor, constant: pad),
            text.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: pad),
            text.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -CockpitStyle.Space.md),
            remove.topAnchor.constraint(equalTo: plate.topAnchor, constant: pad),
            remove.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -pad),
            remove.widthAnchor.constraint(equalToConstant: CockpitStyle.iconSize),
            remove.heightAnchor.constraint(equalToConstant: CockpitStyle.iconSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ comment: ReviewComment, at x: CGFloat, width: CGFloat) {
        text.stringValue = comment.text
        text.preferredMaxLayoutWidth = width - 2 * CommentPlate.padding - CockpitStyle.iconSize - CockpitStyle.Space.md
        leading?.constant = x
        self.width?.constant = width
        setAccessibilityLabel("Comentário: \(comment.text)")
    }

    // A click anywhere on the note but the × opens it for editing; the
    // table under it is not told, so the selection stays where it was.
    override func mouseDown(with event: NSEvent) {
        let point = plate.convert(event.locationInWindow, from: nil)
        if plate.bounds.contains(point) { onEdit?() } else { super.mouseDown(with: event) }
    }

    @objc private func removeClicked() { onRemove?() }
}

/// The field a comment is written in, under its line. ⏎ keeps it, ⎋ drops it.
final class DiffEditorCell: NSView, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("diff.editor")
    static let height = CommentPlate.editorHeight + 2 * CommentPlate.margin

    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?

    let field = NSTextField()
    private let plate = CommentPlate.plate()
    private let hint = NSTextField.label("⏎ salva · esc cancela", font: CockpitStyle.caption, color: CockpitStyle.muted)
    private var leading: NSLayoutConstraint?
    private var width: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        plate.layer?.borderColor = CockpitStyle.accent.withAlphaComponent(0.6).cgColor
        field.font = CommentPlate.font
        field.textColor = CockpitStyle.text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderAttributedString = NSAttributedString(string: "Comente esta linha…", attributes: [
            .font: CommentPlate.font, .foregroundColor: CockpitStyle.muted,
        ])
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(plate)
        plate.addSubview(field)
        plate.addSubview(hint)
        let leading = plate.leadingAnchor.constraint(equalTo: leadingAnchor)
        let width = plate.widthAnchor.constraint(equalToConstant: CommentPlate.widest)
        (self.leading, self.width) = (leading, width)
        let pad = CommentPlate.padding
        NSLayoutConstraint.activate([
            leading, width,
            plate.topAnchor.constraint(equalTo: topAnchor, constant: CommentPlate.margin),
            plate.heightAnchor.constraint(equalToConstant: CommentPlate.editorHeight),
            field.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: pad),
            field.trailingAnchor.constraint(equalTo: hint.leadingAnchor, constant: -CockpitStyle.Space.md),
            hint.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -pad),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(text: String, at x: CGFloat, width: CGFloat) {
        field.stringValue = text
        leading?.constant = x
        self.width?.constant = width
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSave?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}
