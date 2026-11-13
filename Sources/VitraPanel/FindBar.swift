import AppKit

/// The find strip: a field, a match counter or match/none dot, previous, next
/// and close.
///
/// Slid in on Cmd-F over the top of what it searches rather than pushing it
/// down, so finding something does not reflow the text under the words being
/// read. Enter finds forward, Shift-Enter back, Esc closes. It knows nothing of
/// what it searches: the browser's page and the maestro's conversation each
/// answer its callbacks their own way.
public final class FindBar: NSView, NSTextFieldDelegate {
    /// The query changed as it was typed; for a search that follows the keys.
    public var onChange: ((String) -> Void)?
    /// Enter, Shift-Enter or an arrow: step to the next match, or back.
    public var onStep: ((_ query: String, _ forward: Bool) -> Void)?
    /// The bar was put away. `cancelled` is Esc, as opposed to the button.
    public var onClose: ((_ cancelled: Bool) -> Void)?

    private let field = NSTextField()
    private let status = NSView()
    private let counter = NSTextField(labelWithString: "")

    public var query: String { field.stringValue }

    public init(placeholder: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.raised.cgColor
        layer?.borderColor = Theme.raisedLine.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = Theme.Radius.control
        // Over a terminal or a page: lifted off it, so it reads as a tool laid
        // on top and not as part of the text.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        translatesAutoresizingMaskIntoConstraints = false

        field.font = Theme.meta
        field.textColor = Theme.text
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.delegate = self
        field.cell?.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        status.wantsLayer = true
        status.layer?.cornerRadius = Theme.Radius.dot
        status.layer?.backgroundColor = NSColor.clear.cgColor
        status.translatesAutoresizingMaskIntoConstraints = false

        counter.font = Theme.meta
        counter.textColor = Theme.muted
        counter.alignment = .right
        counter.isHidden = true
        counter.setContentCompressionResistancePriority(.required, for: .horizontal)
        counter.setContentHuggingPriority(.required, for: .horizontal)

        let previous = button("chevron.up", #selector(findPrevious), tip: "Anterior (⇧⏎)")
        let next = button("chevron.down", #selector(findNextPressed), tip: "Próxima (⏎)")
        let close = button("xmark", #selector(closePressed), tip: "Fechar (⎋)")

        let row = NSStackView(views: [field, status, counter, previous, next, close])
        row.orientation = .horizontal
        row.spacing = Theme.Space.sm
        row.setCustomSpacing(Theme.Space.md, after: counter)
        row.edgeInsets = NSEdgeInsets(top: 0, left: Theme.Space.lg, bottom: 0, right: Theme.Space.md)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            // At most 180, and less where the panel is narrow: the bar must
            // fit the panel's 260 pt minimum with its buttons and margins.
            field.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            status.widthAnchor.constraint(equalToConstant: 2 * Theme.Radius.dot),
            status.heightAnchor.constraint(equalToConstant: 2 * Theme.Radius.dot),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Shows the bar in the top-right of `parent`, `top` points down, and
    /// takes the keyboard.
    public func reveal(in parent: NSView, top: CGFloat) {
        if superview == nil {
            parent.addSubview(self)
            NSLayoutConstraint.activate([
                topAnchor.constraint(equalTo: parent.topAnchor, constant: top),
                trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Theme.Space.lg),
                // Never wider than the view it sits in.
                leadingAnchor.constraint(greaterThanOrEqualTo: parent.leadingAnchor, constant: Theme.Space.lg),
                heightAnchor.constraint(equalToConstant: Theme.rowHeight),
            ])
        }
        isHidden = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Green when the last find matched, red when it did not, nothing when the
    /// field is empty. For a search that cannot count its matches.
    public func report(found: Bool) {
        let colour: NSColor = field.stringValue.isEmpty
            ? .clear
            : (found ? .systemGreen : .systemRed)
        status.layer?.backgroundColor = colour.withAlphaComponent(0.9).cgColor
    }

    /// "3 de 17" in place of the dot, or nothing.
    public func report(count text: String?, isEmpty: Bool = false) {
        status.isHidden = true
        counter.isHidden = text == nil
        counter.stringValue = text ?? ""
        counter.textColor = isEmpty ? Theme.dangerText : Theme.muted
    }

    /// Puts the text in the field without running a search, as a snapshot does.
    public func setQuery(_ query: String) { field.stringValue = query }

    // MARK: - Actions

    public func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    /// Enter, Shift-Enter and Esc, read from the field editor: Esc in a text
    /// field would otherwise ask for completions.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            onStep?(field.stringValue, !backwards)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(cancelled: true)
            return true
        default:
            return false
        }
    }

    @objc private func findNextPressed() { onStep?(field.stringValue, true) }
    @objc private func findPrevious() { onStep?(field.stringValue, false) }
    @objc private func closePressed() { close(cancelled: false) }

    public override func cancelOperation(_ sender: Any?) { close(cancelled: true) }

    public func close(cancelled: Bool) {
        guard !isHidden else { return }
        isHidden = true
        onClose?(cancelled)
    }

    private func button(_ symbol: String, _ action: Selector, tip: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.contentTintColor = Theme.muted
        button.isBordered = false
        button.toolTip = tip
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}
