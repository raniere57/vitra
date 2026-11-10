import AppKit
import VitraOrchestrator

/// The right side of a project: every worker the maestro has delegated to.
final class WorkersPanel: NSView {
    /// The user asked for every running worker to be stopped.
    var onStopAll: (([String]) -> Void)?

    /// How many workers are running, for the tab's title.
    var runningCount: Int { runningIDs.count }

    private let rows = NSStackView()
    private let scroll = NSScrollView()
    private let empty = NSStackView()
    private let cost = NSTextField.label(font: CockpitStyle.mono(11), color: CockpitStyle.text)
    private let tokens = NSTextField.label(font: CockpitStyle.mono(11), color: CockpitStyle.muted)
    private let stopAll = NSButton(title: "Parar todos", target: nil, action: nil)

    private var rowViews: [String: WorkerRowView] = [:]
    private var openRow: String?
    private var runningIDs: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.panel.cgColor
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `runs`, newest first, as they stand at `now`.
    func show(_ runs: [Run], now: Date) {
        let shown = runs.map { WorkerBoard.row($0, now: now) }
        runningIDs = runs.filter { $0.state == .running }.map(\.id)
        stopAll.isEnabled = !runningIDs.isEmpty

        let today = WorkerBoard.totals(runs, since: Calendar.current.startOfDay(for: now))
        cost.stringValue = WorkerBoard.money(today.cost)
        tokens.stringValue = WorkerBoard.tokens(today.tokens)

        empty.isHidden = !shown.isEmpty
        scroll.isHidden = shown.isEmpty

        // Rows are kept by id and updated in place: a worker's clock ticks
        // every second, and rebuilding the list under the pointer each time
        // would drop the hover and jump the scroll.
        let ids = Set(shown.map(\.id))
        for (id, view) in rowViews where !ids.contains(id) {
            view.removeFromSuperview()
            rowViews[id] = nil
        }
        for (index, row) in shown.enumerated() {
            let view = rowViews[row.id] ?? makeRow(row.id)
            view.show(row, isOpen: openRow == row.id)
            if rows.arrangedSubviews.firstIndex(of: view) != index {
                rows.removeArrangedSubview(view)
                rows.insertArrangedSubview(view, at: index)
            }
        }
    }

    private func makeRow(_ id: String) -> WorkerRowView {
        let view = WorkerRowView()
        view.onClick = { [weak self] in self?.toggle(id) }
        rowViews[id] = view
        rows.addArrangedSubview(view)
        // Inside the list's own margins on both sides.
        view.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -20).isActive = true
        return view
    }

    private func toggle(_ id: String) {
        let previous = openRow
        openRow = previous == id ? nil : id
        for changed in [previous, openRow].compactMap({ $0 }) {
            rowViews[changed]?.setOpen(openRow == changed)
        }
    }

    @objc private func stopAllWorkers(_ sender: Any?) {
        onStopAll?(runningIDs)
    }

    // MARK: - Layout

    private func build() {
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        rows.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        rows.translatesAutoresizingMaskIntoConstraints = false

        let document = TopDownView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false

        let headline = NSTextField.label("Nenhum worker ainda", font: CockpitStyle.ui(14, .medium), color: CockpitStyle.text)
        let body = NSTextField(wrappingLabelWithString: "Peça algo ao maestro. O que ele delegar a outros modelos aparece aqui, com tempo e custo.")
        body.font = CockpitStyle.ui(12)
        body.textColor = CockpitStyle.muted
        body.alignment = .center
        empty.orientation = .vertical
        empty.spacing = 8
        empty.setViews([headline, body], in: .center)

        stopAll.target = self
        stopAll.action = #selector(stopAllWorkers(_:))
        stopAll.bezelStyle = .rounded
        stopAll.controlSize = .small
        stopAll.isEnabled = false
        let today = NSTextField.label("hoje", font: CockpitStyle.mono(11), color: CockpitStyle.muted)
        let footer = NSStackView(views: [today, cost, tokens, NSView(), stopAll])
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 14)

        let footerRule = NSView.rule(CockpitStyle.softLine)
        for view in [scroll, empty, footerRule, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerRule.topAnchor),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36),

            footerRule.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footerRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: CockpitStyle.footerHeight),
        ])
    }
}

