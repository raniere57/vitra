import AppKit

/// A read-only, selectable text view on TextKit 1 — the one that draws
/// `NSTextTable` — with inline code drawn as rounded chips and find matches
/// painted over the text.
@MainActor
final class ReadingTextView: NSTextView {
    /// A link was clicked: a page, or a file the answer named.
    var onOpenLink: ((URL) -> Void)?

    convenience init() {
        let storage = NSTextStorage()
        let layout = ChipLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        self.init(frame: NSRect(x: 0, y: 0, width: 100, height: 20), textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [
            .foregroundColor: ReadingStyle.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: ReadingStyle.link.withAlphaComponent(0.35),
            .cursor: NSCursor.pointingHand,
        ]
        selectedTextAttributes = [.backgroundColor: CockpitStyle.accent.withAlphaComponent(0.28)]
        focusRingType = .none
    }

    func show(_ text: NSAttributedString) {
        guard textStorage?.isEqual(to: text) != true else { return }
        textStorage?.setAttributedString(text)
    }

    /// Paints find matches; `current` stronger than the rest.
    func highlight(_ ranges: [NSRange], current: NSRange?) {
        guard let layout = layoutManager, let length = textStorage?.length else { return }
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        for range in ranges where NSMaxRange(range) <= length {
            let color = range == current ? CockpitStyle.accent.withAlphaComponent(0.55) : CockpitStyle.accent.withAlphaComponent(0.22)
            layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        }
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL { onOpenLink?(url) } else if let text = link as? String, let url = URL(string: text) { onOpenLink?(url) }
    }

    // MARK: - Replying to a passage

    private var reply: NSButton?

    /// A selection made, "Responder" appears by it: the passage goes quoted
    /// into the composer. NSTextView tracks the drag inside `mouseDown`, so
    /// when it returns the selection is final.
    override func mouseDown(with event: NSEvent) {
        hideReply()
        super.mouseDown(with: event)
        showReply()
    }

    override func resignFirstResponder() -> Bool {
        hideReply()
        return super.resignFirstResponder()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if selectedRange().length > 0 {
            let item = NSMenuItem(title: "Responder a este trecho", action: #selector(replyToSelection), keyEquivalent: "")
            item.target = self
            menu?.insertItem(item, at: 0)
            menu?.insertItem(.separator(), at: 1)
        }
        return menu
    }

    private func hideReply() {
        reply?.removeFromSuperview()
        reply = nil
    }

    private func showReply() {
        let range = selectedRange()
        guard range.length > 0, let layout = layoutManager, let container = textContainer,
              !Self.selectedText(string, range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let button = NSButton(title: "", target: self, action: #selector(replyToSelection))
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: "↩ Responder", attributes: [.font: ReadingStyle.smallMedium, .foregroundColor: CockpitStyle.bar])
        button.wantsLayer = true
        button.layer?.backgroundColor = CockpitStyle.accent.cgColor
        button.layer?.cornerRadius = 7
        button.sizeToFit()
        let size = NSSize(width: button.frame.width + 16, height: 24)
        // Over the selection when there is room in the view, else under it.
        let above = rect.minY - size.height - 4
        let y = above >= 0 ? above : min(rect.maxY + 4, max(bounds.height - size.height, 0))
        let x = min(max(rect.minX, 0), max(bounds.width - size.width, 0))
        button.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        addSubview(button)
        reply = button
    }

    @objc private func replyToSelection() {
        let text = Self.selectedText(string, selectedRange())
        hideReply()
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        var ancestor = superview
        while let view = ancestor, !(view is LeituraView) { ancestor = view.superview }
        (ancestor as? LeituraView)?.quote(text)
    }

    private static func selectedText(_ string: String, _ range: NSRange) -> String {
        (string as NSString).substring(with: range)
    }

    /// Scrolling belongs to the list; a text view in a row never scrolls.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    // MARK: - Measuring

    private static let measuringStorage = NSTextStorage()
    private static let measuringContainer: NSTextContainer = {
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        measuringStorage.addLayoutManager(layout)
        return container
    }()

    /// The height `text` takes laid out `width` wide, exactly as a
    /// `ReadingTextView` of that width draws it.
    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let container = measuringContainer
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        measuringStorage.setAttributedString(text)
        guard let layout = container.layoutManager else { return 0 }
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }
}

/// Draws a background colour as a rounded chip a little inside its line,
/// instead of the flat full-height band AppKit draws: inline code reads as a
/// token, not as a highlighter stroke.
final class ChipLayoutManager: NSLayoutManager {
    /// A quiet bar down the left of each block quote. (A text block's own
    /// border would do, but TextKit 1 does not draw it reliably.)
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.quoteBar, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: glyphs, in: container)
            CockpitStyle.muted.withAlphaComponent(0.4).setFill()
            NSBezierPath(roundedRect: NSRect(x: origin.x, y: origin.y + rect.minY, width: 2.5, height: rect.height), xRadius: 1.25, yRadius: 1.25).fill()
        }
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        // Find highlights and selection keep their plain shape.
        guard color == ReadingStyle.chip else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        color.setFill()
        for index in 0 ..< rectCount {
            let rect = rectArray[index].insetBy(dx: -2.5, dy: 1.5)
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
    }
}
