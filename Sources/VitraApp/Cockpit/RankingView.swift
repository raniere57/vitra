import AppKit
import os
import VitraOrchestrator

/// What the Ranking tab is drawn from, read off the main thread in one go:
/// the lineup and the history serve the Escalação too.
struct RankingData: Sendable {
    let lineup: Lineup
    let history: [Run]
    /// The catalogue's workers, or nil while the CLIs are still being listed.
    let offers: [ModelCatalog.Offer]?
    let demoted: Set<ModelCatalog.Offer>
}

/// The Ranking tab: the Escalação, then the record sliced the way the user
/// chose — grouped by kind, difficulty, provider or model, or not at all, and
/// ordered by any of its columns — in compact tables of 30 pt rows.
///
/// Light by construction: the slice is computed on a queue of its own, only
/// while the tab is shown, again when the run feed changes (debounced, and
/// only when a run started, ended or was rated); the tables and their rows are
/// made once and configured again.
final class RankingView: NSView {
    /// Fixed widths of the figure columns, so that they line up from row to row
    /// and from table to table. What is left goes to the name.
    enum Column {
        static let rank: CGFloat = 16
        static let score: CGFloat = 32
        static let time: CGFloat = 50
        static let uses: CGFloat = 34
        /// ENTREGAS as the Resumo sets it…
        static let deliveries: CGFloat = 50
        /// …and as the ranking does, a little wider for the ▲/▼ of its head.
        static let delivered: CGFloat = 56
        static let cost: CGFloat = 46
        static let gap = CockpitStyle.Space.sm
        /// The least the name keeps before CUSTO is dropped: figures are never cut.
        static let nameAtLeast: CGFloat = 96
        static var withCost: CGFloat { rank + score + time + uses + delivered + cost + 6 * gap + nameAtLeast }
    }

    typealias Loader = (@escaping @MainActor @Sendable (RankingData) -> Void) -> Void

    /// How far back the ranking looks.
    static let history = 2000
    /// How long the run feed must be still before the ranking is read again.
    static let settle: TimeInterval = 1.5

    private let column = NSStackView()
    /// The user's lineup, above the record.
    let lineup: LineupSectionView
    private let controls = RankingControls()
    private let loading = NSTextField.label("carregando catálogo…", font: CockpitStyle.caption, color: CockpitStyle.muted)
    private let emptyTitle = NSTextField.label("Ainda não há entregas para comparar", font: CockpitStyle.title, color: CockpitStyle.text)
    private let emptyBody = NSTextField(wrappingLabelWithString: "O maestro dá uma nota de 1 a 5 a cada entrega que revisa. Com as notas e os tempos, o ranking aparece aqui, e quem fica para trás desce na sua escalação.")
    private var tables: [RankingGroupView] = []

    private let loader: Loader
    private let defaults: UserDefaults?
    /// Snapshots and tests draw at once; the app computes on `queue`.
    private let computesInline: Bool
    private let queue = DispatchQueue(label: "dev.vitra.ranking", qos: .userInitiated)
    private(set) var options: RankingOptions
    private var data: RankingData?
    private(set) var slice: RankingSlice?
    private var generation = 0
    private var collapsed: Set<String> = []
    private var showsCost = true
    private var feedSignature: String?
    private var pendingReload: DispatchWorkItem?
    private var popover: NSPopover?

