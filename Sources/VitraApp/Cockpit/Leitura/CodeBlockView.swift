import AppKit

/// A fenced code block: monospaced on a rounded panel, scrolling sideways
/// rather than wrapping (code wrapped mid-line is code misread), with its
/// language named and a copy button that shows on hover.
@MainActor
final class CodeBlockView: NSView {
    static let padding: CGFloat = 12
    static let headerHeight: CGFloat = 26

    private let language = NSTextField.label(font: CockpitStyle.micro, color: ReadingStyle.faint)
    private let scroll = SidewaysScrollView()
    private let text = ReadingTextView()
    private let copy = NSButton()
    private var code = ""
    private var hasHeader = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ReadingStyle.codePanel.cgColor
        layer?.cornerRadius = CockpitStyle.Radius.card
        layer?.borderWidth = 1
        layer?.borderColor = ReadingStyle.codeLine.cgColor

        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none

        copy.title = "copiar"
        copy.isBordered = false
        copy.font = CockpitStyle.caption
        copy.contentTintColor = ReadingStyle.quiet
        copy.attributedTitle = NSAttributedString(string: "copiar", attributes: [.font: CockpitStyle.caption, .foregroundColor: ReadingStyle.quiet])
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "copiar")
        copy.imagePosition = .imageLeading
        copy.imageScaling = .scaleProportionallyDown
        copy.target = self
        copy.action = #selector(copyCode)
        copy.isHidden = true
        copy.toolTip = "Copiar o código"
        for view in [language, scroll, copy] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(language name: String?, code: String) {
        self.code = code
        hasHeader = name != nil
        language.stringValue = (name ?? "").uppercased()
        language.isHidden = name == nil
        text.show(Self.attributed(code))
        needsLayout = true
    }

    static func attributed(_ code: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.18
        return NSAttributedString(string: code.isEmpty ? " " : code, attributes: [
            .font: ReadingStyle.code, .foregroundColor: CockpitStyle.code, .paragraphStyle: style,
        ])
    }

    static func height(language: String?, code: String) -> CGFloat {
        let body = ReadingTextView.height(of: attributed(code), width: 100_000)
        return body + 2 * padding + (language == nil ? 0 : headerHeight - padding + 2)
    }

    override func layout() {
        super.layout()
        let top: CGFloat = hasHeader ? Self.headerHeight : Self.padding
        language.frame = NSRect(x: Self.padding, y: 8, width: bounds.width - 120, height: 14)
        copy.sizeToFit()
        copy.frame = NSRect(x: bounds.width - copy.frame.width - 10, y: 5, width: copy.frame.width, height: 18)
        scroll.frame = NSRect(x: Self.padding, y: top, width: bounds.width - 2 * Self.padding, height: bounds.height - top - Self.padding + 6)
        let natural = text.layoutManager.map { layout -> NSSize in
            layout.ensureLayout(for: text.textContainer!)
            return layout.usedRect(for: text.textContainer!).size
        } ?? .zero
        text.frame = NSRect(x: 0, y: 0, width: max(natural.width + 4, scroll.contentSize.width), height: scroll.bounds.height)
    }

    // MARK: - Hover and copy

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { copy.isHidden = false }
    override func mouseExited(with event: NSEvent) { copy.isHidden = true }

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copy.attributedTitle = NSAttributedString(string: "copiado", attributes: [.font: CockpitStyle.caption, .foregroundColor: CockpitStyle.success])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copy.attributedTitle = NSAttributedString(string: "copiar", attributes: [.font: CockpitStyle.caption, .foregroundColor: ReadingStyle.quiet])
        }
    }

    /// For find: the code's text view.
    var textView: ReadingTextView { text }
    /// For the snapshot: the copy button as it looks on hover.
    func showCopy() { copy.isHidden = false }
}

/// Scrolls only sideways; a mostly vertical swipe goes on to the list, so
/// a code block never traps the reading's scroll.
final class SidewaysScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
