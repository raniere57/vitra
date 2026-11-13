import AppKit

extension UISnapshot {
    /// The first-run guide, under an empty tab bar, as the window shows it
    /// with no project.
    static func welcome(_ context: Context) -> NSView {
        let bar = CockpitTabBar()
        bar.show([], selected: 0)
        let guide = WelcomeView(target: nil, action: #selector(CockpitWindowController.openProject(_:)))
        let window = NSView()
        for view in [bar, guide] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: window.topAnchor),
            bar.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: CockpitStyle.barHeight),
            guide.topAnchor.constraint(equalTo: bar.bottomAnchor),
            guide.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            guide.bottomAnchor.constraint(equalTo: window.bottomAnchor),
        ])
        return window
    }

    /// The shortcuts sheet at the size it opens at.
    static var shortcutsSize: NSSize {
        let view = ShortcutsSheet.makeView {}
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
    }

    /// ⌘F over the maestro: the bar, the counter, and the matches painted
    /// the way the terminal paints them, over a stand-in conversation that the
    /// real search has been run on.
    static func find(_ context: Context) throws -> NSView {
        let conversation = FakeConversation(lines: findLines, query: "relatorio", current: 1)
        return try cockpit(context, terminal: conversation) { project in
            project.showFindBar(query: "relatorio", counter: ConversationFind.counter(current: 1, total: conversation.matchCount, hasQuery: true) ?? "")
        }
    }

    private static let findLines = [
        "❯ gere o relatório semanal e compare com o da semana passada",
        "",
        "⏺ Vou delegar a coleta dos números e escrever o Relatório eu mesmo.",
        "  ⎿ vitra delegate — worker sonnet: \"levantar métricas de uso\"",
        "  ⎿ vitra delegate — worker gemini: \"resumir os incidentes\"",
        "",
        "⏺ Os dois workers entregaram. Juntei tudo em docs/relatorio-semana-45.md,",
        "  com uma tabela comparando as duas semanas e três pontos de atenção.",
        "",
        "❯ manda o RELATORIO para revisão",
    ]
}

/// A terminal's text drawn with AppKit, for the snapshot only: the Metal
/// terminal cannot draw offscreen. The matches are found by the real
/// `ConversationSearch`, and painted with the terminal's own colours and
/// geometry: one cell per column, the current match solid.
private final class FakeConversation: NSView {
    private let lines: [String]
    private let query: String
    private let current: Int
    private let font = CockpitStyle.mono(13)
    private let padding: CGFloat = 12

    init(lines: [String], query: String, current: Int) {
        self.lines = lines
        self.query = query
        self.current = current
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var cell: NSSize {
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: width, height: ceil(font.ascender - font.descender + font.leading) + 3)
    }

    var matchCount: Int { matches.count }

    private var matches: [ConversationSearch.Match] {
        let columns = Int((max(bounds.width, 600) - 2 * padding) / cell.width)
        return ConversationSearch.matches(of: query, in: lines.map { ConversationSearch.Row(text: $0, wraps: $0.count >= columns) }) ?? []
    }

    override func draw(_ dirtyRect: NSRect) {
        CockpitStyle.panel.setFill()
        bounds.fill()
        let cell = self.cell
        for (index, match) in matches.enumerated() {
            for span in match.spans {
                let rect = NSRect(
                    x: padding + CGFloat(span.columns.lowerBound) * cell.width - 1,
                    y: padding + CGFloat(span.row) * cell.height,
                    width: CGFloat(span.columns.count) * cell.width + 2,
                    height: cell.height
                )
                let isCurrent = index == current
                let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                CockpitStyle.accent.withAlphaComponent(isCurrent ? 0.42 : 0.16).setFill()
                path.fill()
                CockpitStyle.accent.withAlphaComponent(isCurrent ? 1 : 0.35).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        for (row, line) in lines.enumerated() {
            var column = 0
            for character in line {
                let colour = line.hasPrefix("❯") ? CockpitStyle.text : (line.hasPrefix("  ⎿") ? CockpitStyle.muted : CockpitStyle.code)
                (String(character) as NSString).draw(
                    at: NSPoint(x: padding + CGFloat(column) * cell.width, y: padding + CGFloat(row) * cell.height + 1),
                    withAttributes: [.font: font, .foregroundColor: colour]
                )
                column += ConversationSearch.width(of: character)
            }
        }
    }
}
