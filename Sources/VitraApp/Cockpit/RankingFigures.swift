import Foundation
import VitraOrchestrator

/// How one worker did over some runs: the figures of one row of the ranking.
///
/// One aggregation for every slice, so a row reads the same whether it stands
/// for one kind of task, one difficulty or the whole history: the ratings are
/// averaged together, and the medians are taken over the runs themselves, not
/// over per-kind medians.
struct RankingFigures: Equatable, Sendable {
    /// Every time the worker was sent, whatever came of it — running, stopped
    /// by the user, failed or delivered. A run its provider refused (quota,
    /// signed out, down) is not a use: the worker never ran.
    let uses: Int
    /// Runs that came to a verdict: finished or lost.
    let attempted: Int
    /// Of those, the ones that delivered what was asked: a result that is not
    /// an error, and not rated below satisfactory.
    let delivered: Int
    let rated: Int
    /// The average of every rating, or nil when none.
    let rating: Double?
    /// The median time of the delivered runs, or nil when none.
    let medianSeconds: TimeInterval?
    /// The median cost of one delivered run, or nil when none.
    let medianCost: Double?
    let lastUsed: Date?

    /// Delivered out of attempted, or nil before any verdict.
    var deliveryRate: Double? { attempted == 0 ? nil : Double(delivered) / Double(attempted) }

    /// The figures of `runs`, which should already be the counted ones (see
    /// `RankingFigures.counts`).
    static func of(_ runs: [Run]) -> RankingFigures {
        let attempted = runs.filter(isAttempted)
        let delivered = attempted.filter(isDelivered)
        let ratings = runs.compactMap { $0.rating?.score }
        return RankingFigures(
            uses: runs.count,
            attempted: attempted.count,
            delivered: delivered.count,
            rated: ratings.count,
            rating: ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count),
            medianSeconds: Scoreboard.median(delivered.map(\.duration)),
            medianCost: Scoreboard.median(delivered.map { $0.output?.costUSD ?? 0 }),
            lastUsed: runs.map(\.started).max()
        )
    }

    /// Whether a run counts at all: a provider failure says nothing about the
    /// worker and is left out everywhere, uses included.
    static func counts(_ run: Run) -> Bool { run.providerFailure == nil }

    private static func isAttempted(_ run: Run) -> Bool {
        switch run.state {
        case .finished, .lost: return true
        case .running, .cancelled: return false
        }
    }

    private static func isDelivered(_ run: Run) -> Bool {
        !Scoreboard.hasFailed(run) && run.rating?.isSatisfactory != false
    }

    // MARK: As text

    var scoreText: String { rating.map { String(format: "%.1f", $0) } ?? "—" }
    var timeText: String { medianSeconds.map(WorkerBoard.duration) ?? "—" }
    var usesText: String { "\(uses)" }
    var deliveriesText: String { "\(delivered)/\(attempted)" }
    var costText: String { medianCost.map(WorkerBoard.money) ?? "—" }
    var ratingsText: String {
        rated == 0 ? "sem avaliação" : "\(rated) \(rated == 1 ? "avaliação" : "avaliações")"
    }
}

/// A worker's record cut by kind of task and by difficulty, for the popover a
/// row opens.
struct RankingBreakdown: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        let title: String
        let figures: RankingFigures
    }

    let worker: ModelCatalog.Offer
    let overall: RankingFigures
    /// Only the kinds and difficulties it was used on, in their usual order.
    let kinds: [Line]
    let difficulties: [Line]

    static func of(_ worker: ModelCatalog.Offer, runs: [Run]) -> RankingBreakdown {
        let mine = runs.filter { RankingFigures.counts($0) && WorkerPicker.isRun($0, of: worker) }
        let kinds = TaskKind.allCases.compactMap { kind -> Line? in
            let ofKind = mine.filter { ($0.spec.kind ?? .other) == kind }
            return ofKind.isEmpty ? nil : Line(title: WorkerBoard.kindName(kind), figures: .of(ofKind))
        }
        let difficulties = LineupBoard.tiers.compactMap { level -> Line? in
            let ofLevel = mine.filter { ($0.spec.difficulty ?? .normal) == level }
            return ofLevel.isEmpty ? nil : Line(title: LineupBoard.title(level).lowercased(), figures: .of(ofLevel))
        }
        return RankingBreakdown(worker: worker, overall: .of(mine), kinds: kinds, difficulties: difficulties)
    }
}