/// One worker: a dot for its state, what it is doing, and its numbers.
/// Clicking it opens the worker's answer underneath.
final class WorkerRowView: NSView {
    var onClick: (() -> Void)?

    private static let longestAnswerShown = 4000

    private let dot = NSView.filled(CockpitStyle.muted, cornerRadius: 4)
    private let title = NSTextField.label(font: CockpitStyle.ui(13, .medium), color: CockpitStyle.text)
    private let state = NSTextField.label(font: CockpitStyle.ui(12), color: CockpitStyle.muted)
    private let meta = NSTextField.label(font: CockpitStyle.mono(11), color: CockpitStyle.muted)
    private let answer = NSTextField(wrappingLabelWithString: "")
    private let answerBox = NSView.filled(CockpitStyle.bar, cornerRadius: 7)
    private var isOpen = false
    private var hasAnswer = false
    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        translatesAutoresizingMaskIntoConstraints = false
        build()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ row: WorkerRow, isOpen: Bool) {
        title.stringValue = row.title
        title.textColor = row.kind == .stopped ? CockpitStyle.muted : CockpitStyle.text
        state.stringValue = row.stateText
        meta.stringValue = row.meta

        let (dotColor, stateColor): (NSColor, NSColor) = switch row.kind {
        case .running: (CockpitStyle.accent, CockpitStyle.accent)
        case .done: (CockpitStyle.success, CockpitStyle.success)
        case .failed: (CockpitStyle.danger, CockpitStyle.dangerText)
        case .stopped: (CockpitStyle.muted, CockpitStyle.muted)
        }
        dot.layer?.backgroundColor = dotColor.cgColor
        state.textColor = stateColor

        let text = row.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        hasAnswer = !text.isEmpty
        // Only when it changed: this runs every second while anything is
        // running, and setting the text again would drop a selection the user
        // is in the middle of making.
        let shownText = String(text.prefix(Self.longestAnswerShown))
        if answer.stringValue != shownText { answer.stringValue = shownText }
        setAccessibilityLabel("\(row.title), \(row.stateText)")
        setOpen(isOpen)
    }

    func setOpen(_ open: Bool) {
        isOpen = open
        answerBox.isHidden = !(open && hasAnswer)
        paint()
    }

    private func paint() {
        let lit = isOpen || isHovered
        layer?.backgroundColor = lit ? CockpitStyle.raised.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isOpen ? 1 : 0
        layer?.borderColor = CockpitStyle.raisedLine.cgColor
    }

    // MARK: - Pointer and keyboard

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    /// Rows move when a new worker arrives above them, and a row that slides
    /// out from under a still pointer is never told the pointer left. Asking
    /// where the pointer is whenever the row moves keeps one row lit, not two.
    override func layout() {
        super.layout()
        let pointer = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        let hovered = pointer.map(bounds.contains) ?? false
        guard hovered != isHovered else { return }
        isHovered = hovered
        paint()
    }

    // Reachable with Tab and opened with Space or Return, like any button.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " " || event.charactersIgnoringModifiers == "\r" else {
            super.keyDown(with: event)
            return
        }
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        paint()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        paint()
    }

    // MARK: - Layout

    private func build() {
        let top = NSStackView(views: [dot, title, state])
        top.spacing = 9
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        state.setContentHuggingPriority(.required, for: .horizontal)

        answer.font = CockpitStyle.mono(11)
        answer.textColor = CockpitStyle.code
        answer.isSelectable = true
        answer.maximumNumberOfLines = 16
        answer.cell?.truncatesLastVisibleLine = true
        answer.translatesAutoresizingMaskIntoConstraints = false
        answerBox.addSubview(answer)
        answerBox.isHidden = true

        let column = NSStackView(views: [top, meta, answerBox])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.setCustomSpacing(10, after: meta)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            top.widthAnchor.constraint(equalTo: column.widthAnchor),
            // Under the title, not under the dot.
            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            answerBox.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            answerBox.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            answer.topAnchor.constraint(equalTo: answerBox.topAnchor, constant: 10),
            answer.bottomAnchor.constraint(equalTo: answerBox.bottomAnchor, constant: -10),
            answer.leadingAnchor.constraint(equalTo: answerBox.leadingAnchor, constant: 12),
            answer.trailingAnchor.constraint(equalTo: answerBox.trailingAnchor, constant: -12),

            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }
}