    init(
        lineup: LineupSectionView = LineupSectionView(), loader: @escaping Loader = RankingView.loadFromDisk,
        defaults: UserDefaults? = .standard, options: RankingOptions? = nil, computesInline: Bool = false
    ) {
        self.lineup = lineup
        self.loader = loader
        self.defaults = defaults
        self.computesInline = computesInline
        self.options = options ?? defaults.map(RankingOptions.load) ?? RankingOptions()
        super.init(frame: .zero)
        collapsed = loadCollapsed()
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.panel.cgColor
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: CockpitStyle.Space.lg, left: CockpitStyle.inset, bottom: CockpitStyle.Space.xl, right: CockpitStyle.inset)
        column.translatesAutoresizingMaskIntoConstraints = false
        emptyBody.font = CockpitStyle.body
        emptyBody.textColor = CockpitStyle.muted
        for view in [lineup, controls, loading, emptyTitle, emptyBody] as [NSView] { add(view) }
        column.setCustomSpacing(CockpitStyle.Space.xxl, after: lineup)
        column.setCustomSpacing(CockpitStyle.Space.lg, after: controls)
        column.setCustomSpacing(CockpitStyle.Space.lg, after: loading)
        column.setCustomSpacing(CockpitStyle.Space.md, after: emptyTitle)
        column.setCustomSpacing(CockpitStyle.Space.xl, after: emptyBody)
        [controls, loading, emptyTitle, emptyBody].forEach { $0.isHidden = true }
        controls.onChange = { [weak self] in self?.choose($0) }

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

    // MARK: Reading

    /// Reads the lineup, the history and the catalogue, then draws. The
    /// loader may answer twice: at once without a catalogue, and again when
    /// the CLIs have listed theirs.
    func reload() {
        pendingReload?.cancel()
        feedSignature = nil
        loader { [weak self] data in self?.loaded(data) }
    }

