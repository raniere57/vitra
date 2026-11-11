import AppKit

/// A delivery's diff, read line by line, with comments pinned to lines and
/// sent back to the worker as one redo.
///
/// One table row per line, header, hunk and comment, with views reused as
/// they scroll: a diff of thousands of lines costs a screenful of views.
final class DiffReviewView: NSView {
    /// Hands the formatted notes to the worker and reports how it went.
    typealias Send = (_ notes: String, _ done: @escaping @MainActor @Sendable (DeliveryRedo.Outcome) -> Void) -> Void

    /// Leaves the review for wherever the user came from.
    var onBack: (() -> Void)?

    let delivery: Delivery
    let book: ReviewCommentBook
    let table = DiffTable()
    private(set) var files: [DiffFile] = []
    private(set) var rows: [DiffRow] = []
    private(set) var geometry = DiffGeometry(largestNumber: 0)
    var editing: DiffEditing?
    var selected: DiffLineRef?
    /// Where each line's row is, for putting the selection back after the
    /// rows are rebuilt.
    private var lineRows: [DiffLineRef: Int] = [:]

    private let isSolo: Bool
    private let send: Send
    private let scroll = NSScrollView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
    private let message = NSTextField.wrapping("Lendo as mudanças…", font: CockpitStyle.body, color: CockpitStyle.muted)
    private let summary = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
    private let count = NSTextField.label(font: CockpitStyle.label, color: CockpitStyle.text)
    private let status = NSTextField.label(font: CockpitStyle.caption, color: CockpitStyle.muted)
    private lazy var copyButton = Self.button("Copiar", target: self, action: #selector(copyClicked))
    private lazy var primaryButton = Self.button(
        isSolo ? "Copiar para o maestro" : "Enviar ao operário", target: self, action: #selector(primaryClicked), primary: true
    )
    private var isSending = false
    private var lastWidth: CGFloat = 0

    /// `loads: false` leaves git alone; the snapshot tool fills the view itself.
    init(delivery: Delivery, book: ReviewCommentBook, isSolo: Bool, loads: Bool = true, send: @escaping Send) {
        self.delivery = delivery
        self.book = book
        self.isSolo = isSolo
        self.send = send
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.panel.cgColor
        build()
        refreshFooter()
        if loads { load() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    private func load() {
        let delivery = delivery
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = DeliveryDiff.load(delivery)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.show(outcome) }
            }
        }
    }

    func show(_ outcome: DeliveryDiff.Outcome) {
        switch outcome {
        case let .files(files) where files.isEmpty: showMessage("Nenhuma mudança nesta entrega.")
        case let .files(files): show(files)
        case .gone: showMessage(DeliveryDiff.goneText)
        case let .failed(text): showMessage(text)
        }
    }

    func show(_ files: [DiffFile]) {
        self.files = files
        let numbers = files.flatMap(\.hunks).flatMap(\.lines).flatMap { [$0.old ?? 0, $0.new ?? 0] }
        geometry = DiffGeometry(largestNumber: numbers.max() ?? 0)
        table.gutterWidth = geometry.gutterWidth
        let longest = files.flatMap(\.hunks).flatMap(\.lines).map { $0.text.count + 3 * $0.text.filter { $0 == "\t" }.count }.max() ?? 0
        column.minWidth = geometry.width(columns: longest)
        let totals = DiffRows.totals(files)
        summary.attributedStringValue = Self.summaryText(totals)
        message.isHidden = true
        scroll.isHidden = false
        rebuild()
        if selected == nil { move(.down) }
    }

    private func showMessage(_ text: String) {
        message.stringValue = text
        message.isHidden = false
        scroll.isHidden = true
        primaryButton.isEnabled = false
        copyButton.isEnabled = !book.comments(for: delivery.runID).isEmpty
    }

