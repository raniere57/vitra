import AppKit

/// A row of the reading list. Each kind lays itself out by hand with the very
/// numbers its `height` measures with, so the list's cached heights and the
/// drawn rows can never disagree. Rows are reused by the table.
@MainActor
class LeituraRowView: NSView {
    weak var context: LeituraContext?
    private(set) var row: LeituraRow?

    override var isFlipped: Bool { true }

    func configure(_ row: LeituraRow, context: LeituraContext) {
        self.row = row
        self.context = context
        needsLayout = true
        if bounds.width > 0 { layout() }
    }

    /// Rows lay out by hand, so a new size is laid out at once: a row the
    /// table makes in the middle of a layout pass gets no pass of its own.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { layout() }
    }

    /// Re-applies find highlights after the query or the current match moved.
    func refreshHighlights() {}

    /// The first text a match in this row would sit in, for scrolling to it.
    func rectOfCurrentMatch() -> NSRect? { nil }

    static func time(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM · HH:mm"
        return formatter.string(from: date)
    }

    /// Paints `query`'s matches over `views`, numbering them across the views
    /// in order so the current one is the find's current one.
    static func highlight(_ views: [ReadingTextView], context: LeituraContext?, row: String) {
        var counter = 0
        let current = context?.currentIndex(in: row)
        for view in views {
            let ranges = LeituraSearch.ranges(of: context?.query ?? "", in: view.string)
            let currentRange = current.flatMap { $0 >= counter && $0 < counter + ranges.count ? ranges[$0 - counter] : nil }
            view.highlight(ranges, current: currentRange)
            counter += ranges.count
        }
    }

    static func currentMatchRect(_ views: [ReadingTextView], context: LeituraContext?, row: String, in owner: NSView) -> NSRect? {
        guard let current = context?.currentIndex(in: row) else { return nil }
        var counter = 0
        for view in views {
            let ranges = LeituraSearch.ranges(of: context?.query ?? "", in: view.string)
            if current < counter + ranges.count, let layout = view.layoutManager, let container = view.textContainer {
                let glyphs = layout.glyphRange(forCharacterRange: ranges[current - counter], actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                return owner.convert(rect, from: view)
            }
            counter += ranges.count
        }
        return nil
    }
}

// MARK: - The user's message

/// What the user said: a warm tinted block, shrink-wrapped to the text,
/// with "você" and the time over it and pasted images as thumbnails.
final class UserRowView: LeituraRowView {
    static let top: CGFloat = 22
    static let bottom: CGFloat = 8
    static let padH: CGFloat = 14
    static let padV: CGFloat = 11
    static let header: CGFloat = 15
    static let headerGap: CGFloat = 5
    static let thumb: CGFloat = 88
    static let thumbGap: CGFloat = 10

