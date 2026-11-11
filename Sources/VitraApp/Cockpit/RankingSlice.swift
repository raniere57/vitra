import Foundation
import VitraOrchestrator

/// How the ranking's rows are gathered into tables.
enum RankingGrouping: String, CaseIterable, Sendable {
    case kind, difficulty, provider, model, none

    var title: String {
        switch self {
        case .kind: return "Tipo de tarefa"
        case .difficulty: return "Dificuldade"
        case .provider: return "Fornecedor"
        case .model: return "Modelo"
        case .none: return "Nenhum"
        }
    }
}

/// What the rows of each table are ranked by.
enum RankingOrder: String, CaseIterable, Sendable {
    case rating, time, uses, deliveries, cost, name

    var title: String {
        switch self {
        case .rating: return "Nota"
        case .time: return "Tempo"
        case .uses: return "Usos"
        case .deliveries: return "Entregas"
        case .cost: return "Custo"
        case .name: return "Nome"
        }
    }

    /// Whether the better rows have the smaller value: the fastest, the
    /// cheapest, the first in the alphabet.
    var isAscending: Bool { self == .time || self == .cost || self == .name }

    /// What breaks a tie on this ordering, before the name does.
    var tieBreaks: [RankingOrder] {
        switch self {
        case .rating: return [.time, .uses]
        case .time: return [.rating, .uses]
        case .uses: return [.rating, .time]
        case .deliveries: return [.uses, .rating]
        case .cost: return [.rating, .time]
        case .name: return []
        }
    }
}

/// The user's choice of slice, remembered between launches.
struct RankingOptions: Equatable, Sendable {
    var grouping = RankingGrouping.kind
    var order = RankingOrder.rating
    /// Whether `order` runs the other way from its natural one.
    var isReversed = false
    /// Whether the catalogue's workers with no run in a table end it.
    var showsUnused = false

    /// Whether the values go up down the table, for the ▲/▼ on the column head.
    var isAscending: Bool { order.isAscending != isReversed }

    /// The options after a click on `order`'s column head: that ordering in
    /// its natural direction, or the current one reversed.
    func clicking(_ order: RankingOrder) -> RankingOptions {
        var copy = self
        if copy.order == order { copy.isReversed.toggle() } else { copy.order = order; copy.isReversed = false }
        return copy
    }

    private enum Key {
        static let grouping = "ranking.grouping", order = "ranking.order"
        static let reversed = "ranking.reversed", unused = "ranking.showsUnused"
    }

    static func load(from defaults: UserDefaults) -> RankingOptions {
        RankingOptions(
            grouping: defaults.string(forKey: Key.grouping).flatMap(RankingGrouping.init) ?? .kind,
            order: defaults.string(forKey: Key.order).flatMap(RankingOrder.init) ?? .rating,
            isReversed: defaults.bool(forKey: Key.reversed),
            showsUnused: defaults.bool(forKey: Key.unused)
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(grouping.rawValue, forKey: Key.grouping)
        defaults.set(order.rawValue, forKey: Key.order)
        defaults.set(isReversed, forKey: Key.reversed)
        defaults.set(showsUnused, forKey: Key.unused)
    }
}

/// One line of a table: a worker and its figures, or a worker never used.
struct RankingEntry: Equatable, Sendable {
    let worker: ModelCatalog.Offer
    let name: String
    /// Nil for a worker of the catalogue with no run in this table.
    let figures: RankingFigures?
    /// 1-based place in the table; nil for a worker never used.
    let place: Int?
    /// Whether the lineup's record passes it over somewhere.
    let isDemoted: Bool
}

/// One table: a title, its rows in order, and its own totals.
struct RankingGroup: Equatable, Sendable {
    /// Stable across reloads, to remember which tables are folded.
    let id: String
    let title: String
    let rows: [RankingEntry]
    let deliveries: Int

    /// "9 operários · 201 entregas", for the right of the table's title.
    var totals: String {
        RankingSlice.count(rows.count, "operário", "operários") + " · " + RankingSlice.count(deliveries, "entrega", "entregas")
    }
}

/// The ranking as the user chose to slice it.
///
/// Pure: runs, catalogue and options in, tables out. The view computes it
/// off the main thread and only draws the result.
struct RankingSlice: Equatable, Sendable {
    let groups: [RankingGroup]
    let summary: String
    /// The catalogue's workers with no run at all, or nil before the
    /// catalogue is known.
    let unusedCount: Int?

