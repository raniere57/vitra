import AppKit
import VitraOrchestrator

/// What a row of the ranking opens: the worker's record cut by kind of task
/// and by difficulty, and a way to put it in the lineup.
final class RankingDetailView: NSView {
    /// Whether the worker is in a tier already; nil while unknown.
    typealias Membership = (Difficulty) -> Bool?

    private static let width: CGFloat = 340
    private enum Column {
        static let uses: CGFloat = 34, score: CGFloat = 30, time: CGFloat = 50, cost: CGFloat = 44, last: CGFloat = 40
    }

    private let breakdown: RankingBreakdown
    private let membership: Membership
    private let onAdd: (Difficulty) -> Void

    init(_ breakdown: RankingBreakdown, now: Date, membership: @escaping Membership, onAdd: @escaping (Difficulty) -> Void) {
        self.breakdown = breakdown
        self.membership = membership
        self.onAdd = onAdd
        super.init(frame: .zero)
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: CockpitStyle.Space.lg, left: CockpitStyle.Space.lg, bottom: CockpitStyle.Space.lg, right: CockpitStyle.Space.lg)
        func add(_ view: NSView, after spacing: CGFloat) {
            if let previous = column.arrangedSubviews.last { column.setCustomSpacing(spacing, after: previous) }
            column.addArrangedSubview(view)
            if !(view is NSButton) {
                view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * CockpitStyle.Space.lg).isActive = true
            }
        }

        let title = NSTextField.label(WorkerPicker.shortName(breakdown.worker), font: CockpitStyle.label, color: CockpitStyle.text)
        title.lineBreakMode = .byTruncatingMiddle
        add(title, after: 0)
        let last = breakdown.overall.lastUsed.map { "usado pela última vez \(WorkerBoard.startedText($0, now: now))" } ?? "nunca usado"
        add(NSTextField.label("\(breakdown.worker.cli.rawValue) · \(last)", font: CockpitStyle.caption, color: CockpitStyle.muted),
            after: CockpitStyle.Space.xs)
        for (caption, lines) in [("POR TIPO", breakdown.kinds), ("POR DIFICULDADE", breakdown.difficulties)] where !lines.isEmpty {
            for (index, view) in table(caption, lines, now: now).enumerated() {
                add(view, after: index == 0 ? CockpitStyle.Space.lg : 0)
            }
        }
        let button = NSButton(title: "Adicionar à escalação…", target: self, action: #selector(showTiers(_:)))
        button.controlSize = .small
        button.bezelStyle = .rounded
        add(button, after: CockpitStyle.Space.lg)
        addFilling(column)
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A titled table: one line per kind or difficulty the worker ran on.
    private func table(_ caption: String, _ lines: [RankingBreakdown.Line], now: Date) -> [NSView] {
        let micro = CockpitStyle.micro
        let heads = RankingView.line([
            RankingView.flexible(caption, font: micro, color: CockpitStyle.text),
            RankingView.cell("USOS", Column.uses, .right, font: micro, color: CockpitStyle.muted),
            RankingView.cell("NOTA", Column.score, .right, font: micro, color: CockpitStyle.muted),
            RankingView.cell("TEMPO", Column.time, .right, font: micro, color: CockpitStyle.muted),
            RankingView.cell("CUSTO", Column.cost, .right, font: micro, color: CockpitStyle.muted),
            RankingView.cell("ÚLTIMA", Column.last, .right, font: micro, color: CockpitStyle.muted),
        ], height: 20)
        let rule = NSView.rule(CockpitStyle.line)
        let heading = NSStackView(views: [heads, rule])
        heading.orientation = .vertical
        heading.spacing = 0
        [heads, rule].forEach { $0.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true }
        return [heading] + lines.map { line in
            let figures = line.figures
            let last = figures.lastUsed.map { WorkerBoard.startedText($0, now: now).components(separatedBy: " ").first ?? "" } ?? "—"
            return RankingView.line([
                RankingView.flexible(line.title, font: CockpitStyle.caption, color: CockpitStyle.text),
                RankingView.cell(figures.usesText, Column.uses, .right, font: CockpitStyle.meta, color: CockpitStyle.text),
                RankingView.cell(figures.scoreText, Column.score, .right, font: CockpitStyle.meta, color: CockpitStyle.text),
                RankingView.cell(figures.timeText, Column.time, .right, font: CockpitStyle.meta, color: CockpitStyle.text),
                RankingView.cell(figures.costText, Column.cost, .right, font: CockpitStyle.meta, color: CockpitStyle.text),
                RankingView.cell(last, Column.last, .right, font: CockpitStyle.meta, color: CockpitStyle.muted),
            ], height: 24)
        }
    }

    /// Difícil, Normal, Fácil; a tier that has the worker already says so
    /// and cannot be chosen.
    @objc private func showTiers(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for level in LineupBoard.tiers {
            let isIn = membership(level)
            let item = MenuAction(title: LineupBoard.title(level) + (isIn == true ? " — já está" : "")) { [onAdd] in onAdd(level) }
            item.isEnabled = isIn == false
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
}
