import AppKit

/// The "Fila" under the maestro's header: what the maestro is told next.
///
/// Three shapes. Nothing at all, not even a line, while the queue is empty
/// and nobody is writing in it. A pill, "fila · 3", while it holds prompts.
/// Open, a list — reorder by dragging, × to remove, click to edit in place —
/// over a field to add another and a switch to hold the queue.
///
/// It never takes the keyboard by itself: a queue redrawn because a prompt
/// went out leaves the focus where it was, in the terminal most likely.
final class PromptQueueDrawer: NSView {
    /// The user changed the queue; the owner saves it.
    var onChange: ((PromptQueue) -> Void)?
    /// The user resumed a paused queue: perhaps the moment to send.
    var onResume: (() -> Void)?
    /// ⎋ in the field: the keyboard goes back to the maestro.
    var onDismiss: (() -> Void)?
    /// The height changed; the owner lays the terminal out again.
    var onHeightChange: (() -> Void)?

    private(set) var queue = PromptQueue()
    private(set) var isExpanded = false
    /// The prompt just sent, shown for a moment as "enviado".
    private var sent: QueuedPrompt?
    private var sentClear: DispatchWorkItem?
    private var editingID: UUID?
    private var editDraft = ""

    private static let rowHeight: CGFloat = 26
    private static let stripHeight: CGFloat = 32
    private static let visibleRows = 6
    private static let sentLasts: TimeInterval = 1.6
    private static let fieldMinHeight: CGFloat = 24
    private static let fieldMaxHeight: CGFloat = 88
    private static let dragType = NSPasteboard.PasteboardType("dev.vitra.queued-prompt")

    private lazy var height = heightAnchor.constraint(equalToConstant: 0)

    // Collapsed
    private let pill = QueuePill()

    // Expanded
    private let expanded = NSView()
    private let titleLabel = NSTextField.label("FILA", font: CockpitStyle.micro, color: CockpitStyle.muted)
    private let countLabel = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
    private let pausedLabel = NSTextField.label("pausada", font: CockpitStyle.label, color: CockpitStyle.accent)
    private lazy var pauseButton = Self.textButton("Pausar", target: self, action: #selector(togglePause(_:)))
    private lazy var closeButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Recolher a fila") ?? NSImage(), target: self, action: #selector(collapseClicked(_:)))
        button.isBordered = false
        button.contentTintColor = CockpitStyle.muted
        button.toolTip = "Recolher a fila"
        return button
    }()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private lazy var tableHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
    let field = QueueField()
    private lazy var fieldHeight = field.heightAnchor.constraint(equalToConstant: Self.fieldMinHeight)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.panel.cgColor
        clipsToBounds = true
        build()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - From the owner

    /// The queue as it now is, after a send or a load. Redraws without
    /// touching the keyboard focus.
    func show(_ queue: PromptQueue) {
        self.queue = queue
        if let editingID, !queue.items.contains(where: { $0.id == editingID }) { self.editingID = nil }
        render()
    }