    /// Lays the rows out again from the diff and the comments, and puts the
    /// selection back on the same line.
    func rebuild() {
        rows = DiffRows.build(files, comments: book.comments(for: delivery.runID), editing: editing)
        lineRows = [:]
        for (index, row) in rows.enumerated() {
            if case let .line(ref, _) = row { lineRows[ref] = index }
        }
        table.reloadData()
        if let selected, let row = lineRows[selected] {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        refreshFooter()
        focusEditor()
    }

    private func focusEditor() {
        guard let index = rows.firstIndex(where: { if case .editor = $0 { true } else { false } }) else { return }
        table.scrollRowToVisible(index)
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? DiffEditorCell {
            window?.makeFirstResponder(cell.field)
        }
    }

    /// Hands the keyboard to the diff, for when the view has just been shown.
    func focus() {
        window?.makeFirstResponder(table)
        focusEditor()
    }

    // MARK: - Comments

    /// Opens the field under a line: for a new comment, or to rewrite `comment`.
    func beginComment(on line: DiffLineRef, rewriting comment: UUID? = nil) {
        selected = line
        editing = DiffEditing(line: line, comment: comment)
        rebuild()
    }

    func endComment(saving text: String?) {
        defer {
            editing = nil
            rebuild()
            window?.makeFirstResponder(table)
        }
        guard let editing, let text else { return }
        if let id = editing.comment {
            book.edit(id, text: text, run: delivery.runID)
        } else if let anchor = anchor(of: editing.line), let row = lineRows[editing.line],
                  case let .line(_, ordinal) = rows[row] {
            book.add(text, at: anchor, order: ordinal, run: delivery.runID)
        }
    }

    func remove(_ comment: UUID) {
        book.remove(comment, run: delivery.runID)
        rebuild()
    }

    func anchor(of ref: DiffLineRef) -> ReviewAnchor? {
        ReviewAnchor(path: files[ref.file].path, line: files[ref.file].hunks[ref.hunk].lines[ref.line])
    }

    // MARK: - Moving

    /// Steps the selection onto the next line of code in a direction, over
    /// headers and notes.
    @discardableResult
    func move(_ key: DiffKey) -> Bool {
        let from = selected.flatMap { lineRows[$0] }
        switch key {
        case .up: select(lineRow(from: (from ?? rows.count) - 1, step: -1))
        case .down: select(lineRow(from: (from ?? -1) + 1, step: 1))
        case .nextFile, .previousFile:
            let step = key == .nextFile ? 1 : -1
            var index = (from ?? (step > 0 ? -1 : rows.count)) + step
            // Back to this file's own header first when going up, so p from
            // the middle of a file reaches the file before it.
            if step < 0, let from { index = (fileRow(from: from, step: -1) ?? 0) - 1 }
            guard let header = fileRow(from: index, step: step) else { return true }
            select(lineRow(from: header, step: 1))
            scrollToTop(header)
        case .comment:
            if let selected { beginComment(on: selected) }
        case .back:
            onBack?()
        }
        return true
    }

    private func lineRow(from start: Int, step: Int) -> Int? {
        var index = start
        while rows.indices.contains(index) {
            if case .line = rows[index] { return index }
            index += step
        }
        return nil
    }

    private func fileRow(from start: Int, step: Int) -> Int? {
        var index = start
        while rows.indices.contains(index) {
            if case .file = rows[index] { return index }
            index += step
        }
        return nil
    }

    private func select(_ row: Int?) {
        guard let row, let ref = rows[row].lineRef else { return }
        selected = ref
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func scrollToTop(_ row: Int) {
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: table.rect(ofRow: row).minY))
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: - Sending

    @objc private func primaryClicked() {
        guard !isSolo else { return copyClicked() }
        let comments = book.comments(for: delivery.runID)
        guard !comments.isEmpty, !isSending else { return }
        isSending = true
        say("Enviando…", color: CockpitStyle.muted)
        let run = delivery.runID
        send(ReviewNotes.format(comments)) { [weak self] outcome in
            guard let self else { return }
            self.isSending = false
            switch outcome {
            case let .started(id):
                self.book.clear(run: run)
                self.editing = nil
                self.rebuild()
                self.say("Enviado — refazendo como \(id)", color: CockpitStyle.success)
            case let .refused(text):
                self.say(text, color: CockpitStyle.dangerText)
            }
        }
    }

    @objc private func copyClicked() {
        let comments = book.comments(for: delivery.runID)
        guard !comments.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ReviewNotes.format(comments), forType: .string)
        say(isSolo ? "Copiado — cole no maestro." : "Copiado.", color: CockpitStyle.muted)
    }

    private func say(_ text: String, color: NSColor) {
        status.stringValue = text
        status.textColor = color
        status.toolTip = text
        refreshFooter()
    }

    func refreshFooter() {
        let n = book.comments(for: delivery.runID).count
        count.stringValue = ReviewNotes.count(n)
        count.textColor = n == 0 ? CockpitStyle.muted : CockpitStyle.text
        primaryButton.isEnabled = n > 0 && !isSending
        copyButton.isEnabled = n > 0
    }

    // MARK: - Resizing

    /// A comment wraps to the view's width, so its row's height follows it.
    override func layout() {
        super.layout()
        let width = scroll.contentView.bounds.width
        guard width != lastWidth else { return }
        lastWidth = width
        let notes = rows.indices.filter { if case .comment = rows[$0] { true } else { false } }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(notes))
    }

    var plateWidth: CGFloat {
        CommentPlate.width(visible: scroll.contentView.bounds.width, geometry: geometry)
    }

    // MARK: - Layout

    private func build() {
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = CockpitStyle.panel
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.floatsGroupRows = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.onKey = { [weak self] key in self?.move(key) ?? false }
        table.onGutterClick = { [weak self] row in self?.gutterClicked(row) ?? false }
        table.setAccessibilityLabel("Diff de \(delivery.label)")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.isHidden = true
        message.alignment = .center
        message.textColor = CockpitStyle.muted

        let header = DiffReviewChrome.header(
            label: delivery.label, worker: delivery.worker, summary: summary, target: self, back: #selector(backClicked)
        )
        let footer = DiffReviewChrome.footer(
            count: count, status: status, buttons: isSolo ? [primaryButton] : [copyButton, primaryButton]
        )
        DiffReviewChrome.arrange(header: header, body: scroll, message: message, footer: footer, in: self)
    }

    @objc private func backClicked() { onBack?() }

    private func gutterClicked(_ row: Int) -> Bool {
        guard rows.indices.contains(row), case let .line(ref, _) = rows[row] else { return false }
        beginComment(on: ref)
        return true
    }

    private static func summaryText(_ totals: (added: Int, removed: Int, files: Int)) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "+\(totals.added)", attributes: [.foregroundColor: CockpitStyle.success, .font: CockpitStyle.meta])
        text.append(NSAttributedString(string: " −\(totals.removed)", attributes: [.foregroundColor: CockpitStyle.dangerText, .font: CockpitStyle.meta]))
        let files = " · \(totals.files) \(totals.files == 1 ? "arquivo" : "arquivos")"
        text.append(NSAttributedString(string: files, attributes: [.foregroundColor: CockpitStyle.muted, .font: CockpitStyle.meta]))
        return text
    }

    private static func button(_ title: String, target: AnyObject, action: Selector, primary: Bool = false) -> NSButton {
        DiffReviewChrome.button(title, target: target, action: action, primary: primary)
    }
}
