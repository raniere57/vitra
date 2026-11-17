import AppKit
import VitraCore

/// Text and source files, monospaced and lightly coloured. A whole UTF-8
/// file can be edited in place: ⌘S saves, and so does leaving it.
final class TextPreviewView: NSScrollView, PreviewContentView, NSTextViewDelegate {
    /// Reading stops here. A preview panel is for looking at a file, and a
    /// hundred-megabyte log would only be a way to run out of memory.
    private static let byteLimit = 2 * 1024 * 1024

    private let textView = NSTextView()
    private let url: URL
    private var dirty = false

    init?(target: PreviewTarget) {
        url = target.url
        super.init(frame: .zero)

        guard let handle = try? FileHandle(forReadingFrom: target.url),
              let data = try? handle.read(upToCount: Self.byteLimit)
        else { return nil }
        try? handle.close()

        // Latin-1 never fails, so a file with a stray invalid byte still shows
        // instead of refusing to open.
        let utf8 = String(data: data, encoding: .utf8)
        let contents = utf8 ?? String(data: data, encoding: .isoLatin1) ?? ""
        // Saving writes UTF-8 back, so only a file read whole and as UTF-8
        // can be edited without changing what was not touched.
        let editable = utf8 != nil && data.count < Self.byteLimit

        let body = NSMutableAttributedString(string: contents, attributes: [
            .font: Theme.source,
            .foregroundColor: PanelStyle.primaryText,
        ])
        SyntaxHighlighter.highlight(body)
        if data.count == Self.byteLimit {
            body.append(NSAttributedString(string: "\n\n… truncated at 2 MB\n", attributes: [
                .font: Theme.sourceHeading,
                .foregroundColor: PanelStyle.secondaryText,
            ]))
        }

        textView.isEditable = editable
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.typingAttributes = [.font: Theme.source, .foregroundColor: PanelStyle.primaryText]
        textView.delegate = self
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = PanelStyle.surface
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textStorage?.setAttributedString(body)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        // The system's own find bar, which costs nothing: Cmd-F below opens it.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        documentView = textView
        hasVerticalScroller = true
        drawsBackground = true
        backgroundColor = PanelStyle.surface
        scrollerStyle = .overlay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func textDidChange(_ notification: Notification) { dirty = true }

    /// Writes the text back when it changed; colours it again.
    @discardableResult
    func save() -> Bool {
        guard dirty, let storage = textView.textStorage else { return true }
        do {
            try storage.string.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
            return false
        }
        dirty = false
        let selection = textView.selectedRanges
        storage.setAttributes([.font: Theme.source, .foregroundColor: PanelStyle.primaryText], range: NSRange(location: 0, length: storage.length))
        SyntaxHighlighter.highlight(storage)
        textView.selectedRanges = selection
        return true
    }

    /// Another file, or the panel closing, keeps what was typed.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { save() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Cmd-F opens the find bar. The panel is not what the menu drives, so the
    /// key is read here and handed to the text view's own find machinery.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only while the keyboard is here: ⌘F in the maestro's terminal is
        // a search of the conversation, not of this file.
        guard event.modifierFlags.contains(.command),
              (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        else { return super.performKeyEquivalent(with: event) }
        if event.charactersIgnoringModifiers == "s" { save(); return true }
        guard event.charactersIgnoringModifiers == "f" else { return super.performKeyEquivalent(with: event) }
        let show = NSMenuItem()
        show.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        textView.performFindPanelAction(show)
        return true
    }
}