    /// `prompt` just went to the maestro: shown a moment, then let go of.
    func showSent(_ prompt: QueuedPrompt) {
        sent = prompt
        sentClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.sent = nil
            self?.render()
        }
        sentClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sentLasts, execute: work)
        render()
    }

    /// Opens the list; `focusingField` hands the add field the keyboard.
    func open(focusingField: Bool) {
        isExpanded = true
        render()
        if focusingField { window?.makeFirstResponder(field) }
    }

    func collapse() {
        commitEdit()
        isExpanded = false
        render()
    }

    /// The edit in place of `id`, for the snapshot tool.
    func beginEditing(_ id: UUID) {
        guard let prompt = queue.items.first(where: { $0.id == id }) else { return }
        editingID = id
        editDraft = prompt.text
        render()
    }

    /// Nothing to show: no height, no line.
    var isEmptyShape: Bool { queue.isEmpty && !isExpanded && sent == nil }

    // MARK: - Drawing

    private func render() {
        let rows = rowCount
        isHidden = isEmptyShape
        pill.isHidden = isExpanded || isHidden
        expanded.isHidden = !isExpanded
        pill.show(count: queue.count, paused: queue.isPaused, sent: sent.map { WorkerBoard.firstLine($0.text) })
        countLabel.stringValue = queue.isEmpty ? "vazia" : "\(queue.count)"
        pausedLabel.isHidden = !queue.isPaused
        pauseButton.attributedTitle = Self.buttonTitle(queue.isPaused ? "Retomar" : "Pausar")
        pauseButton.toolTip = queue.isPaused
            ? "Volta a mandar um pedido da fila a cada turno que o maestro termina"
            : "Segura a fila: nada é mandado ao maestro até você retomar"
        // The row being edited is rebuilt by the reload; it must not take
        // its own removal for the user clicking away, and the keyboard goes
        // back into it only if it was there.
        let editorHadFocus = editorHasFocus
        visibleRows.forEach { $0.stopListening() }
        table.reloadData()
        tableHeight.constant = CGFloat(min(rows, Self.visibleRows)) * Self.rowHeight
            + (editingRow.map { _ in editRowExtra } ?? 0)
        sizeField()
        let newHeight = isHidden ? 0 : (isExpanded ? expandedHeight : Self.stripHeight)
        if height.constant != newHeight {
            height.constant = newHeight
            onHeightChange?()
        }
        if editorHadFocus { focusEditor() }
    }

    private var visibleRows: [QueueRow] {
        (0 ..< table.numberOfRows).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? QueueRow }
    }

    private var editorHasFocus: Bool {
        guard let editor = (window?.firstResponder as? NSTextView)?.delegate as? NSView else { return false }
        return editor.isDescendant(of: table)
    }

    private func focusEditor() {
        guard let row = editingRow,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? QueueRow
        else { return }
        window?.makeFirstResponder(cell.editor)
    }

    private var rowCount: Int { queue.count + (sent == nil ? 0 : 1) }
    private var editingRow: Int? {
        editingID.flatMap { id in queue.items.firstIndex { $0.id == id } }.map { $0 + (sent == nil ? 0 : 1) }
    }

    private var editRowExtra: CGFloat {
        max(0, editHeight - Self.rowHeight)
    }

    private var editHeight: CGFloat {
        // The editor runs from the text's start to the ×, less its padding;
        // the row adds its own margin above and below.
        let width = max(bounds.width, 280) - 80
        let lines = Self.measure(editDraft, width: width)
        return min(max(Self.rowHeight, lines + 16), Self.fieldMaxHeight + 8)
    }

    /// The width decides how the edited prompt and the field wrap: measured
    /// again when it changes, which is also the first real layout.
    private var laidOutWidth: CGFloat = 0
    override func layout() {
        super.layout()
        guard bounds.width != laidOutWidth else { return }
        laidOutWidth = bounds.width
        guard isExpanded else { return }
        if let row = editingRow { table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row)) }
        tableHeight.constant = CGFloat(min(rowCount, Self.visibleRows)) * Self.rowHeight + editRowExtra
        sizeField()
        height.constant = expandedHeight
    }

    private var expandedHeight: CGFloat {
        let header: CGFloat = 30
        let list = tableHeight.constant
        let fieldArea = fieldHeight.constant + CockpitStyle.Space.md * 2
        return header + list + fieldArea
    }

    private func sizeField() {
        let width = max(bounds.width, 280) - 2 * CockpitStyle.inset
        let text = field.stringValue.isEmpty ? "M" : field.stringValue
        fieldHeight.constant = min(max(Self.measure(text, width: width - 12) + 8, Self.fieldMinHeight), Self.fieldMaxHeight)
    }

    private static func measure(_ text: String, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: max(width, 40), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: CockpitStyle.body]
        )
        return ceil(rect.height)
    }

    // MARK: - Actions

    @objc private func togglePause(_ sender: Any?) {
        queue.isPaused.toggle()
        onChange?(queue)
        render()
        if !queue.isPaused { onResume?() }
    }

    @objc private func collapseClicked(_ sender: Any?) { collapse() }

    fileprivate func add(_ text: String) {
        guard queue.add(text, now: Date()) != nil else { return }
        field.stringValue = ""
        onChange?(queue)
        render()
    }

    fileprivate func remove(_ id: UUID) {
        if editingID == id { editingID = nil }
        queue.remove(id)
        onChange?(queue)
        render()
    }

    private func startEditing(row: Int) {
        let index = row - (sent == nil ? 0 : 1)
        guard queue.items.indices.contains(index) else { return }
        commitEdit()
        editingID = queue.items[index].id
        editDraft = queue.items[index].text
        render()
        focusEditor()
    }

    /// `returnToField`: after ⏎, the keyboard goes to the add field; after a
    /// click elsewhere, it stays wherever the click put it.
    fileprivate func commitEdit(returnToField: Bool = false) {
        guard let id = editingID else { return }
        editingID = nil
        queue.edit(id, text: editDraft)
        onChange?(queue)
        render()
        if returnToField { window?.makeFirstResponder(field) }
    }

    fileprivate func cancelEdit() {
        editingID = nil
        render()
        window?.makeFirstResponder(field)
    }

    // MARK: - Layout

    private func build() {
        height.isActive = true
        pill.onClick = { [weak self] in self?.open(focusingField: false) }

        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        pausedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [titleLabel, countLabel, pausedLabel, NSView(), pauseButton, closeButton])
        header.spacing = CockpitStyle.Space.md
        header.edgeInsets = NSEdgeInsets(top: 0, left: CockpitStyle.inset, bottom: 0, right: CockpitStyle.inset - CockpitStyle.Space.xs)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("prompt"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // A click edits a row, a drag moves it; neither takes the keyboard
        // from the terminal by itself.
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.registerForDraggedTypes([Self.dragType])
        table.draggingDestinationFeedbackStyle = .gap
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        field.placeholderString = "Adicionar à fila…"
        field.drawer = self
        field.toolTip = "⏎ adiciona · ⇧⏎ nova linha · ⎋ fecha"

        for view in [header, scroll, field] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            expanded.addSubview(view)
        }
        let rule = NSView.rule(CockpitStyle.softLine)
        for view in [pill, expanded, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.inset),
            pill.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.stripHeight / 2),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -CockpitStyle.inset),

            expanded.topAnchor.constraint(equalTo: topAnchor),
            expanded.leadingAnchor.constraint(equalTo: leadingAnchor),
            expanded.trailingAnchor.constraint(equalTo: trailingAnchor),
            expanded.bottomAnchor.constraint(equalTo: rule.topAnchor),
            header.topAnchor.constraint(equalTo: expanded.topAnchor),
            header.leadingAnchor.constraint(equalTo: expanded.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: expanded.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: expanded.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: expanded.trailingAnchor),
            tableHeight,
            field.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: CockpitStyle.Space.md),
            field.leadingAnchor.constraint(equalTo: expanded.leadingAnchor, constant: CockpitStyle.inset),
            field.trailingAnchor.constraint(equalTo: expanded.trailingAnchor, constant: -CockpitStyle.inset),
            fieldHeight,

            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row != editingRow else { return }
        if sent != nil, row == 0 { return }
        startEditing(row: row)
    }

    private static func textButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: target, action: action)
        button.isBordered = false
        button.attributedTitle = buttonTitle(title)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private static func buttonTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: CockpitStyle.label, .foregroundColor: CockpitStyle.text])
    }
}

