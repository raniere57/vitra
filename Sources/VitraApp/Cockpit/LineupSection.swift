import AppKit
import VitraOrchestrator

/// The Escalação, above the ranking: the user's ordered workers for hard,
/// normal and easy pieces. Rows are reordered by dragging or with ⌥↑/⌥↓ on
/// the selected one, removed with the × that shows on hover, and added from
/// the "+" menu. Every change is written to the lineup file at once, and the
/// next spawn picks from it.
final class LineupSectionView: NSView {
    typealias Loader = (@escaping @MainActor @Sendable (LineupData) -> Void) -> Void

    private let file: URL
    private let loader: Loader
    private let column = NSStackView()
    private var data: LineupData?
    private var collapsed: Set<Difficulty> = []
    private var selected: (tier: Difficulty, index: Int)?
    private let status = NSTextField.label("", font: CockpitStyle.caption, color: CockpitStyle.dangerText)

    init(file: URL = Lineup.defaultURL, loader: @escaping Loader = LineupSectionView.loadFromDisk) {
        self.file = file
        self.loader = loader
        super.init(frame: .zero)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        addFilling(column)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    /// Reads the lineup, the record and the catalogue off the main thread,
    /// then draws.
    func reload() {
        loader { [weak self] data in
            self?.data = data
            self?.rebuild()
        }
    }

    /// The real sources: `~/.vitra/lineup.json`, the runs, and the cached
    /// catalogue, which can take seconds to list the first time.
    nonisolated static func loadFromDisk(_ done: @escaping @MainActor @Sendable (LineupData) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let executables = Executables.discover()
            let data = LineupData(
                lineup: Lineup.load(),
                history: Orchestrator(executables: executables).recent(limit: 2000),
                offers: ModelCatalog.offers(ModelCatalog.cachedListing(executables))
            )
            DispatchQueue.main.async { MainActor.assumeIsolated { done(data) } }
        }
    }

    // MARK: Drawing

