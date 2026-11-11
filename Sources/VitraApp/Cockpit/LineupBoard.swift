import Foundation
import VitraOrchestrator

/// One worker of a lineup tier, as a row of the Escalação reads it.
struct LineupRow: Equatable {
    let worker: ModelCatalog.Offer
    let name: String
    /// The average rating on this tier's pieces, or a dash.
    let score: String
    /// The median time of a delivery on this tier's pieces, or a dash.
    let time: String
    /// "rebaixado: nota 3.2" or "rebaixado: lento" while the record passes it over.
    let demotion: String?
}

/// What the Escalação needs to draw itself: the lineup, the record, and the
/// catalogue to add workers from.
struct LineupData: Sendable {
    let lineup: Lineup
    let history: [Run]
    let offers: [ModelCatalog.Offer]
}

/// Turns the lineup and the record into what the Escalação shows.
enum LineupBoard {
    static let tiers: [Difficulty] = [.hard, .normal, .easy]

    static func title(_ difficulty: Difficulty) -> String {
        switch difficulty {
        case .hard: return "Difícil"
        case .normal: return "Normal"
        case .easy: return "Fácil"
        }
    }

    static func rows(_ tier: [ModelCatalog.Offer], difficulty: Difficulty, history: [Run]) -> [LineupRow] {
        tier.enumerated().map { index, worker in
            let runs = history.filter {
                ($0.spec.difficulty ?? .normal) == difficulty && $0.state != .cancelled && $0.providerFailure == nil
                    && WorkerPicker.isRun($0, of: worker)
            }
            let ratings = runs.compactMap { $0.rating?.score }
            let delivered = runs.filter { run in
                if case .finished = run.state { return !Scoreboard.hasFailed(run) }
                return false
            }
            return LineupRow(
                worker: worker,
                name: WorkerPicker.shortName(worker),
                score: ratings.isEmpty ? "—" : String(format: "%.1f", Double(ratings.reduce(0, +)) / Double(ratings.count)),
                time: Scoreboard.median(delivered.map(\.duration)).map(WorkerBoard.duration) ?? "—",
                demotion: demotion(of: worker, next: tier.dropFirst(index + 1).first, difficulty: difficulty, history: history)
            )
        }
    }

    /// The first kind on which the record demotes `worker`, in words.
    private static func demotion(
        of worker: ModelCatalog.Offer, next: ModelCatalog.Offer?, difficulty: Difficulty, history: [Run]
    ) -> String? {
        for kind in TaskKind.allCases {
            switch WorkerPicker.demotion(of: worker, kind: kind, difficulty: difficulty, history: history, next: next) {
            case let .rating(average)?: return "rebaixado: nota " + String(format: "%.1f", average)
            case .slow?: return "rebaixado: lento"
            case nil: continue
            }
        }
        return nil
    }

    /// The catalogue's workers that are not in `tier`, to add from.
    static func addable(_ offers: [ModelCatalog.Offer], to tier: [ModelCatalog.Offer]) -> [ModelCatalog.Offer] {
        offers.filter { !tier.contains($0) }
    }

    /// `tier` with the worker at `from` moved to `to`, an index in the list
    /// as it is before the move (0...count).
    static func moved(_ tier: [ModelCatalog.Offer], from: Int, to: Int) -> [ModelCatalog.Offer] {
        guard tier.indices.contains(from) else { return tier }
        var copy = tier
        let worker = copy.remove(at: from)
        copy.insert(worker, at: min(max(to > from ? to - 1 : to, 0), copy.count))
        return copy
    }
}