// MARK: - The list

extension PromptQueueDrawer: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row == editingRow ? editHeight : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = QueueRow()
        if let sent, row == 0 {
            cell.show(index: nil, text: sent.text, sent: true)
            return cell
        }
        let index = row - (sent == nil ? 0 : 1)
        guard queue.items.indices.contains(index) else { return nil }
        let prompt = queue.items[index]
        cell.show(index: index + 1, text: prompt.text, sent: false)
        cell.onRemove = { [weak self] in self?.remove(prompt.id) }
        if prompt.id == editingID {
            cell.beginEditing(editDraft, drawer: self)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row != editingRow, !(sent != nil && row == 0) else { return nil }
        let item = NSPasteboardItem()
        item.setString("\(row)", forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let offset = sent == nil ? 0 : 1
        guard let text = info.draggingPasteboard.string(forType: Self.dragType), let from = Int(text).map({ $0 - offset }),
              queue.items.indices.contains(from)
        else { return false }
        // `row` counts the dragged row itself; once it is lifted out, a
        // drop below it lands one higher.
        let target = max(row - offset, 0)
        queue.move(queue.items[from].id, to: target > from ? target - 1 : target)
        onChange?(queue)
        render()
        return true
    }

    fileprivate func draftChanged(_ text: String) {
        editDraft = text
        let before = tableHeight.constant
        if let row = editingRow {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }
        }
        tableHeight.constant = CGFloat(min(rowCount, Self.visibleRows)) * Self.rowHeight + editRowExtra
        if before != tableHeight.constant {
            height.constant = expandedHeight
            onHeightChange?()
        }
    }

    fileprivate func fieldChanged() {
        let before = fieldHeight.constant
        sizeField()
        if before != fieldHeight.constant {
            height.constant = expandedHeight
            onHeightChange?()
        }
    }
}

