import AppKit
import VitraOrchestrator

/// One worker of a ranking table: place, name with its tag, and the five
/// figures in their columns.
///
/// Made once and configured again on every redraw: with "nunca usados" on and
/// a table per kind there are hundreds of rows, and building their labels
/// afresh each time the run feed moves would be most of the cost.
final class RankingRowView: NSView {
    var onClick: ((RankingRowView) -> Void)?
    private(set) var entry: RankingEntry?

    private let rank = RankingView.cell("", RankingView.Column.rank, .left, font: CockpitStyle.meta, color: CockpitStyle.muted)
    private let name = RankingView.flexible("", font: CockpitStyle.label, color: CockpitStyle.text)
    private let note = NSTextField.label("", font: CockpitStyle.ui(10), color: CockpitStyle.muted)
    private let score = RankingView.cell("", RankingView.Column.score, .right, font: CockpitStyle.meta, color: CockpitStyle.text)
    private let time = RankingView.cell("", RankingView.Column.time, .right, font: CockpitStyle.meta, color: CockpitStyle.text)
    private let uses = RankingView.cell("", RankingView.Column.uses, .right, font: CockpitStyle.meta, color: CockpitStyle.text)
    private let deliveries = RankingView.cell("", RankingView.Column.delivered, .right, font: CockpitStyle.meta, color: CockpitStyle.text)
    private let cost = RankingView.cell("", RankingView.Column.cost, .right, font: CockpitStyle.meta, color: CockpitStyle.text)
    /// For a worker never used: "nunca usado" where USOS, ENTREGAS and CUSTO
    /// would be — it has none of them — so its name keeps a used row's room.
    private let never = RankingView.cell("nunca usado", RankingRowView.neverWidth(showsCost: true), .right,
                                         font: CockpitStyle.caption, color: CockpitStyle.muted)
    /// The hairline between two rows of one table, drawn over the row's top
    /// edge so that it adds no height.
    private let rule = NSView.rule(CockpitStyle.softLine)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = CockpitStyle.Radius.control
        name.lineBreakMode = .byTruncatingMiddle
        // The name stays whole as long as it can; the tag gives way first.
        name.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let names = NameAndNote(views: [name, note])
        names.spacing = CockpitStyle.Space.xs
        names.setContentHuggingPriority(.defaultLow, for: .horizontal)
        names.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        never.isHidden = true
        addFilling(RankingView.line([rank, names, score, time, uses, deliveries, cost, never], height: CockpitStyle.rowHeight))
        addSubview(rule)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static func neverWidth(showsCost: Bool) -> CGFloat {
        let column = RankingView.Column.self
        return column.uses + column.gap + column.delivered + (showsCost ? column.gap + column.cost : 0)
    }

    /// - Parameter accentsFirst: whether the first place is drawn in the
    ///   accent: only when the table is ranked by rating, where first means best.
    func configure(_ entry: RankingEntry, accentsFirst: Bool, showsRule: Bool, showsCost: Bool) {
        self.entry = entry
        rule.isHidden = !showsRule
        let isUnused = entry.figures == nil
        uses.isHidden = isUnused
        deliveries.isHidden = isUnused
        cost.isHidden = isUnused || !showsCost
        never.isHidden = !isUnused
        never.constraints.first { $0.firstAttribute == .width }?.constant = Self.neverWidth(showsCost: showsCost)
        rank.stringValue = entry.place.map(String.init) ?? ""
        rank.textColor = entry.place == 1 && accentsFirst ? CockpitStyle.accent : CockpitStyle.muted
        name.stringValue = entry.name
        name.textColor = isUnused || entry.isDemoted ? CockpitStyle.muted : CockpitStyle.text
        note.stringValue = "rebaixado"
        note.isHidden = !entry.isDemoted || isUnused
        let figures = entry.figures
        let colour = isUnused ? CockpitStyle.muted : CockpitStyle.text
        for (label, text) in [
            (score, figures?.scoreText), (time, figures?.timeText), (uses, figures?.usesText),
            (deliveries, figures?.deliveriesText), (cost, figures?.costText),
        ] as [(NSTextField, String?)] {
            label.stringValue = text ?? "—"
            label.textColor = colour
        }
        toolTip = figures.map { "\(entry.worker.name) · \($0.ratingsText)" } ?? "\(entry.worker.name) · nunca usado"
        let place = entry.place.map { "\($0)º, " } ?? ""
        setAccessibilityLabel(figures.map {
            "\(place)\(entry.name): nota \($0.scoreText), tempo \($0.timeText), \($0.uses) usos, entregas \($0.deliveriesText), custo \($0.costText)"
                + (entry.isDemoted ? ", rebaixado" : "")
        } ?? "\(entry.name), nunca usado")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = CockpitStyle.tab.withAlphaComponent(0.5).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    override func mouseUp(with event: NSEvent) { onClick?(self) }
    override func accessibilityPerformPress() -> Bool {
        onClick?(self)
        return true
    }
}

/// A row's name and its tag. A tag cut to "r…" says nothing, so it is shown
/// whole or not at all — checked here, once this stack has placed it, and
/// faded rather than hidden so the name's room does not change with it.
private final class NameAndNote: NSStackView {
    override func layout() {
        super.layout()
        guard let note = arrangedSubviews.last as? NSTextField else { return }
        note.alphaValue = note.frame.width + 0.5 >= note.intrinsicContentSize.width ? 1 : 0
    }
}

/// One table of the ranking: a title that folds it, with its own totals at
/// the right; the column heads, which set the ordering; and its rows.
final class RankingGroupView: NSView {
    var onToggle: ((String) -> Void)?
    var onHead: ((RankingOrder) -> Void)?
    var onRow: ((RankingRowView) -> Void)?

