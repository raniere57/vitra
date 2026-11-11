import AppKit
import VitraCore

/// Talking to the maestro without leaving Leitura: a rounded field that grows
/// to eight lines. ⏎ sends, ⇧⏎ breaks the line, ⎋ hands the keyboard back to
/// the list. Images and files pasted become paths, exactly as a paste into
/// the terminal does, since the maestro reads files by path.
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

    static let verticalPad: CGFloat = 12
    static let fieldPad: CGFloat = 10
    static let maxLines = 8

    private let field = NSView.filled(CockpitStyle.raised, cornerRadius: 12)
    private let scroll = NSScrollView()
    let text = ComposerTextView()
    private let placeholder = NSTextField.label("Mensagem para o maestro…", font: ReadingStyle.body, color: ReadingStyle.faint)
    private let send = NSButton()
    private let queue = NSButton()
    private let status = NSTextField.label(font: CockpitStyle.caption, color: CockpitStyle.dangerText)
    private(set) var isWorking = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ReadingStyle.page.cgColor
        field.translatesAutoresizingMaskIntoConstraints = true
        field.layer?.borderWidth = 1
        field.layer?.borderColor = CockpitStyle.controlLine.cgColor
        text.delegate = self
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
        return Self.verticalPad + Self.fieldPad + textHeight(width: column - 2 * Self.fieldPad) + 8 + 26 + Self.fieldPad + problem + Self.verticalPad
    }

    override func layout() {
        super.layout()
        let column = ReadingStyle.column(in: bounds.width)
        let inner = column.width - 2 * Self.fieldPad
        let textHeight = textHeight(width: inner)
        let problem: CGFloat = status.isHidden ? 0 : 18
        let fieldHeight = bounds.height - 2 * Self.verticalPad - problem
        field.frame = NSRect(x: column.x, y: Self.verticalPad, width: column.width, height: fieldHeight)
        scroll.frame = NSRect(x: column.x + Self.fieldPad, y: Self.verticalPad + Self.fieldPad, width: inner, height: textHeight)
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
        let isEmpty = text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.alphaValue = isEmpty ? 0.45 : 1
        queue.alphaValue = isEmpty ? 0.45 : 1
    }

    // MARK: - Keys

    func textDidChange(_ notification: Notification) {
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
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
            return true
        default:
            return false
        }
    }

    @objc private func sendTapped() {
        let message = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        onSend?(message)
    }

    @objc private func queueTapped() {
        let message = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        onQueue?(message)
    }

    /// The field emptied once its message went.
    func clear() { message = "" }
}

/// The composer's text: a paste of images or files becomes their paths, as
/// it does in the terminal (`PasteboardAttachments`); anything else pastes as
/// plain text.
final class ComposerTextView: NSTextView {
    override func paste(_ sender: Any?) {
        let found = PasteboardAttachments.read(from: .general, store: AttachmentStore())
        guard !found.isEmpty else {
            pasteAsPlainText(sender)
            return
        }
        insertText(ShellQuoting.join(found.map(\.path)) + " ", replacementRange: selectedRange())
    }
}