    private let block = NSView.filled(ReadingStyle.mine, cornerRadius: 10)
    private let label = NSTextField.label(font: CockpitStyle.micro, color: CockpitStyle.accent)
    private let text = ReadingTextView()
    private var thumbs: [ThumbnailView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        block.translatesAutoresizingMaskIntoConstraints = true
        block.layer?.borderWidth = 1
        block.layer?.borderColor = ReadingStyle.mineEdge.cgColor
        label.translatesAutoresizingMaskIntoConstraints = true
        for view in [block, label, text] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The user's words as typed; lines behind ">" are a passage they
    /// answered, drawn quieter behind a bar like any quote.
    static func attributed(_ text: String) -> NSAttributedString {
        guard text.hasPrefix(">") || text.contains("\n>") else { return ReadingStyle.plain(text) }
        let result = NSMutableAttributedString()
        var plain: [Substring] = []
        var quote: [String] = []
        func flush() {
            if !plain.isEmpty {
                let body = plain.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !body.isEmpty { result.append(ReadingStyle.plain(body + "\n")) }
                plain = []
            }
            if !quote.isEmpty {
                let style = ReadingStyle.paragraphStyle(after: 8)
                style.firstLineHeadIndent = 12
                style.headIndent = 12
                result.append(NSAttributedString(string: quote.joined(separator: " ") + "\n", attributes: [
                    .font: CockpitStyle.ui(13), .foregroundColor: ReadingStyle.quiet, .paragraphStyle: style, .quoteBar: true,
                ]))
                quote = []
            }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(">") {
                if !plain.isEmpty { flush() }
                let words = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if !words.isEmpty { quote.append(words) }
            } else {
                if !quote.isEmpty { flush() }
                plain.append(line)
            }
        }
        flush()
        // No newline left hanging after the last paragraph.
        if result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    /// The block's inner width: the text's own width, up to the column.
    static func innerWidth(_ message: UserMessage, column: CGFloat) -> CGFloat {
        let maxInner = column - 2 * padH
        let natural = attributed(message.text).boundingRect(with: NSSize(width: maxInner, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).width
        let thumbs = CGFloat(message.images.count) * (thumb * ThumbnailView.aspect + 8)
        return min(maxInner, max(ceil(natural) + 2, thumbs, 160))
    }

    static func height(_ message: UserMessage, width: CGFloat) -> CGFloat {
        let column = ReadingStyle.column(in: width).width
        let inner = innerWidth(message, column: column)
        let body = message.text.isEmpty ? 0 : ReadingTextView.height(of: attributed(message.text), width: inner)
        let images = message.images.isEmpty ? 0 : thumb + (message.text.isEmpty ? 0 : thumbGap)
        return top + padV + header + headerGap + body + images + padV + bottom
    }

    override func configure(_ row: LeituraRow, context: LeituraContext) {
        super.configure(row, context: context)
        guard case let .item(.user(message)) = row else { return }
        let time = Self.time(message.time)
        let title = NSMutableAttributedString(string: "VOCÊ", attributes: [.font: CockpitStyle.micro, .foregroundColor: CockpitStyle.accent, .kern: 0.6])
        if message.isQueued {
            title.append(NSAttributedString(string: "  ·  na fila", attributes: [.font: CockpitStyle.meta, .foregroundColor: CockpitStyle.muted]))
        }
        alphaValue = message.isQueued ? 0.62 : 1
        if !time.isEmpty {
            title.append(NSAttributedString(string: "  ·  " + time, attributes: [.font: CockpitStyle.meta, .foregroundColor: ReadingStyle.faint]))
        }
        label.attributedStringValue = title
        text.show(Self.attributed(message.text))
        text.isHidden = message.text.isEmpty
        text.onOpenLink = { [weak context] in context?.openLink?($0) }
        thumbs.forEach { $0.removeFromSuperview() }
        thumbs = message.images.map { image in
            let view = ThumbnailView(image: image)
            view.onClick = { [weak context] in context?.openImage?(image) }
            addSubview(view)
            return view
        }
        refreshHighlights()
    }

    override func layout() {
        super.layout()
        guard case let .item(.user(message)) = row else { return }
        let column = ReadingStyle.column(in: bounds.width)
        let inner = Self.innerWidth(message, column: column.width)
        let blockHeight = bounds.height - Self.top - Self.bottom
        // What the user said sits at the right of the column, as in any
        // conversation: at a glance, right is you and left is the maestro.
        let blockX = column.x + column.width - (inner + 2 * Self.padH)
        block.frame = NSRect(x: blockX, y: Self.top, width: inner + 2 * Self.padH, height: blockHeight)
        let x = blockX + Self.padH
        var y = Self.top + Self.padV
        label.frame = NSRect(x: x, y: y, width: inner, height: Self.header)
        y += Self.header + Self.headerGap
        let body = message.text.isEmpty ? 0 : ReadingTextView.height(of: text.attributedString(), width: inner)
        text.frame = NSRect(x: x, y: y, width: inner, height: body)
        y += body + (message.text.isEmpty ? 0 : Self.thumbGap)
        var thumbX = x
        for view in thumbs {
            let width = ThumbnailView.aspect * Self.thumb
            view.frame = NSRect(x: thumbX, y: y, width: width, height: Self.thumb)
            thumbX += width + 8
        }
    }

    override func refreshHighlights() {
        Self.highlight([text], context: context, row: row?.id ?? "")
    }

    override func rectOfCurrentMatch() -> NSRect? {
        Self.currentMatchRect([text], context: context, row: row?.id ?? "", in: self)
    }
}

// MARK: - Quiet rows

/// A slash command, a `!` command, an interruption: one faint line.
final class NoteRowView: LeituraRowView {
    static let height: CGFloat = 26
    private let text = ReadingTextView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func configure(_ row: LeituraRow, context: LeituraContext) {
        super.configure(row, context: context)
        guard case let .item(.note(note)) = row else { return }
        let color = note.kind == .interrupted ? CockpitStyle.dangerText.withAlphaComponent(0.8) : ReadingStyle.faint
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        text.show(NSAttributedString(string: note.line, attributes: [.font: CockpitStyle.meta, .foregroundColor: color, .paragraphStyle: style]))
        text.toolTip = note.line
        refreshHighlights()
    }

    override func layout() {
        super.layout()
        let column = ReadingStyle.column(in: bounds.width)
        text.frame = NSRect(x: column.x, y: 6, width: column.width, height: 16)
        text.textContainer?.maximumNumberOfLines = 1
    }

    override func refreshHighlights() { Self.highlight([text], context: context, row: row?.id ?? "") }
    override func rectOfCurrentMatch() -> NSRect? { Self.currentMatchRect([text], context: context, row: row?.id ?? "", in: self) }
}

/// Time passed, or the conversation was compacted: a label between hairlines.
final class DividerRowView: LeituraRowView {
    static let height: CGFloat = 44
    private let left = NSView.filled(CockpitStyle.softLine)
    private let right = NSView.filled(CockpitStyle.softLine)
    private let label = NSTextField.label(font: CockpitStyle.caption, color: ReadingStyle.faint)

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [left, right, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        label.alignment = .center
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func configure(_ row: LeituraRow, context: LeituraContext) {
        super.configure(row, context: context)
        guard case let .item(.divider(divider)) = row else { return }
        label.stringValue = divider.kind == .compacted ? "conversa resumida" : Self.time(divider.time)
        label.textColor = divider.kind == .compacted ? CockpitStyle.muted : ReadingStyle.faint
    }

    override func layout() {
        super.layout()
        let column = ReadingStyle.column(in: bounds.width)
        label.sizeToFit()
        let labelWidth = label.frame.width + 24
        let mid = bounds.height / 2 + 2
        label.frame = NSRect(x: column.x + (column.width - labelWidth) / 2, y: mid - 8, width: labelWidth, height: 16)
        left.frame = NSRect(x: column.x, y: mid, width: label.frame.minX - column.x, height: 1)
        right.frame = NSRect(x: label.frame.maxX, y: mid, width: column.x + column.width - label.frame.maxX, height: 1)
    }
}

/// "trabalhou 4m 0s", under the answer that ended the turn.
final class WorkedRowView: LeituraRowView {
    static let height: CGFloat = 24
    private let label = NSTextField.label(font: CockpitStyle.caption, color: ReadingStyle.faint)

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func configure(_ row: LeituraRow, context: LeituraContext) {
        super.configure(row, context: context)
        guard case let .item(.worked(worked)) = row else { return }
        label.stringValue = "trabalhou " + ReadingDuration.text(worked.seconds)
    }

    override func layout() {
        super.layout()
        let column = ReadingStyle.column(in: bounds.width)
        label.frame = NSRect(x: column.x, y: 2, width: column.width, height: 15)
    }
}

/// A pasted image, small and rounded, cropped to fill its frame; a click
/// opens it in the preview. Decoded off the main thread — a pasted
/// screenshot is megabytes of base64 — and kept, so scrolling back past it
/// does not decode it again.
final class ThumbnailView: NSView {
    var onClick: (() -> Void)?
    /// Set where the image can be taken away: a cross sits in its corner.
    var onRemove: (() -> Void)? {
        didSet {
            guard onRemove != nil, remove == nil else { return }
            let button = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "remover") ?? NSImage(), target: self, action: #selector(removeTapped))
            button.isBordered = false
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            button.contentTintColor = .white
            button.shadow = { let shadow = NSShadow(); shadow.shadowBlurRadius = 3; shadow.shadowColor = .black; return shadow }()
            button.toolTip = "Remover"
            button.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            addSubview(button)
            remove = button
        }
    }
    private var remove: NSButton?

    override func layout() {
        super.layout()
        // The top right corner, whichever way this view's y runs.
        remove?.frame.origin = NSPoint(x: bounds.width - 21, y: isFlipped ? 1 : bounds.height - 21)
    }

    @objc private func removeTapped() { onRemove?() }

    static let aspect: CGFloat = 1.45
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    convenience init(image ref: ImageRef) {
        self.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CockpitStyle.Radius.control
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = CockpitStyle.raisedLine.cgColor
        layer?.backgroundColor = CockpitStyle.raised.cgColor
        layer?.contentsGravity = .resizeAspectFill
        toolTip = ref.path ?? "imagem colada"
        let key = (ref.path ?? String(ref.base64?.prefix(256) ?? "")) as NSString
        if let cached = Self.cache.object(forKey: key) {
            layer?.contents = cached
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let image = Self.load(ref) else { return }
            Self.cache.setObject(image, forKey: key)
            DispatchQueue.main.async { self?.layer?.contents = image }
        }
    }

    /// From the saved file when there is one, else from the transcript's bytes.
    nonisolated static func load(_ ref: ImageRef) -> NSImage? {
        if let path = ref.path, let image = NSImage(contentsOfFile: path) { return image }
        // A file that is no image (a log, a zip) shows as its icon.
        if let path = ref.path, ref.base64 == nil, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        if let base64 = ref.base64, let data = Data(base64Encoded: base64) { return NSImage(data: data) }
        return nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
