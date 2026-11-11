import AppKit

/// What the right side of a project can show.
enum SideTab: String, CaseIterable {
    case palco, workers, ranking, browser, files, git, terminal

    var title: String {
        switch self {
        case .palco: return "Palco"
        case .workers: return "Workers"
        case .ranking: return "Ranking"
        case .browser: return "Navegador"
        case .files: return "Arquivos"
        case .git: return "Git"
        case .terminal: return "Terminal"
        }
    }

    /// The tab's picture: seven names do not fit the narrow panel with any
    /// air, so only the selected tab spells its name out.
    var symbol: String {
        switch self {
        case .palco: return "atom"
        case .workers: return "person.2"
        case .ranking: return "list.number"
        case .browser: return "globe"
        case .files: return "folder"
        case .git: return "arrow.triangle.branch"
        case .terminal: return "terminal"
        }
    }

    /// A page or a file needs room to be read; a list does not.
    var isWide: Bool { self == .browser || self == .files || self == .terminal }
}

/// The row of tabs at the top of a project's right side.
final class SideTabs: NSView {
    var onSelect: ((SideTab) -> Void)?
    private(set) var selected = SideTab.workers

    private var buttons: [SideTab: TabButton] = [:]
    private var titles: [SideTab: String] = [:]
    /// Holds the unselected tabs to one width; remade when the selection moves.
    private var evenWidths: [NSLayoutConstraint] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        let stack = NSStackView()
        stack.spacing = CockpitStyle.Space.xs
        // The first tab's text, not its plate, sits on the content inset, so
        // it lines up with what is below it.
        stack.edgeInsets = NSEdgeInsets(top: 0, left: CockpitStyle.inset - TabButton.textOffset, bottom: 0, right: CockpitStyle.inset - TabButton.textOffset)
        // The tabs share the whole row: the selected one takes what its name
        // needs and the rest split what is left evenly, so each is a wide
        // target instead of an icon packed against its neighbours.
        stack.distribution = .fill
        for tab in SideTab.allCases {
            let button = TabButton(title: tab.title, target: self, action: #selector(pressed(_:)))
            button.tag = SideTab.allCases.firstIndex(of: tab) ?? 0
            buttons[tab] = button
            stack.addArrangedSubview(button)
        }
        addFilling(stack)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func select(_ tab: SideTab) {
        selected = tab
        paint()
    }

    /// Renames a tab, for the count of running workers beside "Workers".
    func setTitle(_ title: String, for tab: SideTab) {
        guard titles[tab] != title else { return }
        titles[tab] = title
        paint()
    }

    @objc private func pressed(_ sender: NSButton) {
        onSelect?(SideTab.allCases[sender.tag])
    }

    private func paint() {
        for (tab, button) in buttons {
            let isSelected = tab == selected
            let title = titles[tab] ?? tab.title
            // Selected: the picture and the name. Otherwise the picture alone,
            // with whatever count the name carries ("Workers · 2" → "2").
            let count = title.components(separatedBy: " · ").dropFirst().last
            let shown = isSelected ? title : (count ?? "")
            let colour = isSelected ? CockpitStyle.text : CockpitStyle.muted
            button.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: isSelected ? .semibold : .regular))
            button.contentTintColor = colour
            button.imagePosition = shown.isEmpty ? .imageOnly : .imageLeading
            button.attributedTitle = NSAttributedString(string: shown.isEmpty ? "" : " " + shown, attributes: [
                .font: isSelected ? CockpitStyle.ui(12, .semibold) : CockpitStyle.meta,
                .foregroundColor: colour,
            ])
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.layer?.backgroundColor = (isSelected ? CockpitStyle.tab : .clear).cgColor
            button.setAccessibilityValue(isSelected ? "selecionada" : nil)
            // The selected tab keeps to its content; the others stretch.
            button.setContentHuggingPriority(isSelected ? .required : .defaultLow, for: .horizontal)
            button.setContentCompressionResistancePriority(isSelected ? .required : .defaultHigh, for: .horizontal)
        }
        NSLayoutConstraint.deactivate(evenWidths)
        let others = SideTab.allCases.filter { $0 != selected }.compactMap { buttons[$0] }
        evenWidths = others.dropFirst().compactMap { button in
            others.first.map { button.widthAnchor.constraint(equalTo: $0.widthAnchor) }
        }
        NSLayoutConstraint.activate(evenWidths)
    }
}

/// A tab: text on a pill that is filled when the tab is the one shown.
private final class TabButton: NSButton {
    /// Room between the pill's edge and its text, on each side.
    static let padding: CGFloat = 6
    /// Where the text really starts, measured from the plate's edge: less than
    /// `padding`, since the button brings a little room of its own.
    static let textOffset: CGFloat = 4

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + 2 * Self.padding, height: 26)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = CockpitStyle.Radius.control
        setAccessibilityRole(.radioButton)
    }
}

/// The Ranking tab: for each kind of task, a compact table — one 30 pt row per
/// worker, best first — under a micro caps title and one row of column heads.
final class RankingView: NSView {
    /// Fixed widths of the figure columns, so that they line up from row to row
    /// and from section to section. What is left goes to the name.
    enum Column {
        static let rank: CGFloat = 16
        static let score: CGFloat = 32
        static let time: CGFloat = 50
        static let deliveries: CGFloat = 50
        static let cost: CGFloat = 46
        static let gap = CockpitStyle.Space.sm
    }

