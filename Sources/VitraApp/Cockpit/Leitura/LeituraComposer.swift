import AppKit
import VitraCore

/// Talking to the maestro without leaving Leitura: a rounded field that grows
/// to eight lines. ⏎ sends, ⇧⏎ breaks the line, ⎋ hands the keyboard back to
/// the list. Images and files pasted show as previews and go as paths, as a
/// paste into the terminal does, since the maestro reads files by path.
///
/// While the maestro works the button says the message will wait in Claude
/// Code's own queue — which is what typing into its prompt does — and offers
/// Vitra's Fila instead.
@MainActor
final class LeituraComposer: NSView, NSTextViewDelegate {
    var onSend: ((String) -> Void)?
    var onQueue: ((String) -> Void)?
    var onEscape: (() -> Void)?
    var onHeightChange: (() -> Void)?
    /// A pasted image or file was clicked: its path, to open in the preview.
    var onOpenAttachment: ((String) -> Void)?

    static let verticalPad: CGFloat = 12
    static let fieldPad: CGFloat = 10
    static let maxLines = 8
    static let attachment: CGFloat = 56
    static let attachmentGap: CGFloat = 8

    private let field = NSView.filled(CockpitStyle.raised, cornerRadius: 12)
    private let scroll = NSScrollView()
    let text = ComposerTextView()
    private let placeholder = NSTextField.label("Mensagem para o maestro…", font: ReadingStyle.body, color: ReadingStyle.faint)
    private let send = NSButton()
    private let queue = NSButton()
    private let status = NSTextField.label(font: CockpitStyle.caption, color: CockpitStyle.dangerText)
    private(set) var isWorking = false
    /// What was pasted and is still named in the text, with its preview.
    private var attachments: [(path: String, view: ThumbnailView)] = []
    private var attachmentsHeight: CGFloat { attachments.isEmpty ? 0 : Self.attachment + Self.attachmentGap }
    /// Passages of the conversation this message answers.
    private var quotes: [QuoteChip] = []
    private var quotesHeight: CGFloat { CGFloat(quotes.count) * (QuoteChip.height + Self.attachmentGap) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ReadingStyle.page.cgColor
        field.translatesAutoresizingMaskIntoConstraints = true
        field.layer?.borderWidth = 1
        field.layer?.borderColor = CockpitStyle.controlLine.cgColor
        text.delegate = self
        text.onAttach = { [weak self] paths in self?.attach(paths) }
        text.font = ReadingStyle.body
        text.textColor = ReadingStyle.text
        text.insertionPointColor = CockpitStyle.accent
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.setAccessibilityLabel("Mensagem para o maestro")
        applyTypingLook()
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        configure(send, action: #selector(sendTapped))
        configure(queue, action: #selector(queueTapped))
        queue.toolTip = "Guardar na Fila do Vitra: vai quando o maestro terminar o turno"
        for view in [field, scroll, placeholder, send, queue, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        text.textContainer?.widthTracksTextView = true
        setWorking(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// A click anywhere on the field is a click on the text: the placeholder
    /// lies over it and the field around it, and neither takes the keyboard —
    /// which would stay with the terminal underneath, typing into it unseen.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === placeholder || hit === field || hit === self ? text : hit
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.target = self
        button.action = action
    }

    /// The labels follow whether the maestro is mid-turn.
    func setWorking(_ working: Bool) {
        isWorking = working
        let title = working ? "Enviar (entra na fila do Claude)" : "Enviar"
        send.attributedTitle = NSAttributedString(string: title + "  ⏎", attributes: [.font: ReadingStyle.smallMedium, .foregroundColor: CockpitStyle.bar])
        send.layer?.backgroundColor = CockpitStyle.accent.cgColor
        send.toolTip = working
            ? "O Claude Code guarda a mensagem e a lê assim que puder"
            : "Envia ao maestro, como se fosse digitada no terminal"
        queue.attributedTitle = NSAttributedString(string: "pôr na Fila", attributes: [.font: CockpitStyle.caption, .foregroundColor: ReadingStyle.quiet])
        queue.isHidden = !working
        needsLayout = true
    }

    /// A line under the field when a message could not go.
    func showProblem(_ message: String?) {
        status.stringValue = message ?? ""
        status.isHidden = message == nil
        onHeightChange?()
    }

    var message: String {
        get { text.string }
        set {
            text.string = newValue
            textDidChange(Notification(name: NSText.didChangeNotification))
        }
    }

    // MARK: - Pasted images and files

    private func attach(_ paths: [String]) {
        for path in paths where !attachments.contains(where: { $0.path == path }) {
            let view = ThumbnailView(image: ImageRef(path: path))
            view.onClick = { [weak self] in self?.onOpenAttachment?(path) }
            view.onRemove = { [weak self] in self?.removeAttachment(path) }
            view.toolTip = "Clique para ampliar"
            addSubview(view)
            attachments.append((path, view))
        }
        attachmentsChanged()
    }

    private func removeAttachment(_ path: String) {
        attachments.removeAll { attachment in
            guard attachment.path == path else { return false }
            attachment.view.removeFromSuperview()
            return true
        }
        attachmentsChanged()
    }

    /// The passage a reply is about, shown over the text; the same passage
    /// is not quoted twice.
    func addQuote(_ passage: String) {
        let passage = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !passage.isEmpty, !quotes.contains(where: { $0.passage == passage }) else { return }
        let chip = QuoteChip(passage: passage)
        chip.onRemove = { [weak self, weak chip] in
            guard let self, let chip else { return }
            chip.removeFromSuperview()
            self.quotes.removeAll { $0 === chip }
            self.attachmentsChanged()
        }
        addSubview(chip)
        quotes.append(chip)
        attachmentsChanged()
    }

    /// ⌫ at the very start of the text takes away what sits over it, last
    /// first: a preview, then a quote.
    private func removeLastExtra() {
        if let attachment = attachments.popLast() {
            attachment.view.removeFromSuperview()
        } else {
            quotes.popLast()?.removeFromSuperview()
        }
        attachmentsChanged()
    }

    private func attachmentsChanged() {
        needsLayout = true
        onHeightChange?()
    }

    /// What goes to the maestro: the pasted files' paths, which it reads as
    /// a paste into its prompt does, then the words.
    private var outgoing: String {
        let paths = ShellQuoting.join(attachments.map(\.path))
        let words = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = [paths, words].filter { !$0.isEmpty }.joined(separator: " ")
        // A quote alone says nothing: it goes with the words about it.
        guard !said.isEmpty else { return "" }
        return (quotes.map { LeituraView.quoted($0.passage) } + [said]).joined(separator: "\n\n")
    }

    // MARK: - Size

    private var lineHeight: CGFloat { ceil(ReadingStyle.body.ascender - ReadingStyle.body.descender + ReadingStyle.body.leading) + 1 }

    private func textHeight(width: CGFloat) -> CGFloat {
        let measured = text.layoutManager.flatMap { layout -> CGFloat? in
            guard let container = text.textContainer else { return nil }
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            return layout.usedRect(for: container).height
        } ?? lineHeight
        return min(max(measured, lineHeight), lineHeight * CGFloat(Self.maxLines))
    }

    /// The composer's height at `width`: one line to eight, the buttons'
    /// row, and the problem line when there is one.
    func preferredHeight(width: CGFloat) -> CGFloat {
        let column = ReadingStyle.column(in: width).width
        let problem: CGFloat = status.isHidden ? 0 : 18
        return Self.verticalPad + Self.fieldPad + quotesHeight + attachmentsHeight + textHeight(width: column - 2 * Self.fieldPad) + 8 + 26 + Self.fieldPad + problem + Self.verticalPad
    }

    override func layout() {
        super.layout()
        let column = ReadingStyle.column(in: bounds.width)
        let inner = column.width - 2 * Self.fieldPad
        let textHeight = textHeight(width: inner)
        let problem: CGFloat = status.isHidden ? 0 : 18
        let fieldHeight = bounds.height - 2 * Self.verticalPad - problem
        field.frame = NSRect(x: column.x, y: Self.verticalPad, width: column.width, height: fieldHeight)
        var quoteY = Self.verticalPad + Self.fieldPad
        for chip in quotes {
            chip.frame = NSRect(x: column.x + Self.fieldPad, y: quoteY, width: inner, height: QuoteChip.height)
            quoteY += QuoteChip.height + Self.attachmentGap
        }
        var thumbX = column.x + Self.fieldPad
        for attachment in attachments {
            let width = Self.attachment * ThumbnailView.aspect
            attachment.view.frame = NSRect(x: thumbX, y: quoteY, width: width, height: Self.attachment)
            attachment.view.isHidden = thumbX + width > field.frame.maxX - Self.fieldPad
            thumbX += width + Self.attachmentGap
        }
        scroll.frame = NSRect(x: column.x + Self.fieldPad, y: quoteY + attachmentsHeight, width: inner, height: textHeight)
        text.frame.size.width = inner
        placeholder.frame = NSRect(x: scroll.frame.minX, y: scroll.frame.minY - 1, width: inner, height: lineHeight)
        placeholder.isHidden = !text.string.isEmpty
        send.sizeToFit()
        let sendWidth = send.frame.width + 20
        let buttonsY = field.frame.maxY - Self.fieldPad - 26
        send.frame = NSRect(x: field.frame.maxX - Self.fieldPad - sendWidth, y: buttonsY, width: sendWidth, height: 26)
        queue.sizeToFit()
        queue.frame = NSRect(x: send.frame.minX - queue.frame.width - 16, y: buttonsY, width: queue.frame.width + 8, height: 26)
        status.frame = NSRect(x: column.x + 4, y: field.frame.maxY + 3, width: column.width, height: 15)
        let isEmpty = outgoing.isEmpty
        send.alphaValue = isEmpty ? 0.45 : 1
        queue.alphaValue = isEmpty ? 0.45 : 1
    }

    // MARK: - Keys

    /// What is typed next looks like the rest. An empty text view forgets its
    /// colour and types in black — invisible on this page — so it is told
    /// again each time it empties.
    private func applyTypingLook() {
        text.typingAttributes = [.font: ReadingStyle.body, .foregroundColor: ReadingStyle.text]
    }

    func textDidChange(_ notification: Notification) {
        if text.string.isEmpty { applyTypingLook() }
        if !status.isHidden { showProblem(nil) }
        placeholder.isHidden = !text.string.isEmpty
        needsLayout = true
        onHeightChange?()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                sendTapped()
            }
            return true
        case #selector(NSResponder.deleteBackward(_:)) where textView.selectedRange() == NSRange(location: 0, length: 0) && !(attachments.isEmpty && quotes.isEmpty):
            removeLastExtra()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
            return true
        default:
            return false
        }
    }

    @objc private func sendTapped() {
        let message = outgoing
        guard !message.isEmpty else { return }
        onSend?(message)
    }

    @objc private func queueTapped() {
        let message = outgoing
        guard !message.isEmpty else { return }
        onQueue?(message)
    }

    /// The field emptied once its message went.
    func clear() {
        attachments.forEach { $0.view.removeFromSuperview() }
        attachments = []
        quotes.forEach { $0.removeFromSuperview() }
        quotes = []
        message = ""
    }
}

/// The composer's text: a paste of images or files becomes previews over
/// the text (`PasteboardAttachments` saves them); anything else pastes as
/// plain text.
final class ComposerTextView: NSTextView {
    /// The paths a paste just put in the text.
    var onAttach: (([String]) -> Void)?

    override func paste(_ sender: Any?) {
        let found = PasteboardAttachments.read(from: .general, store: AttachmentStore())
        guard !found.isEmpty else {
            pasteAsPlainText(sender)
            return
        }
        // A preview over the text, not a path in it: the path goes with the
        // message when it is sent.
        onAttach?(found.map(\.path))
    }
}

/// A quoted passage over the composer's text: a bar, two lines of it at
/// most, and a cross to drop it.
final class QuoteChip: NSView {
    static let height: CGFloat = 40
    let passage: String
    var onRemove: (() -> Void)?

    private let bar = NSView.filled(CockpitStyle.accent.withAlphaComponent(0.7), cornerRadius: 1.25)
    private let label = NSTextField.label(font: CockpitStyle.ui(12.5), color: ReadingStyle.quiet)
    private let close = NSButton()

    init(passage: String) {
        self.passage = passage
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = ReadingStyle.page.cgColor
        layer?.cornerRadius = 7
        label.stringValue = passage.split(whereSeparator: \.isNewline).joined(separator: " ")
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = true
        label.toolTip = passage
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "remover citação")
        close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        close.contentTintColor = ReadingStyle.quiet
        close.toolTip = "Remover citação"
        close.target = self
        close.action = #selector(removeTapped)
        for view in [bar, label, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 8, y: 6, width: 2.5, height: bounds.height - 12)
        close.frame = NSRect(x: bounds.width - 26, y: (bounds.height - 20) / 2, width: 20, height: 20)
        label.frame = NSRect(x: 18, y: 4, width: max(bounds.width - 18 - 32, 0), height: bounds.height - 8)
    }

    @objc private func removeTapped() { onRemove?() }
}