    private func rebuild() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let data else { return }
        let heading = NSTextField.label("ESCALAÇÃO", font: CockpitStyle.micro, color: CockpitStyle.text)
        column.addArrangedSubview(heading)
        column.setCustomSpacing(CockpitStyle.Space.md, after: heading)
        add(columnHeads())
        for difficulty in LineupBoard.tiers {
            let tier = data.lineup.tier(difficulty)
            let header = tierHeader(difficulty, tier: tier, offers: data.offers)
            add(header)
            guard !collapsed.contains(difficulty) else { continue }
            let rows = LineupBoard.rows(tier, difficulty: difficulty, history: data.history)
            let list = TierList(difficulty: difficulty) { [weak self] from, to in self?.move(difficulty, from: from, to: to) }
            for (index, row) in rows.enumerated() {
                if index > 0 { list.addRow(NSView.rule(CockpitStyle.softLine)) }
                list.addRow(rowView(row, place: index + 1, difficulty: difficulty))
            }
            if rows.isEmpty {
                list.addRow(RankingView.line([
                    RankingView.cell("", RankingView.Column.rank, .left, font: CockpitStyle.meta, color: CockpitStyle.muted),
                    RankingView.flexible("vazia: a Vitra escolhe pelo histórico", font: CockpitStyle.caption, color: CockpitStyle.muted),
                ], height: CockpitStyle.rowHeight))
            }
            add(list)
            column.setCustomSpacing(CockpitStyle.Space.md, after: list)
        }
        if !status.stringValue.isEmpty { add(status) }
    }

    private func add(_ view: NSView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    /// The captions over the figures, in the ranking's columns.
    private func columnHeads() -> NSView {
        let micro = CockpitStyle.micro
        let heads = RankingView.line([
            RankingView.cell("#", RankingView.Column.rank, .left, font: micro, color: CockpitStyle.muted),
            RankingView.flexible("MODELO", font: micro, color: CockpitStyle.muted),
            RankingView.cell("NOTA", RankingView.Column.score, .right, font: micro, color: CockpitStyle.muted),
            RankingView.cell("TEMPO", RankingView.Column.time, .right, font: micro, color: CockpitStyle.muted),
            RankingView.cell("", Self.trailingWidth, .right, font: micro, color: CockpitStyle.muted),
        ], height: 20)
        let rule = NSView.rule(CockpitStyle.line)
        let stack = NSStackView(views: [heads, rule])
        stack.orientation = .vertical
        stack.spacing = 0
        heads.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// What the ranking's ENTREGAS and CUSTO take, so NOTA and TEMPO line up
    /// with the table below; the × sits at its right end.
    static let trailingWidth = RankingView.Column.deliveries + RankingView.Column.gap + RankingView.Column.cost

    private func tierHeader(_ difficulty: Difficulty, tier: [ModelCatalog.Offer], offers: [ModelCatalog.Offer]) -> NSView {
        let isOpen = !collapsed.contains(difficulty)
        let toggle = LinkButton(
            title: (isOpen ? "▾ " : "▸ ") + LineupBoard.title(difficulty), font: CockpitStyle.label, color: CockpitStyle.text
        ) { [weak self] in self?.toggle(difficulty) }
        toggle.setAccessibilityLabel("\(LineupBoard.title(difficulty)), \(isOpen ? "aberta" : "fechada")")
        var views: [NSView] = [toggle, NSView()]
        if tier != Lineup.standard.tier(difficulty) {
            views.append(LinkButton(title: "restaurar padrão", font: CockpitStyle.caption, color: CockpitStyle.muted) { [weak self] in
                self?.save(difficulty, Lineup.standard.tier(difficulty))
            })
        }
        let addable = LineupBoard.addable(offers, to: tier)
        let plus = LinkButton(title: "+", font: CockpitStyle.ui(14, .medium), color: addable.isEmpty ? CockpitStyle.muted : CockpitStyle.accent) {}
        plus.onPress = { [weak self, weak plus] in
            guard let self, let plus else { return }
            self.showAddMenu(difficulty, addable: addable, from: plus)
        }
        plus.isEnabled = !addable.isEmpty
        plus.toolTip = addable.isEmpty ? "Todos os workers do catálogo já estão aqui" : "Adicionar um worker"
        plus.setAccessibilityLabel("Adicionar worker à escalação \(LineupBoard.title(difficulty))")
        views.append(plus)
        let stack = NSStackView(views: views)
        stack.spacing = CockpitStyle.Space.md
        stack.alignment = .centerY
        stack.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return stack
    }

    private func rowView(_ row: LineupRow, place: Int, difficulty: Difficulty) -> NSView {
        let isSelected = selected.map { $0.tier == difficulty && $0.index == place - 1 } ?? false
        let view = LineupRowView(
            row: row, place: place, difficulty: difficulty, isSelected: isSelected,
            onSelect: { [weak self] in self?.select(difficulty, place - 1) },
            onRemove: { [weak self] in self?.remove(difficulty, at: place - 1) }
        )
        return view
    }

    // MARK: Editing

    private func toggle(_ difficulty: Difficulty) {
        if collapsed.contains(difficulty) { collapsed.remove(difficulty) } else { collapsed.insert(difficulty) }
        rebuild()
    }

    private func select(_ difficulty: Difficulty, _ index: Int) {
        selected = (difficulty, index)
        window?.makeFirstResponder(self)
        rebuild()
    }

    private func move(_ difficulty: Difficulty, from: Int, to: Int) {
        guard let tier = data?.lineup.tier(difficulty) else { return }
        let moved = LineupBoard.moved(tier, from: from, to: to)
        if let index = moved.firstIndex(of: tier[from]) { selected = (difficulty, index) }
        save(difficulty, moved)
    }

    private func remove(_ difficulty: Difficulty, at index: Int) {
        guard var tier = data?.lineup.tier(difficulty), tier.indices.contains(index) else { return }
        tier.remove(at: index)
        selected = nil
        save(difficulty, tier)
    }

    private func showAddMenu(_ difficulty: Difficulty, addable: [ModelCatalog.Offer], from button: NSView) {
        let menu = NSMenu()
        for worker in addable {
            let item = MenuAction(title: worker.name) { [weak self] in
                guard let tier = self?.data?.lineup.tier(difficulty) else { return }
                self?.save(difficulty, tier + [worker])
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// Writes the tier at once; the picker reads the same file on the next spawn.
    private func save(_ difficulty: Difficulty, _ tier: [ModelCatalog.Offer]) {
        guard let data else { return }
        let lineup = data.lineup.with(difficulty, tier)
        do {
            try lineup.save(to: file)
            status.stringValue = ""
            self.data = LineupData(lineup: lineup, history: data.history, offers: data.offers)
        } catch {
            status.stringValue = "Não foi possível salvar a escalação: \(error.localizedDescription)"
        }
        rebuild()
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.option), let selected, let tier = data?.lineup.tier(selected.tier) else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 126 where selected.index > 0: // ↑
            move(selected.tier, from: selected.index, to: selected.index - 1)
        case 125 where selected.index < tier.count - 1: // ↓
            move(selected.tier, from: selected.index, to: selected.index + 2)
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Rows

private let lineupDragType = NSPasteboard.PasteboardType("com.vitra.lineup-row")

/// One worker of a tier: place, name with its demotion tag, nota and tempo
/// in the ranking's columns, and a × on hover.
private final class LineupRowView: NSView, NSDraggingSource {
    let difficulty: Difficulty
    let index: Int
    private let onSelect: () -> Void
    private let remove: LinkButton
    private let isSelected: Bool
    private var dragStart: NSPoint?

    init(row: LineupRow, place: Int, difficulty: Difficulty, isSelected: Bool,
         onSelect: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.difficulty = difficulty
        self.index = place - 1
        self.onSelect = onSelect
        self.isSelected = isSelected
        remove = LinkButton(title: "×", font: CockpitStyle.ui(13), color: CockpitStyle.muted, action: onRemove)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CockpitStyle.Radius.control
        layer?.backgroundColor = isSelected ? CockpitStyle.raised.cgColor : nil

        let name = RankingView.flexible(row.name, font: CockpitStyle.label, color: row.demotion == nil ? CockpitStyle.text : CockpitStyle.muted)
        name.lineBreakMode = .byTruncatingMiddle
        // The name stays whole; the tag gives way first.
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        var nameViews: [NSView] = [name]
        if let demotion = row.demotion {
            let tag = NSTextField.label(demotion, font: CockpitStyle.ui(10), color: CockpitStyle.muted)
            tag.toolTip = demotion
            tag.lineBreakMode = .byTruncatingTail
            tag.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            nameViews.append(tag)
        }
        let names = NSStackView(views: nameViews)
        names.spacing = CockpitStyle.Space.xs
        names.setContentHuggingPriority(.defaultLow, for: .horizontal)
        names.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        remove.isHidden = !isSelected
        remove.toolTip = "Tirar da escalação"
        remove.setAccessibilityLabel("Tirar \(row.name) da escalação")
        let trailing = NSStackView(views: [NSView(), remove])
        trailing.widthAnchor.constraint(equalToConstant: LineupSectionView.trailingWidth).isActive = true

        let first = place == 1 && row.demotion == nil
        let line = RankingView.line([
            RankingView.cell("\(place)", RankingView.Column.rank, .left, font: CockpitStyle.meta, color: first ? CockpitStyle.accent : CockpitStyle.muted),
            names,
            RankingView.cell(row.score, RankingView.Column.score, .right, font: CockpitStyle.meta, color: CockpitStyle.text),
            RankingView.cell(row.time, RankingView.Column.time, .right, font: CockpitStyle.meta, color: CockpitStyle.text),
            trailing,
        ], height: CockpitStyle.rowHeight)
        addFilling(line)
        toolTip = "\(row.worker.name) — arraste para reordenar, ou selecione e use ⌥↑ ⌥↓"
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel("\(place)º, \(row.name): nota \(row.score), tempo \(row.time)" + (row.demotion.map { ", \($0)" } ?? ""))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        remove.isHidden = false
        if !isSelected { layer?.backgroundColor = CockpitStyle.tab.withAlphaComponent(0.5).cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        remove.isHidden = !isSelected
        if !isSelected { layer?.backgroundColor = nil }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        dragStart = nil
        let item = NSPasteboardItem()
        item.setString("\(difficulty.rawValue):\(index)", forType: lineupDragType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { onSelect() }
        dragStart = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    private func snapshot() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A tier's rows, which takes drops of its own rows and shows where one lands.
private final class TierList: NSStackView {
    let difficulty: Difficulty
    private let onMove: (Int, Int) -> Void
    private let marker = NSView.filled(CockpitStyle.accent, cornerRadius: 1)

    init(difficulty: Difficulty, onMove: @escaping (Int, Int) -> Void) {
        self.difficulty = difficulty
        self.onMove = onMove
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        registerForDraggedTypes([lineupDragType])
        marker.isHidden = true
        marker.translatesAutoresizingMaskIntoConstraints = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func addRow(_ view: NSView) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private var rows: [LineupRowView] { arrangedSubviews.compactMap { $0 as? LineupRowView } }

    /// The index the dragged row would land at: before the first row whose
    /// middle is below the pointer.
    private func target(_ info: NSDraggingInfo) -> Int {
        let point = convert(info.draggingLocation, from: nil)
        let rows = rows
        let below = rows.firstIndex { row in
            let middle = row.frame.midY
            return isFlipped ? point.y < middle : point.y > middle
        }
        return below ?? rows.count
    }

    private func source(_ info: NSDraggingInfo) -> Int? {
        guard let text = info.draggingPasteboard.string(forType: lineupDragType) else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 2, parts[0] == Substring(difficulty.rawValue) else { return nil }
        return Int(parts[1])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard source(sender) != nil else { return [] }
        let rows = rows
        let index = target(sender)
        let y: CGFloat
        if index < rows.count {
            y = isFlipped ? rows[index].frame.minY : rows[index].frame.maxY
        } else {
            y = rows.last.map { isFlipped ? $0.frame.maxY : $0.frame.minY } ?? 0
        }
        if marker.superview == nil { addSubview(marker) }
        marker.frame = NSRect(x: 0, y: y - 1, width: bounds.width, height: 2)
        marker.isHidden = false
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { marker.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        marker.isHidden = true
        guard let from = source(sender) else { return false }
        onMove(from, target(sender))
        return true
    }
}

// MARK: - Small controls

/// Text that acts: the tier's toggle, "restaurar padrão", "+", "×".
private final class LinkButton: NSButton {
    var onPress: (() -> Void)?

    init(title: String, font: NSFont, color: NSColor, action: @escaping () -> Void) {
        onPress = action
        super.init(frame: .zero)
        isBordered = false
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        target = self
        self.action = #selector(pressed)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    @objc private func pressed() { onPress?() }
}

/// A menu item that runs a closure.
private final class MenuAction: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}