    static func make(
        runs: [Run], offers: [ModelCatalog.Offer]?, options: RankingOptions, demoted: Set<ModelCatalog.Offer> = []
    ) -> RankingSlice {
        let counted = runs.filter(RankingFigures.counts)
        let byGroup = Dictionary(grouping: counted) { key(of: worker(of: $0), run: $0, options.grouping) }
        let keys = groupKeys(used: Set(byGroup.keys), offers: offers ?? [], options: options)
        let groups = keys.compactMap { key -> RankingGroup? in
            let runs = byGroup[key.id] ?? []
            let used = Dictionary(grouping: runs, by: worker(of:)).map { worker, runs in
                (worker, RankingFigures.of(runs))
            }
            let ranked = used.sorted { precedes($0, $1, options: options) }
            let usedWorkers = Set(used.map(\.0))
            let unused = options.showsUnused
                ? (offers ?? []).filter { !usedWorkers.contains($0) && key.matches($0) }
                : []
            guard !ranked.isEmpty || !unused.isEmpty else { return nil }
            let rows = ranked.enumerated().map { index, pair in
                RankingEntry(worker: pair.0, name: name(pair.0, options.grouping), figures: pair.1, place: index + 1,
                             isDemoted: demoted.contains(pair.0))
            } + unused.map {
                RankingEntry(worker: $0, name: name($0, options.grouping), figures: nil, place: nil, isDemoted: demoted.contains($0))
            }
            return RankingGroup(id: key.id, title: key.title, rows: rows, deliveries: ranked.reduce(0) { $0 + $1.1.delivered })
        }
        let usedAnywhere = Set(counted.map(worker(of:)))
        return RankingSlice(
            groups: groups,
            summary: summary(runs: runs, offers: offers),
            unusedCount: offers.map { Set($0).subtracting(usedAnywhere).count }
        )
    }

    /// "38 operários · 14 usados · 24 nunca usados · 312 entregas": every
    /// worker known — used or offered —, how many were used, how many never,
    /// and how many deliveries there were. Without the catalogue, only what
    /// the runs say.
    static func summary(runs: [Run], offers: [ModelCatalog.Offer]?) -> String {
        let counted = runs.filter(RankingFigures.counts)
        let used = Set(counted.map(worker(of:)))
        let deliveries = RankingFigures.of(counted).delivered
        var parts: [String] = []
        if let offers {
            let all = used.union(offers)
            parts.append(count(all.count, "operário", "operários"))
            parts.append(count(used.count, "usado", "usados"))
            parts.append(count(all.count - used.count, "nunca usado", "nunca usados"))
        } else {
            parts.append(count(used.count, "usado", "usados"))
        }
        parts.append(count(deliveries, "entrega", "entregas"))
        return parts.joined(separator: " · ")
    }

    static func count(_ number: Int, _ one: String, _ many: String) -> String {
        "\(number) \(number == 1 ? one : many)"
    }

    /// A worker is its CLI, model and effort: haiku at low and at high are two.
    static func worker(of run: Run) -> ModelCatalog.Offer {
        ModelCatalog.Offer(cli: run.spec.cli, model: run.spec.model, effort: run.spec.effort)
    }

    /// The row's name. Grouped by model the table's title already says the
    /// model, so a row is its effort.
    static func name(_ worker: ModelCatalog.Offer, _ grouping: RankingGrouping) -> String {
        if grouping == .model, let effort = WorkerPicker.split(cli: worker.cli, model: worker.model, effort: worker.effort).effort {
            return effort
        }
        return WorkerPicker.shortName(worker)
    }

    // MARK: Groups

    /// The providers in the order the cockpit names them elsewhere.
    static let providers: [WorkerCLI] = [.claude, .opencode, .cursor, .gemini]

    private struct GroupKey {
        let id: String
        let title: String
        /// Whether a worker of the catalogue belongs in this table at all.
        let matches: (ModelCatalog.Offer) -> Bool
    }

