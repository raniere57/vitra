import AppKit
import VitraCore

/// Text and source files, monospaced and lightly coloured.
final class TextPreviewView: NSScrollView, PreviewContentView {
    /// Reading stops here. A preview panel is for looking at a file, and a
    /// hundred-megabyte log would only be a way to run out of memory.
    private static let byteLimit = 2 * 1024 * 1024

    private let textView = NSTextView()

    init?(target: PreviewTarget) {
        super.init(frame: .zero)

        guard let handle = try? FileHandle(forReadingFrom: target.url),
              let data = try? handle.read(upToCount: Self.byteLimit)
        else { return nil }
        try? handle.close()

        // Latin-1 never fails, so a file with a stray invalid byte still shows
        // instead of refusing to open.
        let contents = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        let body = NSMutableAttributedString(string: contents, attributes: [
            .font: PanelStyle.monospaced(11.5),
            .foregroundColor: PanelStyle.primaryText,
        ])
        SyntaxHighlighter.highlight(body)
        if data.count == Self.byteLimit {
            body.append(NSAttributedString(string: "\n\n… truncated at 2 MB\n", attributes: [
                .font: PanelStyle.monospaced(11.5, weight: .semibold),
                .foregroundColor: PanelStyle.secondaryText,
            ]))
        }

        textView.isEditable = false
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

    /// Cmd-F opens the find bar. The panel is not what the menu drives, so the
    /// key is read here and handed to the text view's own find machinery.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers == "f"
        else { return super.performKeyEquivalent(with: event) }
        let show = NSMenuItem()
        show.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        textView.performFindPanelAction(show)
        return true
    }
}