    private var id = ""
    private let toggle = NSButton(title: "", target: nil, action: nil)
    private let totals = NSTextField.label("", font: CockpitStyle.caption, color: CockpitStyle.muted)
    private let heads = RankingHeads()
    private let rows = NSStackView()
    /// Rows made so far; the ones past the table's length are hidden, not
    /// thrown away, and a stack view lays out no hidden view.
    private var pool: [RankingRowView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        toggle.isBordered = false
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        totals.alignment = .right
        let header = NSStackView(views: [toggle, NSView(), totals])
        header.spacing = CockpitStyle.Space.md
        header.alignment = .centerY
        header.heightAnchor.constraint(equalToConstant: 28).isActive = true
        heads.onHead = { [weak self] in self?.onHead?($0) }
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        let stack = NSStackView(views: [header, heads, rows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setCustomSpacing(CockpitStyle.Space.xs, after: header)
        for view in [header, heads, rows] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        addFilling(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ group: RankingGroup, options: RankingOptions, isCollapsed: Bool, showsCost: Bool) {
        id = group.id
        toggle.attributedTitle = NSAttributedString(string: (isCollapsed ? "▸ " : "▾ ") + group.title.uppercased(), attributes: [
            .font: CockpitStyle.micro, .foregroundColor: CockpitStyle.text,
        ])
        toggle.setAccessibilityLabel("\(group.title), \(isCollapsed ? "fechado" : "aberto")")
        totals.stringValue = group.totals
        heads.isHidden = isCollapsed
        rows.isHidden = isCollapsed
        guard !isCollapsed else { return }
        heads.configure(options, showsCost: showsCost)
        while pool.count < group.rows.count {
            let row = RankingRowView()
            row.onClick = { [weak self] in self?.onRow?($0) }
            pool.append(row)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        for (index, row) in pool.enumerated() {
            row.isHidden = index >= group.rows.count
            guard index < group.rows.count else { continue }
            row.configure(group.rows[index], accentsFirst: options.order == .rating && !options.isReversed,
                          showsRule: index > 0, showsCost: showsCost)
        }
    }

    @objc private func toggled() { onToggle?(id) }
}

/// The captions over a table's figures. Each names an ordering: a click
/// ranks by it, a second click turns it around, and the one in force carries
/// a small ▲ or ▼.
final class RankingHeads: NSView {
    var onHead: ((RankingOrder) -> Void)?
    private var labels: [RankingOrder: NSTextField] = [:]

    private static let columns: [(RankingOrder?, String, CGFloat?)] = [
        (nil, "#", RankingView.Column.rank), (.name, "MODELO", nil), (.rating, "NOTA", RankingView.Column.score),
        (.time, "TEMPO", RankingView.Column.time), (.uses, "USOS", RankingView.Column.uses),
        (.deliveries, "ENTREGAS", RankingView.Column.delivered), (.cost, "CUSTO", RankingView.Column.cost),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        let views = Self.columns.map { order, title, width -> NSView in
            let label = width.map { RankingView.cell(title, $0, order == nil ? .left : .right, font: CockpitStyle.micro, color: CockpitStyle.muted) }
                ?? RankingView.flexible(title, font: CockpitStyle.micro, color: CockpitStyle.muted)
            if let order {
                labels[order] = label
                label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked(_:))))
                label.setAccessibilityRole(.button)
                label.setAccessibilityLabel("Ordenar por \(order.title.lowercased())")
            }
            return label
        }
        let heads = RankingView.line(views, height: 20)
        let rule = NSView.rule(CockpitStyle.line)
        let stack = NSStackView(views: [heads, rule])
        stack.orientation = .vertical
        stack.spacing = 0
        heads.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addFilling(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ options: RankingOptions, showsCost: Bool) {
        labels[.cost]?.isHidden = !showsCost
        for (order, label) in labels {
            let title = Self.columns.first { $0.0 == order }?.1 ?? ""
            let isActive = order == options.order
            let text = NSMutableAttributedString()
            if isActive {
                // Before the caption: the figures are right-aligned, and an
                // arrow after them would push the caption off its column.
                text.append(NSAttributedString(string: (options.isAscending ? "▲" : "▼") + "\u{2009}", attributes: [
                    .font: CockpitStyle.ui(7), .foregroundColor: CockpitStyle.accent, .baselineOffset: 1,
                ]))
            }
            text.append(NSAttributedString(string: title, attributes: [
                .font: CockpitStyle.micro, .foregroundColor: isActive ? CockpitStyle.text : CockpitStyle.muted,
            ]))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = order == .name ? .left : .right
            paragraph.lineBreakMode = .byClipping
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            label.attributedStringValue = text
            label.setAccessibilityValue(isActive ? (options.isAscending ? "crescente" : "decrescente") : nil)
        }
    }

    override func resetCursorRects() {
        for label in labels.values where !label.isHidden { addCursorRect(convert(label.bounds, from: label), cursor: .pointingHand) }
    }

    @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
        guard let order = labels.first(where: { $0.value === recognizer.view })?.key else { return }
        onHead?(order)
    }
}
