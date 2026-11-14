import AppKit
import VitraOrchestrator

/// The right side of a project: every worker the maestro has delegated to.
final class WorkersPanel: NSView {
    /// The user asked for every running worker to be stopped.
    var onStopAll: (([String]) -> Void)?
    /// The user asked to review a delivery's diff.
    var onReview: ((Delivery) -> Void)?

    /// How many workers are running, for the tab's title.
    var runningCount: Int { runningIDs.count }

    private let rows = NSStackView()
    private let scroll = NSScrollView()
    private let empty = NSStackView()
    private let tokens = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
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
        // Only worth a button while there is something to stop.
        stopAll.isHidden = runningIDs.isEmpty

        // What today cost is in the tab bar; the footer keeps the tokens.
        let today = WorkerBoard.totals(runs, since: Calendar.current.startOfDay(for: now))
        tokens.stringValue = WorkerBoard.tokens(today.tokens) + " hoje"

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
        for (index, (row, run)) in zip(shown, runs).enumerated() {
            let view = rowViews[row.id] ?? makeRow(row.id)
            view.show(row, isOpen: openRow == row.id, delivery: Delivery(run))
            // The last row ends on the footer's rule: two lines there would
            // read as a seam.
            view.showsSeparator = index < shown.count - 1
            if rows.arrangedSubviews.firstIndex(of: view) != index {
                rows.removeArrangedSubview(view)
                rows.insertArrangedSubview(view, at: index)
            }
        }
    }

    private func makeRow(_ id: String) -> WorkerRowView {
        let view = WorkerRowView()
        view.onClick = { [weak self] in self?.toggle(id) }
        view.onReview = { [weak self] delivery in self?.onReview?(delivery) }
        view.onStop = { [weak self] in self?.onStopAll?([id]) }
        rowViews[id] = view
        rows.addArrangedSubview(view)
        // Full width: a row's hover and its hairline run edge to edge, and it
        // holds its own content on the shared inset.
        view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        return view
    }

    private func toggle(_ id: String) {
        let previous = openRow
        openRow = previous == id ? nil : id
        for changed in [previous, openRow].compactMap({ $0 }) {
            rowViews[changed]?.setOpen(openRow == changed)
        }
    }

    /// Opens one worker's row, closing the one that was open, and scrolls to it.
    /// For the Palco, which sends you here when a worker is clicked.
    func reveal(_ id: String) {
        guard let view = rowViews[id] else { return }
        let previous = openRow
        openRow = id
        for changed in [previous, id].compactMap({ $0 }) {
            rowViews[changed]?.setOpen(openRow == changed)
        }
        layoutSubtreeIfNeeded()
        view.scrollToVisible(view.bounds)
    }

    @objc private func stopAllWorkers(_ sender: Any?) {
        // One click in the footer must not throw away several workers' paid
        // work unasked; a single one has its own "Parar" in its row too.
        if runningIDs.count > 1 {
            let alert = NSAlert()
            alert.messageText = "Parar \(runningIDs.count) workers?"
            alert.informativeText = "Todos os workers em andamento neste projeto são encerrados. O que já fizeram fica como está."
            alert.addButton(withTitle: "Parar todos")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        onStopAll?(runningIDs)
    }

    // MARK: - Layout

    private func build() {
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false

        let document = TopDownView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false

        let headline = NSTextField.label("Nenhum worker ainda", font: CockpitStyle.title, color: CockpitStyle.text)
        let body = NSTextField(wrappingLabelWithString: "Peça algo ao maestro. O que ele delegar a outros modelos aparece aqui, com tempo e custo.")
        body.font = CockpitStyle.body
        body.textColor = CockpitStyle.muted
        body.alignment = .center
        empty.orientation = .vertical
        empty.spacing = CockpitStyle.Space.md
        empty.setViews([headline, body], in: .center)

        stopAll.target = self
        stopAll.action = #selector(stopAllWorkers(_:))
        stopAll.isBordered = false
        stopAll.wantsLayer = true
        stopAll.layer?.cornerRadius = CockpitStyle.Radius.control
        stopAll.layer?.backgroundColor = CockpitStyle.raised.cgColor
        stopAll.layer?.borderWidth = 1
        stopAll.layer?.borderColor = CockpitStyle.raisedLine.cgColor
        stopAll.attributedTitle = NSAttributedString(string: "Parar todos", attributes: [
            .font: CockpitStyle.label, .foregroundColor: CockpitStyle.text,
        ])
        stopAll.isHidden = true
        stopAll.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            stopAll.heightAnchor.constraint(equalToConstant: 24),
            stopAll.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])
        let footer = NSStackView(views: [tokens, NSView(), stopAll])
        footer.spacing = CockpitStyle.Space.lg
        footer.edgeInsets = NSEdgeInsets(top: 0, left: CockpitStyle.inset, bottom: 0, right: CockpitStyle.inset)

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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    var onClick: (() -> Void)?
    /// The user asked for this one worker to be stopped.
    var onStop: (() -> Void)?
    var onReview: ((Delivery) -> Void)? {
        get { actions.onReview }
        set { actions.onReview = newValue }
    }

    private static let longestAnswerShown = 4000

    private static let dotSize: CGFloat = 8

    private let dot = NSView.filled(CockpitStyle.muted, cornerRadius: CockpitStyle.Radius.dot + 1)
    private let title = NSTextField.label(font: CockpitStyle.ui(13, .medium), color: CockpitStyle.text)
    private let state = NSTextField.label(font: CockpitStyle.body, color: CockpitStyle.muted)
    private let meta = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
    private let answer = NSTextField(wrappingLabelWithString: "")
    private let answerBox = NSView.filled(CockpitStyle.bar, cornerRadius: CockpitStyle.Radius.card)
    private let hairline = NSView.rule(CockpitStyle.softLine)
    private let actions = DeliveryActionsView()
    /// Stops just this worker; shown while its row is open and it runs.
    private let stop = NSButton(title: "", target: nil, action: nil)
    private var delivery: Delivery?
    private var isRunning = false
    /// Whether the row draws the hairline under it.
    var showsSeparator = true {
        didSet { hairline.isHidden = !showsSeparator }
    }
    private var isOpen = false
    private var hasAnswer = false
    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ row: WorkerRow, isOpen: Bool, delivery: Delivery? = nil) {
        self.delivery = delivery
        title.stringValue = row.title
        title.textColor = row.kind == .stopped ? CockpitStyle.muted : CockpitStyle.text
        state.stringValue = row.stateText
        isRunning = row.kind == .running
        meta.stringValue = row.meta
        // Two lines closed, all of it open: the model, the times, the cost and
        // why this worker do not fit one line of the narrow panel.
        meta.maximumNumberOfLines = isOpen ? 0 : 2

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
        actions.show(delivery, isOpen: open)
        stop.isHidden = !(open && isRunning)
        paint()
    }

    private func paint() {
        let lit = isOpen || isHovered
        layer?.backgroundColor = lit ? CockpitStyle.raised.cgColor : NSColor.clear.cgColor
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
        NSBezierPath(rect: bounds).fill()
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

    @objc private func stopClicked() { onStop?() }

    private func build() {
        stop.target = self
        stop.action = #selector(stopClicked)
        stop.isBordered = false
        stop.attributedTitle = NSAttributedString(string: "Parar", attributes: [
            .font: CockpitStyle.label, .foregroundColor: CockpitStyle.dangerText,
        ])
        stop.toolTip = "Parar só este worker"
        stop.isHidden = true
        stop.setContentHuggingPriority(.required, for: .horizontal)
        stop.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = NSStackView(views: [dot, title, state, stop])
        top.spacing = CockpitStyle.Space.md
        // The state word keeps its room, pinned to the right edge; the title
        // takes what is left and is the one that is cut.
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        state.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        answer.font = CockpitStyle.meta
        answer.textColor = CockpitStyle.code
        answer.isSelectable = true
        answer.maximumNumberOfLines = 16
        answer.cell?.truncatesLastVisibleLine = true
        answer.translatesAutoresizingMaskIntoConstraints = false
        answerBox.addSubview(answer)
        answerBox.isHidden = true

        meta.lineBreakMode = .byWordWrapping
        meta.cell?.wraps = true
        meta.cell?.truncatesLastVisibleLine = true
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSStackView(views: [top, meta, answerBox, actions])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = CockpitStyle.Space.sm
        column.setCustomSpacing(CockpitStyle.Space.lg, after: meta)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.inset),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.inset),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.widthAnchor.constraint(equalTo: column.widthAnchor),
            // Under the title, not under the dot.
            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            answerBox.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            answerBox.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            actions.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),

            answer.topAnchor.constraint(equalTo: answerBox.topAnchor, constant: CockpitStyle.Space.lg),
            answer.bottomAnchor.constraint(equalTo: answerBox.bottomAnchor, constant: -CockpitStyle.Space.lg),
            answer.leadingAnchor.constraint(equalTo: answerBox.leadingAnchor, constant: CockpitStyle.Space.lg),
            answer.trailingAnchor.constraint(equalTo: answerBox.trailingAnchor, constant: -CockpitStyle.Space.lg),

            // The same 12 pt above and below every row, on the shared inset.
            column.topAnchor.constraint(equalTo: topAnchor, constant: CockpitStyle.Space.lg),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CockpitStyle.Space.lg),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.inset),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.inset),
        ])
    }
}
