import AppKit

/// The find-in-page strip: a field, a match/none dot, next and previous.
///
/// Slid in on Cmd-F over the top of the web view rather than pushing it down,
/// so finding something does not reflow the page under the words being read.
/// Enter finds forward, Shift-Enter back, Esc closes.
final class FindBar: NSView {
    private unowned let browser: BrowserView
    private let field = NSTextField()
    private let status = NSView()

    init(browser: BrowserView) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PanelStyle.surface.cgColor
        layer?.borderColor = PanelStyle.hairline.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false

        field.font = PanelStyle.monospaced(11)
        field.textColor = PanelStyle.primaryText
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "find in page"
        field.target = self
        field.action = #selector(findNext)
        field.translatesAutoresizingMaskIntoConstraints = false

        status.wantsLayer = true
        status.layer?.cornerRadius = 3
        status.layer?.backgroundColor = NSColor.clear.cgColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let next = button("chevron.down", #selector(findNext))
        let previous = button("chevron.up", #selector(findPrevious))
        let close = button("xmark", #selector(closeBar))

        let row = NSStackView(views: [field, status, previous, next, close])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(equalToConstant: 180),
            status.widthAnchor.constraint(equalToConstant: 6),
            status.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Shows the bar in the top-right of the browser, and takes the keyboard.
    func reveal(in parent: BrowserView) {
        if superview == nil {
            parent.addSubview(self)
            NSLayoutConstraint.activate([
                topAnchor.constraint(equalTo: parent.topAnchor, constant: 40),
                trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -12),
                heightAnchor.constraint(equalToConstant: 30),
            ])
        }
        isHidden = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        if !field.stringValue.isEmpty { browser.find(field.stringValue, forward: true) }
    }

    /// Green when the last find matched, red when it did not, nothing when the
    /// field is empty.
    func report(found: Bool) {
        let colour: NSColor = field.stringValue.isEmpty
            ? .clear
            : (found ? .systemGreen : .systemRed)
        status.layer?.backgroundColor = colour.withAlphaComponent(0.9).cgColor
    }

    @objc private func findNext() {
        // Shift held turns Enter into a step backwards, the browser convention.
        let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        browser.find(field.stringValue, forward: !backwards)
    }

    @objc private func findPrevious() { browser.find(field.stringValue, forward: false) }

    @objc private func closeBar() {
        isHidden = true
        window?.makeFirstResponder(browser)
    }

    override func cancelOperation(_ sender: Any?) { closeBar() }

    private func button(_ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = PanelStyle.secondaryText
        button.isBordered = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}
