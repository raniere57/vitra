import AppKit

/// One tool call inside an opened activity: status dot, icon, what it did,
/// lines added and removed, how long. Its one-liner opens the file it is
/// about, or the worker it delegated to; anywhere else on the row opens the
/// call itself.
final class CallRowView: NSView {
    var onToggle: (() -> Void)?
    var onShowAll: (() -> Void)?
    var onOpenFile: ((String) -> Void)?
    var onOpenWorker: ((String) -> Void)?

    private let call: ToolCall
    private let dot: NSView
    private let icon = NSImageView()
    private let summary = NSTextField.label(font: ReadingStyle.small, color: CockpitStyle.code)
    private let changes = NSTextField.label(font: CockpitStyle.meta, color: ReadingStyle.quiet)
    private let duration = NSTextField.label(font: CockpitStyle.meta, color: ReadingStyle.faint)
    private let error = NSTextField.label(font: CockpitStyle.caption, color: CockpitStyle.dangerText)
    private var detail: CallDetailView?
    private let isOpen: Bool

    init(call: ToolCall, isOpen: Bool, full: Bool) {
        self.call = call
        self.isOpen = isOpen
        let color: NSColor = switch call.status {
        case .ok: CockpitStyle.success.withAlphaComponent(0.75)
        case .error: CockpitStyle.danger
        case .running: CockpitStyle.accent
        }
        dot = NSView.filled(color, cornerRadius: 3)
        super.init(frame: .zero)
        for view in [dot, icon, summary, changes, duration, error] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        icon.image = NSImage(systemSymbolName: call.icon, accessibilityDescription: nil)
        icon.contentTintColor = ReadingStyle.faint
        icon.symbolConfiguration = .init(pointSize: 10.5, weight: .regular)
        summary.stringValue = call.summary
        summary.toolTip = call.filePath ?? call.summary
        if let path = call.filePath {
            summary.toolTip = "Abrir \(path) no preview"
        } else if let worker = call.workerID {
            summary.toolTip = "Ver o operário \(worker)"
        }
        changes.attributedStringValue = Self.changes(call)
        duration.stringValue = call.duration.map(ReadingDuration.text) ?? (call.status == .running ? "…" : "")
        duration.alignment = .right
        if case let .error(line) = call.status { error.stringValue = line }
        error.isHidden = !call.isError || isOpen
        if isOpen {
            let detail = CallDetailView(call: call, full: full)
            detail.onShowAll = { [weak self] in self?.onShowAll?() }
            addSubview(detail)
            self.detail = detail
        }
        setAccessibilityLabel(call.summary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    static func changes(_ call: ToolCall) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let added = call.added, added > 0 || call.removed ?? 0 > 0 {
            text.append(NSAttributedString(string: "+\(added)", attributes: [.font: CockpitStyle.meta, .foregroundColor: CockpitStyle.success]))
        }
        if let removed = call.removed, removed > 0 {
            text.append(NSAttributedString(string: " −\(removed)", attributes: [.font: CockpitStyle.meta, .foregroundColor: CockpitStyle.dangerText]))
        }
        return text
    }

    override func layout() {
        super.layout()
        let row = ActivityRowView.callHeight
        let mid = row / 2
        dot.frame = NSRect(x: -18, y: mid - 3, width: 6, height: 6)
        icon.frame = NSRect(x: 0, y: mid - 7, width: 14, height: 14)
        duration.frame = NSRect(x: bounds.width - 56, y: mid - 7, width: 56, height: 14)
        changes.sizeToFit()
        let changesWidth = changes.attributedStringValue.length > 0 ? changes.frame.width : 0
        changes.frame = NSRect(x: duration.frame.minX - changesWidth - 8, y: mid - 7, width: changesWidth, height: 14)
        summary.sizeToFit()
        let room = changes.frame.minX - 20 - 12
        summary.frame = NSRect(x: 20, y: mid - 8, width: min(summary.frame.width, room), height: 16)
        error.frame = NSRect(x: 20, y: row - 3, width: bounds.width - 20, height: 15)
        detail?.frame = NSRect(x: 0, y: row + 2, width: bounds.width, height: bounds.height - row - 6)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if summary.frame.contains(point) {
            if let path = call.filePath { return onOpenFile?(path) ?? () }
            if let worker = call.workerID { return onOpenWorker?(worker) ?? () }
        }
        if point.y < ActivityRowView.callHeight + (error.isHidden ? 0 : ActivityRowView.errorHeight) { onToggle?() }
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: ActivityRowView.callHeight), cursor: .pointingHand)
    }

    /// Over a one-liner that opens something, it says so by underlining.
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard call.filePath != nil || call.workerID != nil else { return }
        let area = NSTrackingArea(rect: summary.frame, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { underline(true) }
    override func mouseExited(with event: NSEvent) { underline(false) }

    private func underline(_ on: Bool) {
        summary.attributedStringValue = NSAttributedString(string: call.summary, attributes: [
            .font: ReadingStyle.small, .foregroundColor: on ? ReadingStyle.text : CockpitStyle.code,
            .underlineStyle: on ? NSUnderlineStyle.single.rawValue : 0,
        ])
    }
}