    private static func key(of worker: ModelCatalog.Offer, run: Run, _ grouping: RankingGrouping) -> String {
        switch grouping {
        case .kind: return "kind." + (run.spec.kind ?? .other).rawValue
        case .difficulty: return "difficulty." + (run.spec.difficulty ?? .normal).rawValue
        case .provider: return "provider." + worker.cli.rawValue
        case .model: return modelKey(worker)
        case .none: return "all"
        }
    }

    private static func modelKey(_ worker: ModelCatalog.Offer) -> String {
        "model.\(worker.cli.rawValue).\(WorkerPicker.split(cli: worker.cli, model: worker.model, effort: worker.effort).base)"
    }

    /// Every table the grouping has, in order. With "nunca usados" off only
    /// those with runs will have rows; the rest are dropped by `make`.
    private static func groupKeys(used: Set<String>, offers: [ModelCatalog.Offer], options: RankingOptions) -> [GroupKey] {
        switch options.grouping {
        case .kind:
            return TaskKind.allCases.map { kind in
                GroupKey(id: "kind." + kind.rawValue, title: WorkerBoard.kindName(kind), matches: { _ in true })
            }
        case .difficulty:
            return LineupBoard.tiers.map { level in
                GroupKey(id: "difficulty." + level.rawValue, title: LineupBoard.title(level), matches: { _ in true })
            }
        case .provider:
            return providers.map { cli in
                GroupKey(id: "provider." + cli.rawValue, title: cli.rawValue, matches: { $0.cli == cli })
            }
        case .model:
            let ids = used.union(options.showsUnused ? offers.map(modelKey) : [])
            return ids.sorted { left, right in
                let (l, r) = (left.split(separator: "."), right.split(separator: "."))
                let order = { (cli: Substring) in providers.firstIndex { $0.rawValue == cli } ?? providers.count }
                if l[1] != r[1] { return order(l[1]) < order(r[1]) }
                return left < right
            }.map { id in
                let parts = id.split(separator: ".", maxSplits: 2).map(String.init)
                let base = parts.count > 2 ? parts[2] : id
                let shown = base.split(separator: "/").last.map(String.init) ?? base
                return GroupKey(id: id, title: "\(parts[1]) · \(shown)", matches: { modelKey($0) == id })
            }
        case .none:
            return [GroupKey(id: "all", title: "todos", matches: { _ in true })]
        }
    }

    // MARK: Order

    private static func precedes(
        _ left: (ModelCatalog.Offer, RankingFigures), _ right: (ModelCatalog.Offer, RankingFigures), options: RankingOptions
    ) -> Bool {
        if let first = compare(left, right, options.order, reversed: options.isReversed) { return first }
        for tie in options.order.tieBreaks {
            if let first = compare(left, right, tie, reversed: false) { return first }
        }
        let (l, r) = (name(left.0, options.grouping), name(right.0, options.grouping))
        if l != r { return l < r }
        return left.0.name < right.0.name
    }

    /// Whether `left` comes first on `order`, or nil on a tie. A row with no
    /// value — never rated, never delivered — comes last either way.
    private static func compare(
        _ left: (ModelCatalog.Offer, RankingFigures), _ right: (ModelCatalog.Offer, RankingFigures),
        _ order: RankingOrder, reversed: Bool
    ) -> Bool? {
        let ascending = order.isAscending != reversed
        if order == .name {
            let (l, r) = (WorkerPicker.shortName(left.0).lowercased(), WorkerPicker.shortName(right.0).lowercased())
            return l == r ? nil : (l < r) == ascending
        }
        switch (value(left.1, order), value(right.1, order)) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case let (l?, r?): return l == r ? nil : (l < r) == ascending
        }
    }

    private static func value(_ figures: RankingFigures, _ order: RankingOrder) -> Double? {
        switch order {
        case .rating: return figures.rating
        case .time: return figures.medianSeconds
        case .uses: return Double(figures.uses)
        case .deliveries: return figures.deliveryRate
        case .cost: return figures.medianCost
        case .name: return nil
        }
    }
}
