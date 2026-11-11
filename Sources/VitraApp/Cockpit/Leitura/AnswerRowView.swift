import AppKit

/// The maestro's words: plain on the page, no bubble, Markdown drawn as
/// typography. Prose is one text view per run between code blocks, so a
/// selection runs across paragraphs, lists and tables; code blocks sit
/// between them. Hovering shows "copiar resposta", which copies the
/// Markdown as it was written.
final class AnswerRowView: LeituraRowView {
    static let top: CGFloat = 12
    static let bottom: CGFloat = 10
    static let segmentGap: CGFloat = 14

    private var texts: [ReadingTextView] = []
    private var codes: [CodeBlockView] = []
    private var order: [NSView] = []
    private let copy = NSButton()
    private var markdown = ""
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        copy.isBordered = false
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "copiar resposta")
        copy.imagePosition = .imageLeading
        copy.contentTintColor = ReadingStyle.quiet
        setCopyTitle("copiar resposta", color: ReadingStyle.quiet)
        copy.target = self
        copy.action = #selector(copyAnswer)
        copy.isHidden = true
        copy.wantsLayer = true
        copy.layer?.backgroundColor = ReadingStyle.page.cgColor
        copy.layer?.cornerRadius = CockpitStyle.Radius.control
        addSubview(copy)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func height(_ answer: Answer, width: CGFloat, context: LeituraContext) -> CGFloat {
        let column = ReadingStyle.column(in: width).width
        let segments = context.segments(for: answer)
        let body = segments.reduce(CGFloat(0)) { total, segment in
            total + height(of: segment, width: column)
        }
        return top + body + CGFloat(max(segments.count - 1, 0)) * segmentGap + bottom
    }

    private static func height(of segment: LeituraContext.Segment, width: CGFloat) -> CGFloat {
        switch segment {
        case let .text(text, _): ReadingTextView.height(of: text, width: width)
        case let .code(language, code): CodeBlockView.height(language: language, code: code)
        }
    }

    override func configure(_ row: LeituraRow, context: LeituraContext) {
        super.configure(row, context: context)
        guard case let .item(.answer(answer)) = row else { return }
        markdown = answer.markdown
        let segments = context.segments(for: answer)
        // Reuse the views this row already has, in kind order.
        var textPool = texts[...], codePool = codes[...]
        var usedTexts: [ReadingTextView] = [], usedCodes: [CodeBlockView] = []
        order = segments.map { segment -> NSView in
            switch segment {
            case let .text(text, _):
                let view = textPool.popFirst() ?? ReadingTextView()
                view.show(text)
                view.onOpenLink = { [weak context] in context?.openLink?($0) }
                usedTexts.append(view)
                return view
            case let .code(language, code):
                let view = codePool.popFirst() ?? CodeBlockView()
                view.show(language: language, code: code)
                usedCodes.append(view)
                return view
            }
        }
        (textPool.map { $0 as NSView } + codePool.map { $0 as NSView }).forEach { $0.removeFromSuperview() }
        texts = usedTexts
        codes = usedCodes
        for view in order where view.superview !== self { addSubview(view, positioned: .below, relativeTo: copy) }
        refreshHighlights()
    }

    override func layout() {
        super.layout()
        guard case let .item(.answer(answer)) = row, let context else { return }
        let column = ReadingStyle.column(in: bounds.width)
        var y = Self.top
        for (view, segment) in zip(order, context.segments(for: answer)) {
            let height = Self.height(of: segment, width: column.width)
            view.frame = NSRect(x: column.x, y: y, width: column.width, height: height)
            y += height + Self.segmentGap
        }
        copy.sizeToFit()
        let width = copy.frame.width + 12
        copy.frame = NSRect(x: column.x + column.width - width, y: max(Self.top - 10, 0), width: width, height: 20)
    }

    override func refreshHighlights() {
        Self.highlight(searchViews, context: context, row: row?.id ?? "")
    }

    override func rectOfCurrentMatch() -> NSRect? {
        Self.currentMatchRect(searchViews, context: context, row: row?.id ?? "", in: self)
    }

    /// The text views in drawing order, code included, as search numbers them.
    private var searchViews: [ReadingTextView] {
        order.compactMap { ($0 as? ReadingTextView) ?? ($0 as? CodeBlockView)?.textView }
    }

    // MARK: - Hover and copy

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { copy.isHidden = false }
    override func mouseExited(with event: NSEvent) { copy.isHidden = true }

    /// For the snapshot: the row as it looks under the pointer.
    func showHover() { copy.isHidden = false }

    @objc private func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        setCopyTitle("copiada", color: CockpitStyle.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.setCopyTitle("copiar resposta", color: ReadingStyle.quiet)
        }
    }

    private func setCopyTitle(_ title: String, color: NSColor) {
        copy.attributedTitle = NSAttributedString(string: " " + title, attributes: [.font: CockpitStyle.caption, .foregroundColor: color])
    }
}
