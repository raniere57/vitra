import AppKit

/// What the right side of a project can show.
enum SideTab: String, CaseIterable {
    case palco, workers, ranking, resumo, browser, files, git, terminal

    var title: String {
        switch self {
        case .palco: return "Palco"
        case .workers: return "Workers"
        case .ranking: return "Ranking"
        case .resumo: return "Resumo"
        case .browser: return "Navegador"
        case .files: return "Arquivos"
        case .git: return "Git"
        case .terminal: return "Terminal"
        }
    }

    /// The tab's picture: eight names do not fit the narrow panel with any
    /// air, so only the selected tab spells its name out.
    var symbol: String {
        switch self {
        case .palco: return "atom"
        case .workers: return "person.2"
        case .ranking: return "list.number"
        case .resumo: return "chart.bar"
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
    static let padding: CGFloat = 10
    /// Where the text really starts, measured from the plate's edge: less than
    /// `padding`, since the button brings a little room of its own.
    static let textOffset: CGFloat = 4

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + 2 * Self.padding, height: 26)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        isBordered = false
        // Picture and name as one centred group: left alone, a button pins the
        // picture to its leading edge and the plate looks lopsided.
        imageHugsTitle = true
        wantsLayer = true
        layer?.cornerRadius = CockpitStyle.Radius.control
        setAccessibilityRole(.radioButton)
    }
}