/// An opened call: its input and its output in the source face, the output
/// cut at 40 lines until "mostrar tudo".
final class CallDetailView: NSView {
    static let pad: CGFloat = 10
    static let label: CGFloat = 14
    static let gap: CGFloat = 4
    static let showAll: CGFloat = 24
    static let clipLines = 40

    var onShowAll: (() -> Void)?
    private let inputLabel = NSTextField.label("ENTRADA", font: CockpitStyle.micro, color: ReadingStyle.faint)
    private let outputLabel = NSTextField.label("SAÍDA", font: CockpitStyle.micro, color: ReadingStyle.faint)
    private let input = ReadingTextView()
    private let output = ReadingTextView()
    private let more = NSButton()
    private let call: ToolCall
    private let full: Bool

    init(call: ToolCall, full: Bool) {
        self.call = call
        self.full = full
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = ReadingStyle.codePanel.cgColor
        layer?.cornerRadius = CockpitStyle.Radius.control
        layer?.borderWidth = 1
        layer?.borderColor = ReadingStyle.codeLine.cgColor
        for view in [inputLabel, outputLabel, input, output, more] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        input.show(Self.text(Self.shown(call.input, full: full).text))
        output.show(Self.text(Self.outputText(call, full: full), color: call.isError ? CockpitStyle.dangerText : CockpitStyle.code))
        more.isBordered = false
        let hidden = Self.hiddenLines(call, full: full)
        more.attributedTitle = NSAttributedString(string: "mostrar tudo · mais \(hidden) linhas", attributes: [.font: CockpitStyle.caption, .foregroundColor: ReadingStyle.link])
        more.isHidden = hidden == 0
        more.target = self
        more.action = #selector(showAll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    static func text(_ string: String, color: NSColor = CockpitStyle.code) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.12
        style.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: string.isEmpty ? "—" : string, attributes: [
            .font: CockpitStyle.mono(11.5), .foregroundColor: color, .paragraphStyle: style,
        ])
    }

    /// `text` cut to `clipLines` lines unless `full`, and how many were cut.
    static func shown(_ text: String, full: Bool) -> (text: String, hidden: Int) {
        let lines = text.components(separatedBy: "\n")
        guard !full, lines.count > clipLines else { return (text, 0) }
        return (lines.prefix(clipLines).joined(separator: "\n"), lines.count - clipLines)
    }

    static func outputText(_ call: ToolCall, full: Bool) -> String {
        if call.status == .running { return "ainda rodando…" }
        let shown = shown(UserText.stripANSI(call.output), full: full).text
        return call.isOutputClipped && full ? shown + "\n… (saída cortada em 64 KB)" : shown
    }

    static func hiddenLines(_ call: ToolCall, full: Bool) -> Int {
        shown(call.input, full: full).hidden + shown(UserText.stripANSI(call.output), full: full).hidden
    }

    static func height(_ call: ToolCall, width: CGFloat, full: Bool) -> CGFloat {
        let inner = width - 2 * pad
        let inputHeight = ReadingTextView.height(of: text(shown(call.input, full: full).text), width: inner)
        let outputHeight = ReadingTextView.height(of: text(outputText(call, full: full)), width: inner)
        let more = hiddenLines(call, full: full) > 0 ? showAll : 0
        return pad + label + gap + inputHeight + 12 + label + gap + outputHeight + more + pad
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - 2 * Self.pad
        var y = Self.pad
        inputLabel.frame = NSRect(x: Self.pad, y: y, width: inner, height: Self.label)
        y += Self.label + Self.gap
        let inputHeight = ReadingTextView.height(of: input.attributedString(), width: inner)
        input.frame = NSRect(x: Self.pad, y: y, width: inner, height: inputHeight)
        y += inputHeight + 12
        outputLabel.frame = NSRect(x: Self.pad, y: y, width: inner, height: Self.label)
        y += Self.label + Self.gap
        let outputHeight = ReadingTextView.height(of: output.attributedString(), width: inner)
        output.frame = NSRect(x: Self.pad, y: y, width: inner, height: outputHeight)
        y += outputHeight
        more.sizeToFit()
        more.frame = NSRect(x: Self.pad - 2, y: y + 4, width: more.frame.width, height: 18)
    }

    @objc private func showAll() { onShowAll?() }
}
