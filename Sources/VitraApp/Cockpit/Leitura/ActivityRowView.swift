import AppKit

/// Everything the maestro did between two pieces of text, as one muted line:
/// "▸ 6 ações · 4m 12s", red when a call failed. Opened, one compact row per
/// call — a status dot, what it did in words, lines changed, how long — and a
/// call opened in turn shows its input and output in the source face.
final class ActivityRowView: LeituraRowView {
    static let headerHeight: CGFloat = 30
    static let callHeight: CGFloat = 25
    static let thoughtHeight: CGFloat = 20
    static let errorHeight: CGFloat = 17
    static let indent: CGFloat = 22
    static let listPad: CGFloat = 8

    private let header = ActivityHeader()
    private let guide = NSView.filled(CockpitStyle.softLine)
    private var lines: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        guide.translatesAutoresizingMaskIntoConstraints = true
        addSubview(guide)
        addSubview(header)
        header.onClick = { [weak self] in
            guard let self, let context = self.context, let id = self.row?.id else { return }
            context.toggleActivity(id)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Measuring

    static func height(_ activity: Activity, width: CGFloat, context: LeituraContext) -> CGFloat {
        guard context.isOpen(activity: activity.id) else { return headerHeight }
        let inner = ReadingStyle.column(in: width).width - indent
        return headerHeight + listPad + activity.steps.reduce(CGFloat(0)) { $0 + height(of: $1, width: inner, context: context) } + listPad
    }

    static func height(of step: Activity.Step, width: CGFloat, context: LeituraContext) -> CGFloat {
        guard case let .call(call) = step else { return thoughtHeight }
        var height = callHeight
        if context.isOpen(call: call.id) {
            height += CallDetailView.height(call, width: width, full: context.showsFull(call: call.id)) + 6
        } else if call.isError {
            height += errorHeight
        }
        return height
    }

    // MARK: - Showing

    override func configure(_ row: LeituraRow, context: LeituraContext) {
        super.configure(row, context: context)
        guard case let .item(.activity(activity)) = row else { return }
        header.show(activity, isOpen: context.isOpen(activity: activity.id))
        lines.forEach { $0.removeFromSuperview() }
        lines = []
        guard context.isOpen(activity: activity.id) else {
            guide.isHidden = true
            return
        }
        guide.isHidden = false
        for step in activity.steps {
            switch step {
            case .thought:
                let label = NSTextField.label("pensou", font: NSFontManager.shared.convert(CockpitStyle.caption, toHaveTrait: .italicFontMask), color: ReadingStyle.faint)
                label.translatesAutoresizingMaskIntoConstraints = true
                lines.append(label)
            case let .call(call):
                let view = CallRowView(call: call, isOpen: context.isOpen(call: call.id), full: context.showsFull(call: call.id))
                view.onToggle = { [weak context, id = row.id] in context?.toggleCall(call.id, in: id) }
                view.onShowAll = { [weak context, id = row.id] in context?.showFullOutput(call.id, in: id) }
                view.onOpenFile = { [weak context] path in context?.openLink?(URL(fileURLWithPath: path)) }
                view.onOpenWorker = { [weak context] id in context?.openWorker?(id) }
                lines.append(view)
            }
        }
        lines.forEach(addSubview)
    }

    override func layout() {
        super.layout()
        guard case let .item(.activity(activity)) = row, let context else { return }
        let column = ReadingStyle.column(in: bounds.width)
        header.frame = NSRect(x: column.x - 4, y: 0, width: column.width + 4, height: Self.headerHeight)
        let inner = column.width - Self.indent
        var y = Self.headerHeight + Self.listPad
        for (view, step) in zip(lines, activity.steps) {
            let height = Self.height(of: step, width: inner, context: context)
            if view is NSTextField {
                view.frame = NSRect(x: column.x + Self.indent, y: y + 2, width: inner, height: 15)
            } else {
                view.frame = NSRect(x: column.x + Self.indent, y: y, width: inner, height: height)
            }
            y += height
        }
        guide.frame = NSRect(x: column.x + 7, y: Self.headerHeight + 2, width: 1, height: max(y - Self.headerHeight - 4, 0))
    }
}

/// The folded line: chevron, the dominant tool's icon, count and time, and
/// what failed.
final class ActivityHeader: NSView {
    var onClick: (() -> Void)?
    private let chevron = NSImageView()
    private let icon = NSImageView()
    private let label = NSTextField.label(font: ReadingStyle.small, color: ReadingStyle.quiet)
    private let failure = NSTextField.label(font: ReadingStyle.small, color: CockpitStyle.dangerText)
    private let dot = NSView.filled(CockpitStyle.danger, cornerRadius: 3)
    private var isHovered = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = CockpitStyle.Radius.control
        for view in [chevron, icon, label, failure, dot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        chevron.contentTintColor = ReadingStyle.faint
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        icon.contentTintColor = ReadingStyle.faint
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ activity: Activity, isOpen: Bool) {
        chevron.image = NSImage(systemSymbolName: isOpen ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        icon.image = NSImage(systemSymbolName: activity.dominantIcon, accessibilityDescription: nil)
        let count = activity.calls.count
        var text = count == 1 ? "1 ação" : "\(count) ações"
        if let duration = activity.duration { text += " · " + ReadingDuration.text(duration) }
        label.stringValue = text
        let failures = activity.failures
        failure.stringValue = failures == 0 ? "" : (failures == 1 ? "1 falhou" : "\(failures) falharam")
        failure.isHidden = failures == 0
        dot.isHidden = failures == 0
        setAccessibilityLabel(text + (failures > 0 ? ", " + failure.stringValue : ""))
        setAccessibilityRole(.button)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        chevron.frame = NSRect(x: 4, y: mid - 6, width: 12, height: 12)
        icon.frame = NSRect(x: 22, y: mid - 7, width: 14, height: 14)
        label.sizeToFit()
        label.frame = NSRect(x: 42, y: mid - 8, width: min(label.frame.width, bounds.width - 140), height: 16)
        dot.frame = NSRect(x: label.frame.maxX + 12, y: mid - 3, width: 6, height: 6)
        failure.sizeToFit()
        failure.frame = NSRect(x: dot.frame.maxX + 6, y: mid - 8, width: failure.frame.width, height: 16)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = CockpitStyle.raised.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
