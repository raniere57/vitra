import Foundation

/// Chooses the worker for a piece of work, from the record, with no model in
/// the loop.
///
/// A worker is a CLI, a model and an effort: haiku at low and haiku at high
/// are two workers with separate records. The order is:
///
/// 1. Workers rated 4 or more on the kind, the fastest first.
/// 2. Every fifth piece of a kind is a learning turn instead: the cheapest
///    worker with fewer than two deliveries on the kind, so each earns a
///    record without holding the work up. A higher effort of a model waits
///    until a lower one has run. With nobody left to learn, the least used.
/// 3. While nobody is rated 4 or more on the kind, learning comes first.
/// 4. Otherwise the cheapest worker that may run.
///
/// Pure: the choice is a function of its inputs, so it can be tested without
/// spawning anything.
public enum WorkerPicker {
    public struct Choice: Equatable, Sendable {
        public let offer: ModelCatalog.Offer
        /// Why, in a few words: it is shown to the orchestrator.
        public let reason: String
    }

    /// Delivered runs a worker needs on a kind before it stops being tried.
    static let deliveriesToLearn = 2
    /// Every this-many-th piece of a kind goes to the least used worker.
    static let explorationEvery = 5
    /// A run that failed this fast never really ran: a quota, a sign-in.
    static let quickFailure: TimeInterval = 60
    /// How long such a failure keeps its CLI out.
    static let quotaMemory: TimeInterval = 30 * 60
    /// What kinds of task gemini may be given: it fails whenever it reaches
    /// for a shell, so it reads and does not run anything.
    static let geminiKinds: Set<TaskKind> = [.explore, .review, .docs]

    /// The worker for the next piece of `kind`, or nil when none may run.
    ///
    /// - Parameters:
    ///   - offers: every worker the catalogue lists, in catalogue order.
    ///   - installed: the CLIs that are on this machine.
    ///   - excluded: CLIs that must not be picked, such as the implementer's
    ///     own when the piece is its audit.
    public static func pick(
        kind: TaskKind,
        access: WorkerAccess,
        needsCommands: Bool,
        history: [Run],
        offers: [ModelCatalog.Offer],
        installed: Set<WorkerCLI>,
        excluded: Set<WorkerCLI> = [],
        now: Date = Date()
    ) -> Choice? {
        // Not a verdict on anyone: a run the user stopped is not a try.
        let ofKind = history.filter { ($0.spec.kind ?? .other) == kind && $0.state != .cancelled }
        let stalled = stalledCLIs(history, now: now)

        let candidates = offers.enumerated().filter { _, offer in
            guard installed.contains(offer.cli), !excluded.contains(offer.cli), !stalled.contains(offer.cli) else {
                return false
            }
            switch offer.cli {
            case .claude, .opencode: return true
            case .cursor: return !needsCommands
            case .gemini: return !needsCommands && access == .read && geminiKinds.contains(kind)
            }
        }.map { order, offer in
            Candidate(offer: offer, order: order, runs: ofKind.filter { isRun($0, of: offer) })
        }
            // Known bad on this kind, at this effort: never picked on its own.
            .filter { $0.average.map { $0 >= Double(Rating.satisfactory) } ?? true }
            // Nor one that has run twice here and delivered nothing: unrated
            // failures are a record too.
            .filter { $0.runs.count < deliveriesToLearn || $0.delivered > 0 }

        func cliRuns(_ candidate: Candidate) -> Int {
            ofKind.filter { $0.spec.cli == candidate.offer.cli }.count
        }

        let learning = candidates.filter {
            $0.delivered < deliveriesToLearn && lowerEffortTried($0.offer, offers: offers, ofKind: ofKind)
        }.min(by: {
            ($0.costRank, cliRuns($0), $0.order) < ($1.costRank, cliRuns($1), $1.order)
        })
        func learn(_ first: Candidate) -> Choice {
            Choice(
                offer: first.offer,
                reason: "learning, \(first.delivered) of \(deliveriesToLearn) runs on \(kind.rawValue)"
            )
        }

        // Proven workers do the work; trying the others is a turn, not a
        // toll. With dozens of untried workers on offer, learning them all
        // first would put every slow or broken one ahead of the good ones.
        let good = candidates.filter { ($0.average ?? 0) >= Double(Rating.satisfactory) }
        if !good.isEmpty {
            if ofKind.count % explorationEvery == explorationEvery - 1 {
                if let learning { return learn(learning) }
                if let least = candidates.min(by: {
                    ($0.runs.count, $0.costRank, $0.order) < ($1.runs.count, $1.costRank, $1.order)
                }) {
                    return Choice(
                        offer: least.offer,
                        reason: "every fifth piece goes to the least used worker: "
                            + "\(least.runs.count) \(least.runs.count == 1 ? "run" : "runs") on \(kind.rawValue)"
                    )
                }
            }
            if let best = good.min(by: {
                ($0.medianSeconds, $0.medianCost, $0.order) < ($1.medianSeconds, $1.medianCost, $1.order)
            }) {
                return Choice(offer: best.offer, reason: best.fastestReason(kind))
            }
        }

        // Nobody has earned the kind yet: the cheap untried ones go first.
        if let learning { return learn(learning) }

        return candidates.min { ($0.costRank, $0.order) < ($1.costRank, $1.order) }.map {
            Choice(offer: $0.offer, reason: "cheapest that may run; none is rated \(Rating.satisfactory) or more on \(kind.rawValue)")
        }
    }

