import AppKit

/// The reading list: a view-based table, one row per item, heights measured
/// once and cached, row views reused — smooth with thousands of items.
///
/// It sticks to the bottom only while the user is there: new content then
/// scrolls in; read higher up, new content waits behind a pill. Rows prepended
/// from older stretches keep what is on screen where it is.
@MainActor
final class LeituraList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let context = LeituraContext()
    /// Scrolled near the top while there is more before it.
    var onNearTop: (() -> Void)?
    /// Whether the bottom is in view changed.
    var onBottomChange: ((Bool) -> Void)?

    private(set) var rows: [LeituraRow] = []
    let scroll = ReadingScrollView()
    let table = NSTableView()
    private(set) var isAtBottom = true
    private static let nearTop: CGFloat = 600
    private static let bottomSlack: CGFloat = 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = ReadingStyle.page
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAutomaticRowHeights = false
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Conversa do maestro")
        let clip = StickyClipView()
        clip.onResize = { [weak self] in
            guard let self, self.isAtBottom, !self.rows.isEmpty else { return }
            self.scrollToBottom()
        }
        scroll.contentView = clip
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = ReadingStyle.page
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.postsBoundsChangedNotifications = true
        addFilling(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(userScrolled), name: NSScrollView.didLiveScrollNotification, object: scroll)
        scroll.onUserScroll = { [weak self] in self?.userScrolled() }
        context.rowChanged = { [weak self] id in self?.rowChanged(id) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Room under the last row, for what floats over the list's bottom.
    var bottomInset: CGFloat = 0 {
        didSet { scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: bottomInset, right: 0) }
    }

    // MARK: - Updating

    /// Shows `newRows`, touching only what changed. Returns whether rows were
    /// added at the end while the user was reading higher up.
    @discardableResult
    func show(_ newRows: [LeituraRow]) -> Bool {
        let old = rows
        let wasAtBottom = isAtBottom
        rows = newRows
        let oldIDs = old.map(\.id)
        let newIDs = newRows.map(\.id)
        let common = zip(oldIDs, newIDs).prefix { $0 == $1 }.count
        if old.isEmpty || newRows.isEmpty {
            table.reloadData()
        } else if common >= oldIDs.count - 2 {
            // The usual case: the last row grew, the live row moved, rows came.
            updateTail(old: old)
        } else if let first = oldIDs.first, let shift = newIDs.firstIndex(of: first), shift > 0 {
            // Older rows came in front of what is shown.
            keepingPosition { table.reloadData() }
            return false
        } else {
            table.reloadData()
        }
        if wasAtBottom { scrollToBottom() }
        return !wasAtBottom && newRows.count > old.count
    }

    private func keepingPosition(_ change: () -> Void) {
        // Keep the row on screen where it is: the document grows above it.
        let before = table.bounds.height
        let offset = scroll.contentView.bounds.origin.y
        change()
        table.layoutSubtreeIfNeeded()
        let grown = table.bounds.height - before
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset + grown))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The same rows with the last ones changed, added or removed.
    private func updateTail(old: [LeituraRow]) {
        let common = zip(old, rows).prefix { $0.0.id == $0.1.id }.count
        let changed = IndexSet((0 ..< common).filter { old[$0] != rows[$0] })
        table.beginUpdates()
        if old.count > common { table.removeRows(at: IndexSet(common ..< old.count), withAnimation: []) }
        if rows.count > common { table.insertRows(at: IndexSet(common ..< rows.count), withAnimation: []) }
        table.endUpdates()
        if !changed.isEmpty {
            noteHeights(changed)
            table.reloadData(forRowIndexes: changed, columnIndexes: [0])
        }
    }

    /// New heights, applied at once. AppKit animates them by default, and a
    /// reading list whose rows glide on every resize or append is not calm.
    private func noteHeights(_ indexes: IndexSet) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            table.noteHeightOfRows(withIndexesChanged: indexes)
        }
    }

    private func rowChanged(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        noteHeights([index])
        table.reloadData(forRowIndexes: [index], columnIndexes: [0])
    }

    /// Repaints find highlights on the rows on screen.
    func refreshHighlights() {
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? LeituraRowView)?.refreshHighlights()
        }
    }

    /// Brings the current match into view.
    func reveal(row id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        table.scrollRowToVisible(index)
        table.layoutSubtreeIfNeeded()
        guard let view = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? LeituraRowView,
              let rect = view.rectOfCurrentMatch() else { return }
        let inTable = table.convert(rect, from: view)
        let visible = scroll.contentView.bounds
        if !visible.insetBy(dx: 0, dy: 40).contains(inTable) {
            let y = max(inTable.midY - visible.height / 2, 0)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, max(table.bounds.height - visible.height, 0))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func scrollToBottom() {
        // The table's own height lags its rows until it tiles.
        table.tile()
        let clip = scroll.contentView
        let bottom = rows.isEmpty ? 0 : table.rect(ofRow: rows.count - 1).maxY
        let y = max(bottom - clip.bounds.height + scroll.contentInsets.bottom, -scroll.contentInsets.top)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        // The rows now in view, made and placed now, not on a later pass.
        table.layoutSubtreeIfNeeded()
        setAtBottom(true)
    }

    /// Shows `id`'s row at the top, and stops following the bottom.
    func scroll(toRow id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        table.tile()
        setAtBottom(false)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(table.rect(ofRow: index).minY - 12, 0)))
        scroll.reflectScrolledClipView(scroll.contentView)
        table.layoutSubtreeIfNeeded()
    }

    /// The live row's clock, if it is on screen.
    func tickLiveRow() {
        guard let index = rows.lastIndex(where: { if case .live = $0 { true } else { false } }),
              let view = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? LiveRowView else { return }
        view.tick()
    }

    // MARK: - Scrolling

    /// Any change of the visible part, the user's or the content's own.
    @objc private func scrolled() {
        if scroll.contentView.bounds.minY < Self.nearTop, !rows.isEmpty { onNearTop?() }
    }

    /// Only the user moving the view decides whether it follows the bottom:
    /// content growing under a still view must not unstick it.
    @objc private func userScrolled() {
        let clip = scroll.contentView.bounds
        setAtBottom(clip.maxY >= table.bounds.height + scroll.contentInsets.bottom - Self.bottomSlack)
    }

    private func setAtBottom(_ value: Bool) {
        guard value != isAtBottom else { return }
        isAtBottom = value
        onBottomChange?(value)
    }

    /// The width rows were last measured at. Checked after layout, when the
    /// table itself has its new width — not when this view is resized, which
    /// is before the table follows.
    private var measuredWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let width = table.bounds.width
        if width != measuredWidth, width > 0 {
            measuredWidth = width
            if !rows.isEmpty { noteHeights(IndexSet(integersIn: 0 ..< rows.count)) }
        }
        // Read at the bottom, it stays there through any change of size.
        if isAtBottom, !rows.isEmpty {
            scroll.layoutSubtreeIfNeeded()
            scrollToBottom()
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 1 }
        let item = rows[row]
        let width = max(tableView.bounds.width, 320)
        return context.height(of: item, width: width, signature: context.signature(of: item)) {
            Self.measure(item, width: width, context: context)
        }
    }

    static func measure(_ row: LeituraRow, width: CGFloat, context: LeituraContext) -> CGFloat {
        switch row {
        case let .item(.user(message)): UserRowView.height(message, width: width)
        case let .item(.answer(answer)): AnswerRowView.height(answer, width: width, context: context)
        case let .item(.activity(activity)): ActivityRowView.height(activity, width: width, context: context)
        case .item(.divider): DividerRowView.height
        case .item(.note): NoteRowView.height
        case .item(.worked): WorkedRowView.height
        case .live: LiveRowView.height
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let (identifier, make): (String, () -> LeituraRowView) = switch item {
        case .item(.user): ("user", { UserRowView() })
        case .item(.answer): ("answer", { AnswerRowView() })
        case .item(.activity): ("activity", { ActivityRowView() })
        case .item(.divider): ("divider", { DividerRowView() })
        case .item(.note): ("note", { NoteRowView() })
        case .item(.worked): ("worked", { WorkedRowView() })
        case .live: ("live", { LiveRowView() })
        }
        let view = (tableView.makeView(withIdentifier: .init(identifier), owner: nil) as? LeituraRowView) ?? {
            let made = make()
            made.identifier = .init(identifier)
            return made
        }()
        view.configure(item, context: context)
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// Tells the list when the user scrolled, as opposed to the content moving.
final class ReadingScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onUserScroll?()
    }
}

/// Reports its own resizing — the moment the visible height is really new —
/// so a list read at its bottom stays there when the composer grows, a
/// banner appears or the window is resized.
final class StickyClipView: NSClipView {
    var onResize: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }
}