    private let column = NSStackView()
    /// The user's lineup, above the record; it loads and saves itself.
    private let lineup: LineupSectionView

    init(lineup: LineupSectionView = LineupSectionView()) {
        self.lineup = lineup
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.panel.cgColor
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: CockpitStyle.Space.lg, left: CockpitStyle.inset, bottom: CockpitStyle.Space.xl, right: CockpitStyle.inset)
        column.translatesAutoresizingMaskIntoConstraints = false

        let document = TopDownView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        addFilling(scroll)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ rows: [RankingRow]) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        add(lineup)
        column.setCustomSpacing(CockpitStyle.Space.xxl, after: lineup)
        lineup.reload()
        if rows.isEmpty {
            let title = NSTextField.label("Ainda não há entregas para comparar", font: CockpitStyle.title, color: CockpitStyle.text)
            column.addArrangedSubview(title)
            let body = NSTextField(wrappingLabelWithString: "O maestro dá uma nota de 1 a 5 a cada entrega que revisa. Com as notas e os tempos, o ranking aparece aqui, e quem fica para trás desce na sua escalação.")
            body.font = CockpitStyle.body
            body.textColor = CockpitStyle.muted
            column.addArrangedSubview(body)
            column.setCustomSpacing(CockpitStyle.Space.md, after: title)
            body.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * CockpitStyle.inset).isActive = true
            return
        }

        var section = ""
        var place = 0
        var previous: NSView?
        var isFirstOfSection = true
        for row in rows {
            if row.kind != section {
                section = row.kind
                place = 0
                isFirstOfSection = true
                if let previous { column.setCustomSpacing(CockpitStyle.Space.xl, after: previous) }
                let heading = NSTextField.label(section.uppercased(), font: CockpitStyle.micro, color: CockpitStyle.text)
                column.addArrangedSubview(heading)
                column.setCustomSpacing(CockpitStyle.Space.md, after: heading)
                add(Self.headerRow())
            }
            if !isFirstOfSection {
                // The hairline between two rows of one section.
                let rule = NSView.rule(CockpitStyle.softLine)
                add(rule)
            }
            isFirstOfSection = false
            place += 1
            let view = Self.tableRow(row, place: place)
            add(view)
            previous = view
        }
    }

    private func add(_ view: NSView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * CockpitStyle.inset).isActive = true
    }

    /// The small row of captions over one section's figures, with a hairline
    /// under it.
    private static func headerRow() -> NSView {
        let heads = line([
            cell("#", Column.rank, .left, font: CockpitStyle.micro, color: CockpitStyle.muted),
            flexible("MODELO", font: CockpitStyle.micro, color: CockpitStyle.muted),
            cell("NOTA", Column.score, .right, font: CockpitStyle.micro, color: CockpitStyle.muted),
            cell("TEMPO", Column.time, .right, font: CockpitStyle.micro, color: CockpitStyle.muted),
            cell("ENTREGAS", Column.deliveries, .right, font: CockpitStyle.micro, color: CockpitStyle.muted),
            cell("CUSTO", Column.cost, .right, font: CockpitStyle.micro, color: CockpitStyle.muted),
        ], height: 20)
        let rule = NSView.rule(CockpitStyle.line)
        let stack = NSStackView(views: [heads, rule])
        stack.orientation = .vertical
        stack.spacing = 0
        heads.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// One worker: place, name, and the four figures in their columns.
    private static func tableRow(_ row: RankingRow, place: Int) -> NSView {
        let name = flexible(row.model, font: CockpitStyle.label, color: CockpitStyle.text)
        name.lineBreakMode = .byTruncatingMiddle
        let view = line([
            cell("\(place)", Column.rank, .left, font: CockpitStyle.meta, color: place == 1 ? CockpitStyle.accent : CockpitStyle.muted),
            name,
            cell(row.score, Column.score, .right, font: CockpitStyle.meta, color: CockpitStyle.text),
            cell(row.time, Column.time, .right, font: CockpitStyle.meta, color: CockpitStyle.text),
            cell(row.deliveries, Column.deliveries, .right, font: CockpitStyle.meta, color: CockpitStyle.text),
            cell(row.cost, Column.cost, .right, font: CockpitStyle.meta, color: CockpitStyle.text),
        ], height: CockpitStyle.rowHeight)
        view.toolTip = "\(row.model) · \(row.ratings)"
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("\(place)º, \(row.model): nota \(row.score), tempo \(row.time), entregas \(row.deliveries), custo \(row.cost), \(row.ratings)")
        return view
    }

    static func line(_ views: [NSView], height: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = Column.gap
        stack.alignment = .centerY
        // The name, which hugs least, takes what the fixed columns leave.
        stack.distribution = .fill
        stack.heightAnchor.constraint(equalToConstant: height).isActive = true
        return stack
    }

    /// A label of fixed width: a column.
    static func cell(_ text: String, _ width: CGFloat, _ alignment: NSTextAlignment, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField.label(text, font: font, color: color)
        label.alignment = alignment
        label.lineBreakMode = .byClipping
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    /// The column that takes what the fixed ones leave, and gives way first.
    static func flexible(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField.label(text, font: font, color: color)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }
}