// MARK: - Keys in the fields

/// Return adds or commits, Shift-Return breaks the line, Escape leaves.
private func handleQueueCommand(_ selector: Selector, in textView: NSTextView, commit: () -> Void, leave: () -> Void) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
        } else {
            commit()
        }
        return true
    case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
    case #selector(NSResponder.cancelOperation(_:)):
        leave()
        return true
    default:
        return false
    }
}

/// A text cell with room around its text, drawn and edited alike: a field
/// without a bezel otherwise puts its text against its border.
private final class PaddedCell: NSTextFieldCell {
    static let padding = NSSize(width: 6, height: 4)

    private func inset(_ rect: NSRect) -> NSRect {
        rect.insetBy(dx: Self.padding.width, dy: Self.padding.height)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: inset(rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inset(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: inset(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

/// The look both editable fields of the drawer share.
private func styleQueueEditor(_ field: NSTextField, border: NSColor) {
    field.cell = PaddedCell(textCell: "")
    field.isEditable = true
    field.isSelectable = true
    field.font = CockpitStyle.body
    field.textColor = CockpitStyle.text
    field.isBordered = false
    // The ground is the layer's, edge to edge; the cell's own would stop at
    // its padding and show as a second, inner plate.
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = false
    field.cell?.wraps = true
    field.cell?.isScrollable = false
    field.lineBreakMode = .byWordWrapping
    field.wantsLayer = true
    field.layer?.backgroundColor = CockpitStyle.raised.cgColor
    field.layer?.cornerRadius = CockpitStyle.Radius.control
    field.layer?.borderWidth = 1
    field.layer?.borderColor = border.cgColor
}

/// "Adicionar à fila…": wraps, grows to a few lines, ⏎ (or ⌘⏎) adds.
final class QueueField: NSTextField, NSTextFieldDelegate {
    fileprivate weak var drawer: PromptQueueDrawer?

    init() {
        super.init(frame: .zero)
        styleQueueEditor(self, border: CockpitStyle.raisedLine)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// ⌘⏎ is no menu chord; here it adds, like ⏎.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if currentEditor() != nil, event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            drawer?.add(stringValue)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        handleQueueCommand(selector, in: textView, commit: { drawer?.add(textView.string) }, leave: { drawer?.onDismiss?() })
    }

    func controlTextDidChange(_ notification: Notification) {
        drawer?.fieldChanged()
    }
}

/// One prompt of the list: its place, its first line, and ×. Edited in place.
private final class QueueRow: NSTableCellView, NSTextFieldDelegate {
    var onRemove: (() -> Void)?
    let editor = NSTextField()
    private let number = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
    private let text = NSTextField.label(font: CockpitStyle.body, color: CockpitStyle.text)
    private let state = NSTextField.label("enviado", font: CockpitStyle.label, color: CockpitStyle.success)
    private lazy var remove: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Tirar da fila") ?? NSImage(), target: self, action: #selector(removeClicked(_:)))
        button.isBordered = false
        button.contentTintColor = CockpitStyle.muted
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        button.toolTip = "Tirar da fila"
        return button
    }()
    private weak var drawer: PromptQueueDrawer?
    private var isEditing = false

    init() {
        super.init(frame: .zero)
        number.alignment = .right
        number.setContentCompressionResistancePriority(.required, for: .horizontal)
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        remove.setContentCompressionResistancePriority(.required, for: .horizontal)
        styleQueueEditor(editor, border: CockpitStyle.accent.withAlphaComponent(0.6))
        editor.delegate = self
        editor.isHidden = true
        for view in [number, text, state, remove, editor] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.inset - CockpitStyle.Space.xs),
            number.widthAnchor.constraint(equalToConstant: 16),
            number.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
            text.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: CockpitStyle.Space.md),
            text.centerYAnchor.constraint(equalTo: topAnchor, constant: 13),
            text.trailingAnchor.constraint(lessThanOrEqualTo: state.leadingAnchor, constant: -CockpitStyle.Space.md),
            state.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            state.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -CockpitStyle.Space.sm),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.inset + CockpitStyle.Space.xs),
            remove.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 16),
            editor.leadingAnchor.constraint(equalTo: text.leadingAnchor, constant: -CockpitStyle.Space.xs),
            editor.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -CockpitStyle.Space.sm),
            editor.topAnchor.constraint(equalTo: topAnchor, constant: CockpitStyle.Space.hair),
            editor.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CockpitStyle.Space.sm),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(index: Int?, text full: String, sent: Bool) {
        number.stringValue = index.map(String.init) ?? "↑"
        number.textColor = sent ? CockpitStyle.success : CockpitStyle.muted
        text.stringValue = WorkerBoard.firstLine(full)
        text.textColor = sent ? CockpitStyle.muted : CockpitStyle.text
        // The whole prompt on hover: the row shows its first line only.
        toolTip = full
        state.isHidden = !sent
        remove.isHidden = sent
    }

    func beginEditing(_ draft: String, drawer: PromptQueueDrawer) {
        self.drawer = drawer
        isEditing = true
        editor.stringValue = draft
        editor.isHidden = false
        text.isHidden = true
        toolTip = "⏎ guarda · ⇧⏎ nova linha · ⎋ desfaz"
    }

    /// Being rebuilt: the end of editing that comes with it is no commit.
    func stopListening() { isEditing = false }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        handleQueueCommand(selector, in: textView, commit: {
            isEditing = false
            drawer?.commitEdit(returnToField: true)
        }, leave: {
            isEditing = false
            drawer?.cancelEdit()
        })
    }

    func controlTextDidChange(_ notification: Notification) {
        drawer?.draftChanged(editor.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Clicked away: the edit is kept, as a text field keeps its text.
        guard isEditing else { return }
        isEditing = false
        let movement = (notification.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        if movement != .cancel { drawer?.commitEdit() }
    }

    @objc private func removeClicked(_ sender: Any?) { onRemove?() }
}

/// The collapsed drawer: "fila · 3", "pausada" in amber when held, and for
/// a moment after a send what went.
private final class QueuePill: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    var onClick: (() -> Void)?
    private let label = NSTextField.label(font: CockpitStyle.label, color: CockpitStyle.text)
    private let paused = NSTextField.label("pausada", font: CockpitStyle.label, color: CockpitStyle.accent)
    private let sentLabel = NSTextField.label(font: CockpitStyle.label, color: CockpitStyle.success)
    private let icon = NSImageView(image: NSImage(systemSymbolName: "text.line.first.and.arrowtriangle.forward", accessibilityDescription: nil) ?? NSImage())

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CockpitStyle.Radius.control
        layer?.borderWidth = 1
        layer?.backgroundColor = CockpitStyle.raised.cgColor
        layer?.borderColor = CockpitStyle.raisedLine.cgColor
        icon.contentTintColor = CockpitStyle.muted
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        sentLabel.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [icon, label, paused, sentLabel])
        row.spacing = CockpitStyle.Space.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: CockpitStyle.Space.xs),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CockpitStyle.Space.xs),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.Space.md),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.Space.md),
            sentLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        toolTip = "Abrir a fila (⇧⌘⏎)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(count: Int, paused isPaused: Bool, sent: String?) {
        label.stringValue = "fila · \(count)"
        label.isHidden = count == 0
        paused.isHidden = !isPaused || count == 0
        sentLabel.stringValue = sent.map { "enviado: " + $0 } ?? ""
        sentLabel.isHidden = sent == nil
        setAccessibilityLabel("Fila: \(count) pedidos" + (isPaused ? ", pausada" : ""))
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