    // MARK: Candidates

    private struct Candidate {
        let offer: ModelCatalog.Offer
        /// Position in the catalogue, the last tie-break.
        let order: Int
        /// This worker's runs on the kind.
        let runs: [Run]

        var delivered: Int { deliveredRuns.count }
        private var deliveredRuns: [Run] {
            runs.filter { run in
                if case .finished = run.state { return !Scoreboard.hasFailed(run) }
                return false
            }
        }

        var average: Double? {
            let ratings = runs.compactMap { $0.rating?.score }
            return ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count)
        }

        var medianSeconds: TimeInterval { Scoreboard.median(deliveredRuns.map(\.duration)) ?? .infinity }
        var medianCost: Double { Scoreboard.median(deliveredRuns.map { $0.output?.costUSD ?? 0 }) ?? .infinity }

        /// Free CLIs cost nothing; claude costs by its tier, in the order the
        /// catalogue lists them: haiku low < medium < high < sonnet high < opus low.
        var costRank: Int {
            guard offer.cli == .claude else { return 0 }
            let tiers = ModelCatalog.claudeWorkers.flatMap { worker in worker.efforts.map { (worker.model, $0) } }
            let index = tiers.firstIndex { $0.0 == offer.model && $0.1 == offer.effort }
            return 1 + (index ?? tiers.count)
        }

        func fastestReason(_ kind: TaskKind) -> String {
            let score = String(format: "%.1f", average ?? 0)
            let seconds = medianSeconds.isFinite ? ", median \(Int(medianSeconds.rounded()))s" : ""
            return "fastest rated \(Rating.satisfactory) or more on \(kind.rawValue) (average \(score)\(seconds))"
        }
    }

    /// Whether `run` is `offer`: the same CLI, model and effort.
    static func isRun(_ run: Run, of offer: ModelCatalog.Offer) -> Bool {
        run.spec.cli == offer.cli && run.spec.model == offer.model && run.spec.effort == offer.effort
    }

    // MARK: Effort ladder

    /// Whether a lower effort of `offer`'s model has run on the kind, or none
    /// is offered: a model is tried at its lowest effort before a higher one.
    private static func lowerEffortTried(_ offer: ModelCatalog.Offer, offers: [ModelCatalog.Offer], ofKind: [Run]) -> Bool {
        let (base, effort) = split(cli: offer.cli, model: offer.model, effort: offer.effort)
        guard let rank = rank(effort) else { return true }
        let isLower = { (cli: WorkerCLI, model: String, effort: String?) -> Bool in
            let other = split(cli: cli, model: model, effort: effort)
            return cli == offer.cli && other.base == base && (self.rank(other.effort) ?? rank) < rank
        }
        guard offers.contains(where: { isLower($0.cli, $0.model, $0.effort) }) else { return true }
        return ofKind.contains { isLower($0.spec.cli, $0.spec.model, $0.spec.effort) }
    }

    private static func rank(_ effort: String?) -> Int? {
        effort.flatMap { ModelCatalog.efforts.firstIndex(of: $0) }
    }

    /// The model without its effort, and the effort: apart for claude and
    /// opencode, inside the id for cursor and gemini (grok-4.7-low-fast).
    static func split(cli: WorkerCLI, model: String, effort: String?) -> (base: String, effort: String?) {
        switch cli {
        case .claude, .opencode:
            return (model, effort)
        case .cursor, .gemini:
            let words = model.split(separator: "-").map(String.init)
            guard let index = words.lastIndex(where: { ModelCatalog.efforts.contains($0) }) else { return (model, nil) }
            var rest = words
            rest.remove(at: index)
            return (rest.joined(separator: "-"), words[index])
        }
    }

    // MARK: Quota

    /// The CLIs whose latest run, of any kind, failed without really running
    /// — out within a minute with nothing useful, as with "Free usage limit
    /// reached" — less than half an hour ago.
    static func stalledCLIs(_ history: [Run], now: Date) -> Set<WorkerCLI> {
        var stalled: Set<WorkerCLI> = []
        for (cli, runs) in Dictionary(grouping: history, by: \.spec.cli) {
            guard let latest = runs.max(by: { $0.started < $1.started }),
                  case let .finished(exitCode) = latest.state,
                  exitCode != 0 || Scoreboard.hasFailed(latest),
                  latest.duration < quickFailure,
                  now.timeIntervalSince(latest.started) < quotaMemory
            else { continue }
            stalled.insert(cli)
        }
        return stalled
    }
}