    /// The run feed moved. Read again once it has been still for a moment,
    /// and only when a run started, ended or was rated: the per-second clock
    /// of a running worker changes nothing here.
    func runsChanged(_ runs: [Run]) {
        let signature = runs.map { "\($0.id):\($0.state):\($0.rating?.score ?? 0)" }.joined(separator: ",")
        defer { feedSignature = signature }
        guard let previous = feedSignature, previous != signature else { return }
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Gone from the screen meanwhile: the next look reads afresh anyway.
            guard let self, self.window != nil else { return }
            self.loader { [weak self] data in self?.loaded(data) }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func loaded(_ data: RankingData) {
        // A second answer without the catalogue keeps the one already known.
        let offers = data.offers ?? self.data?.offers
        let merged = RankingData(lineup: data.lineup, history: data.history, offers: offers, demoted: data.demoted)
        self.data = merged
        lineup.show(LineupData(lineup: merged.lineup, history: merged.history, offers: offers ?? []))
        recompute()
    }

    /// The real sources: `~/.vitra/lineup.json`, the runs, and the catalogue
    /// — at once when it is cached, otherwise listed here, off the main
    /// thread, which can take seconds.
    nonisolated static func loadFromDisk(_ done: @escaping @MainActor @Sendable (RankingData) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let executables = Executables.discover()
            let lineup = Lineup.load()
            let history = Orchestrator(executables: executables).recent(limit: history)
            let demoted = LineupBoard.demoted(lineup, history: history)
            let cached = ModelCatalog.listingIfCached(executables).map(ModelCatalog.offers) ?? Catalogue.recent()
            let first = RankingData(lineup: lineup, history: history, offers: cached, demoted: demoted)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(first) } }
            guard cached == nil else { return }
            let offers = ModelCatalog.offers(ModelCatalog.cachedListing(executables))
            Catalogue.keep(offers)
            let full = RankingData(lineup: lineup, history: history, offers: offers, demoted: demoted)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(full) } }
        }
    }

    /// The last catalogue listed here, for ten minutes. `ModelCatalog` keeps
    /// only a listing every CLI answered; with one signed out, every reload
    /// would list them all again, and the ranking reloads while workers run.
    private enum Catalogue {
        static let lifetime: TimeInterval = 600
        private static let kept = OSAllocatedUnfairLock<(Date, [ModelCatalog.Offer])?>(initialState: nil)

        static func recent(now: Date = Date()) -> [ModelCatalog.Offer]? {
            kept.withLock { $0.flatMap { now.timeIntervalSince($0.0) < lifetime ? $0.1 : nil } }
        }

        static func keep(_ offers: [ModelCatalog.Offer]) { kept.withLock { $0 = (Date(), offers) } }
    }

    // MARK: Slicing

    private func choose(_ options: RankingOptions) {
        let grouping = self.options.grouping
        self.options = options
        if let defaults { options.save(to: defaults) }
        if options.grouping != grouping { collapsed = loadCollapsed() }
        recompute()
    }

    private func recompute() {
        guard let data else { return }
        generation += 1
        let (generation, options) = (self.generation, self.options)
        guard !computesInline else {
            return show(RankingSlice.make(runs: data.history, offers: data.offers, options: options, demoted: data.demoted))
        }
        queue.async {
            let slice = RankingSlice.make(runs: data.history, offers: data.offers, options: options, demoted: data.demoted)
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                guard let self, self.generation == generation else { return }
                self.show(slice)
            } }
        }
    }

    // MARK: Drawing

    private func show(_ slice: RankingSlice) {
        self.slice = slice
        let hasAnything = !(data?.history.isEmpty ?? true) || !(data?.offers?.isEmpty ?? true)
        controls.isHidden = !hasAnything
        controls.show(options, unusedCount: slice.unusedCount, summary: slice.summary)
        loading.isHidden = !(options.showsUnused && data?.offers == nil)
        emptyTitle.isHidden = !slice.groups.isEmpty
        emptyBody.isHidden = !slice.groups.isEmpty
        while tables.count < slice.groups.count {
            let table = RankingGroupView()
            table.onToggle = { [weak self] in self?.toggle($0) }
            table.onHead = { [weak self] order in
                guard let self else { return }
                self.choose(self.options.clicking(order))
            }
            table.onRow = { [weak self] in self?.open($0) }
            add(table)
            column.setCustomSpacing(CockpitStyle.Space.xl, after: table)
            tables.append(table)
        }
        for (index, table) in tables.enumerated() {
            table.isHidden = index >= slice.groups.count
            guard index < slice.groups.count else { continue }
            let group = slice.groups[index]
            table.configure(group, options: options, isCollapsed: collapsed.contains(group.id), showsCost: showsCost)
        }
    }

    override func layout() {
        super.layout()
        // On a narrow panel CUSTO goes, so the name keeps some room.
        let fits = bounds.width - 2 * CockpitStyle.inset >= Column.withCost
        guard fits != showsCost else { return }
        showsCost = fits
        if let slice { show(slice) }
    }

    private func add(_ view: NSView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * CockpitStyle.inset).isActive = true
    }

    // MARK: Folding

    private var collapsedKey: String { "ranking.collapsed." + options.grouping.rawValue }

    private func loadCollapsed() -> Set<String> {
        Set(defaults?.stringArray(forKey: collapsedKey) ?? [])
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        defaults?.set(collapsed.sorted(), forKey: collapsedKey)
        if let slice { show(slice) }
    }

    // MARK: A worker's record

    /// Opens the worker's breakdown under its row; worked out on the queue
    /// like the slice, since it reads the whole history.
    private func open(_ row: RankingRowView) {
        guard let worker = row.entry?.worker, let history = data?.history else { return }
        queue.async {
            let breakdown = RankingBreakdown.of(worker, runs: history)
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self, weak row] in
                guard let self, let row, row.window != nil else { return }
                self.showDetail(breakdown, under: row)
            } }
        }
    }

    private func showDetail(_ breakdown: RankingBreakdown, under row: NSView) {
        popover?.close()
        let worker = breakdown.worker
        let detail = RankingDetailView(
            breakdown, now: Date(),
            membership: { [weak self] in self?.lineup.contains(worker, in: $0) },
            onAdd: { [weak self] level in
                self?.lineup.append(worker, to: level)
                self?.popover?.close()
            }
        )
        let controller = NSViewController()
        controller.view = detail
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: row.bounds, of: row, preferredEdge: .maxY)
        self.popover = popover
    }

    // MARK: Building blocks, shared with the Escalação and the Resumo

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
