import AppKit

/// What the right side of a project can show.
enum SideTab: String, CaseIterable {
    case workers, ranking, browser, files, git, terminal

    var title: String {
        switch self {
        case .workers: return "Workers"
        case .ranking: return "Ranking"
        case .browser: return "Navegador"
        case .files: return "Arquivos"
        case .git: return "Git"
        case .terminal: return "Terminal"
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        let stack = NSStackView()
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        for tab in SideTab.allCases {
            let button = TabButton(title: tab.title, target: self, action: #selector(pressed(_:)))
            button.tag = SideTab.allCases.firstIndex(of: tab) ?? 0
            buttons[tab] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(NSView())
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
            button.attributedTitle = NSAttributedString(string: titles[tab] ?? tab.title, attributes: [
                .font: CockpitStyle.ui(12, isSelected ? .semibold : .medium),
                .foregroundColor: isSelected ? CockpitStyle.text : CockpitStyle.muted,
            ])
            button.layer?.backgroundColor = (isSelected ? CockpitStyle.tab : .clear).cgColor
            button.setAccessibilityValue(isSelected ? "selecionada" : nil)
        }
    }
}

/// A tab: text on a pill that is filled when the tab is the one shown.
private final class TabButton: NSButton {
    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + 14, height: 26)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        setAccessibilityRole(.radioButton)
    }
}

/// The Ranking tab: one section per kind of task, best worker first.
final class RankingView: NSView {
    private let column = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.panel.cgColor
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
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
        if rows.isEmpty {
            column.addArrangedSubview(NSTextField.label("Ainda não há entregas para comparar", font: CockpitStyle.ui(13, .medium), color: CockpitStyle.text))
            let body = NSTextField(wrappingLabelWithString: "O maestro dá uma nota de 1 a 5 a cada entrega que revisa. Com as notas e os tempos, o ranking aparece aqui e ele passa a escolher o operário por ele.")
            body.font = CockpitStyle.ui(12)
            body.textColor = CockpitStyle.muted
            column.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36).isActive = true
        }
        var section = ""
        var place = 0
        for row in rows {
            if row.kind != section {
                section = row.kind
                place = 0
                let heading = NSTextField.label(section.uppercased(), font: CockpitStyle.mono(10.5, .medium), color: CockpitStyle.muted)
                column.addArrangedSubview(heading)
                column.setCustomSpacing(8, after: heading)
            }
            place += 1
            let card = card(row, place: place)
            column.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36).isActive = true
        }
    }

    /// One worker: its place and name on top, and under them four figures of
    /// equal width — rating, time, deliveries, cost — each over its caption.
    private func card(_ row: RankingRow, place: Int) -> NSView {
        let number = NSTextField.label("\(place)", font: CockpitStyle.mono(11, .medium), color: place == 1 ? CockpitStyle.accent : CockpitStyle.muted)
        let model = NSTextField.label(row.model, font: CockpitStyle.ui(13, .semibold), color: CockpitStyle.text)
        let ratings = NSTextField.label(row.ratings, font: CockpitStyle.mono(10.5), color: CockpitStyle.muted)
        ratings.setContentCompressionResistancePriority(.required, for: .horizontal)
        let head = NSStackView(views: [number, model, NSView(), ratings])
        head.spacing = 8

        let figures = NSStackView(views: [
            figure(row.score, "nota", color: CockpitStyle.accent),
            figure(row.time, "tempo"),
            figure(row.deliveries, "entregas"),
            figure(row.cost, "custo"),
        ])
        figures.distribution = .fillEqually
        figures.spacing = 8

        let stack = NSStackView(views: [head, NSView.rule(CockpitStyle.raisedLine), figures])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView.filled(CockpitStyle.raised, cornerRadius: 10)
        card.layer?.borderWidth = 1
        card.layer?.borderColor = CockpitStyle.raisedLine.cgColor
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            figures.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.arrangedSubviews[1].widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        card.setAccessibilityElement(true)
        card.setAccessibilityLabel("\(place)º, \(row.model): nota \(row.score), tempo \(row.time), entregas \(row.deliveries), custo \(row.cost), \(row.ratings)")
        return card
    }

    private func figure(_ value: String, _ caption: String, color: NSColor = CockpitStyle.text) -> NSView {
        let value = NSTextField.label(value, font: CockpitStyle.mono(15, .medium), color: color)
        let caption = NSTextField.label(caption, font: CockpitStyle.ui(10.5), color: CockpitStyle.muted)
        let stack = NSStackView(views: [value, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }
}
