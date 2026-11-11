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
/// A hard piece goes only to strong workers when any may run, and has no
/// learning turns; an easy one stays off them when a lighter worker may run.
/// A worker whose last three runs all failed rests for half an hour, and a CLI
/// whose provider said it is out of quota, signed out or down is left alone
/// until that has had time to pass.
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
    /// Kept for a failure whose words were not recognised.
    static let quickFailure: TimeInterval = 60
    /// How long such an unrecognised failure keeps its CLI out.
    static let quotaMemory: TimeInterval = 30 * 60
    /// Failures in a row that make a worker rest.
    static let restingAfter = 3
    /// The failures must fall within this, and the rest lasts this long from
    /// the last of them.
    static let restingWindow: TimeInterval = 30 * 60
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
    ///   - excludedWorkers: single workers that must not be picked, such as the
    ///     one whose delivery is being redone.
    ///   - difficulty: how hard the piece is.
    public static func pick(
        kind: TaskKind,
        access: WorkerAccess,
        needsCommands: Bool,
        history: [Run],
        offers: [ModelCatalog.Offer],
        installed: Set<WorkerCLI>,
        excluded: Set<WorkerCLI> = [],
        excludedWorkers: Set<ModelCatalog.Offer> = [],
        difficulty: Difficulty = .normal,
        now: Date = Date()
    ) -> Choice? {
        func attempt(skipping skipped: Set<ModelCatalog.Offer>) -> Choice? {
            choose(
                kind: kind, access: access, needsCommands: needsCommands, history: history, offers: offers,
                installed: installed, excluded: excluded, skipping: skipped, difficulty: difficulty, now: now
            )
        }
        let resters = resting(history, now: now)
        let choice = attempt(skipping: excludedWorkers.union(resters.keys))
        guard !resters.isEmpty,
              let without = attempt(skipping: excludedWorkers),
              without.offer != choice?.offer,
              let until = resters[without.offer]
        else { return choice }
        // The rest changed the choice: say who is resting and until when.
        guard let choice else { return nil }
        return Choice(
            offer: choice.offer,
            reason: choice.reason + "; \(without.offer.name) is resting until \(clock(until)) after \(restingAfter) failures in a row"
        )
    }

    private static func choose(
        kind: TaskKind,
        access: WorkerAccess,
        needsCommands: Bool,
        history: [Run],
        offers: [ModelCatalog.Offer],
        installed: Set<WorkerCLI>,
        excluded: Set<WorkerCLI>,
        skipping: Set<ModelCatalog.Offer>,
        difficulty: Difficulty,
        now: Date
    ) -> Choice? {
        // Not a verdict on anyone: a run the user stopped is not a try, and a
        // run whose provider was out of quota or down is not a run at all.
        let ofKind = history.filter {
            ($0.spec.kind ?? .other) == kind && $0.state != .cancelled && $0.providerFailure == nil
        }
        let stalled = stalledCLIs(history, now: now)

        let eligible = offers.enumerated().filter { _, offer in
            guard installed.contains(offer.cli), !excluded.contains(offer.cli), !stalled.contains(offer.cli),
                  !skipping.contains(offer)
            else { return false }
            switch offer.cli {
            case .claude, .opencode: return true
            case .cursor: return !needsCommands
            case .gemini: return !needsCommands && access == .read && geminiKinds.contains(kind)
            }
        }
        // A hard piece goes to a strong worker when one may run, an easy one
        // to a light worker when one may.
        let strong = eligible.filter { _, offer in isStrong(offer) }
        let light = eligible.filter { _, offer in !isStrong(offer) }
        let pool: [(offset: Int, element: ModelCatalog.Offer)]
        switch difficulty {
        case .hard: pool = strong.isEmpty ? eligible : strong
        case .easy: pool = light.isEmpty ? eligible : light
        case .normal: pool = eligible
        }

        let candidates = pool.map { order, offer in
            Candidate(offer: offer, order: order, runs: ofKind.filter { isRun($0, of: offer) }, difficulty: difficulty)
        }
            // Known bad on this kind, at this effort: never picked on its own.
            .filter { $0.average.map { $0 >= Double(Rating.satisfactory) } ?? true }
            // Nor one that has run twice here and delivered nothing: unrated
            // failures are a record too.
            .filter { $0.runs.count < deliveriesToLearn || $0.delivered > 0 }

        func cliRuns(_ candidate: Candidate) -> Int {
            ofKind.filter { $0.spec.cli == candidate.offer.cli }.count
        }
        // What the pick says about the piece, when it was not a normal one.
        func said(_ reason: String) -> String {
            difficulty == .normal ? reason : reason + ", \(difficulty.rawValue) piece"
        }

        // A hard piece is not the place to try an unknown worker.
        let learning = difficulty == .hard ? nil : candidates.filter {
            $0.delivered < deliveriesToLearn && lowerEffortTried($0.offer, offers: offers, ofKind: ofKind)
        }.min(by: {
            ($0.costRank, cliRuns($0), $0.order) < ($1.costRank, cliRuns($1), $1.order)
        })
        func learn(_ first: Candidate) -> Choice {
            Choice(
                offer: first.offer,
                reason: said("learning, \(first.delivered) of \(deliveriesToLearn) runs on \(kind.rawValue)")
            )
        }

        // Proven workers do the work; trying the others is a turn, not a
        // toll. With dozens of untried workers on offer, learning them all
        // first would put every slow or broken one ahead of the good ones.
        let good = candidates.filter { ($0.average ?? 0) >= Double(Rating.satisfactory) }
        if !good.isEmpty {
            if difficulty != .hard, ofKind.count % explorationEvery == explorationEvery - 1 {
                if let learning { return learn(learning) }
                if let least = candidates.min(by: {
                    ($0.runs.count, $0.costRank, $0.order) < ($1.runs.count, $1.costRank, $1.order)
                }) {
                    return Choice(
                        offer: least.offer,
                        reason: said(
                            "every fifth piece goes to the least used worker: "
                                + "\(least.runs.count) \(least.runs.count == 1 ? "run" : "runs") on \(kind.rawValue)"
                        )
                    )
                }
            }
            if let best = good.min(by: {
                ($0.medianSeconds, $0.medianCost, $0.order) < ($1.medianSeconds, $1.medianCost, $1.order)
            }) {
                return Choice(offer: best.offer, reason: said(best.fastestReason(kind)))
            }
        }

        // Nobody has earned the kind yet: the cheap untried ones go first.
        if let learning { return learn(learning) }

        return candidates.min { ($0.costRank, $0.order) < ($1.costRank, $1.order) }.map {
            Choice(
                offer: $0.offer,
                reason: said("cheapest that may run; none is rated \(Rating.satisfactory) or more on \(kind.rawValue)")
            )
        }
    }

    // MARK: Candidates

    private struct Candidate {
        let offer: ModelCatalog.Offer
        /// Position in the catalogue, the last tie-break.
        let order: Int
        /// This worker's runs on the kind.
        let runs: [Run]
        /// How hard the piece being placed is.
        let difficulty: Difficulty

        var delivered: Int { Self.delivered(runs).count }

        private static func delivered(_ runs: [Run]) -> [Run] {
            runs.filter { run in
                if case .finished = run.state { return !Scoreboard.hasFailed(run) }
                return false
            }
        }

        /// What ranking looks at: the runs of the same difficulty when the
        /// worker has two of them, otherwise everything it did on the kind.
        private var ranked: [Run] {
            let same = runs.filter { ($0.spec.difficulty ?? .normal) == difficulty }
            return same.count >= 2 ? same : runs
        }

        var average: Double? {
            let ratings = ranked.compactMap { $0.rating?.score }
            return ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count)
        }

        var medianSeconds: TimeInterval { Scoreboard.median(Self.delivered(ranked).map(\.duration)) ?? .infinity }
        var medianCost: Double { Scoreboard.median(Self.delivered(ranked).map { $0.output?.costUSD ?? 0 }) ?? .infinity }

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

    // MARK: Strength

    /// Whether `offer` is a worker for a hard piece: claude sonnet and opus at
    /// any effort, claude haiku only at high, and the Groks at high or xhigh.
    /// opencode's free models are never strong, and nor is gemini.
    static func isStrong(_ offer: ModelCatalog.Offer) -> Bool {
        switch offer.cli {
        case .claude:
            return offer.model != "haiku" || offer.effort == "high"
        case .cursor:
            let effort = split(cli: .cursor, model: offer.model, effort: offer.effort).effort
            return offer.model.contains("grok") && (effort == "high" || effort == "xhigh")
        case .opencode, .gemini:
            return false
        }
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

    /// The CLIs to leave alone for now.
    ///
    /// When a provider has said what is wrong — out of quota, signed out,
    /// down — that is believed: quota for an hour, a sign-in until a later run
    /// of the CLI succeeds, an outage for ten minutes, unless a later run
    /// succeeded before then. A failure with no such words is still taken for
    /// a quota when it came to nothing within a minute and is under half an
    /// hour old.
    static func stalledCLIs(_ history: [Run], now: Date) -> Set<WorkerCLI> {
        var stalled: Set<WorkerCLI> = []
        for (cli, runs) in Dictionary(grouping: history, by: \.spec.cli) {
            guard let latest = runs.max(by: { $0.started < $1.started }) else { continue }
            if let said = runs.filter({ $0.providerFailure != nil }).max(by: { $0.started < $1.started }),
               let failure = said.providerFailure {
                let recovered = runs.contains { $0.started > said.started && isDelivery($0) }
                let since = now.timeIntervalSince(said.ended ?? said.started)
                if !recovered, failure.stall.map({ since < $0 }) ?? true { stalled.insert(cli) }
                // The words settle it, whichever way: no guessing from speed.
                if latest.providerFailure != nil { continue }
            }
            guard case let .finished(exitCode) = latest.state,
                  exitCode != 0 || Scoreboard.hasFailed(latest),
                  latest.duration < quickFailure,
                  now.timeIntervalSince(latest.started) < quotaMemory
            else { continue }
            stalled.insert(cli)
        }
        return stalled
    }

    private static func isDelivery(_ run: Run) -> Bool {
        if case .finished = run.state { return !Scoreboard.hasFailed(run) }
        return false
    }

    // MARK: Circuit breaker

    /// The workers resting, and until when: those whose last three runs, of
    /// any kind, all failed within half an hour of each other, rest for half an
    /// hour from the last. A run that delivered, even one rated poorly, closes
    /// it, as does the time passing. A run stopped by the user, one still
    /// going and one whose provider failed are not verdicts either way.
    static func resting(_ history: [Run], now: Date) -> [ModelCatalog.Offer: Date] {
        let judged = history.filter { run in
            guard run.providerFailure == nil else { return false }
            switch run.state {
            case .finished, .lost: return true
            case .running, .cancelled: return false
            }
        }
        func end(_ run: Run) -> Date { run.ended ?? run.started }

        var resting: [ModelCatalog.Offer: Date] = [:]
        let byWorker = Dictionary(grouping: judged) {
            ModelCatalog.Offer(cli: $0.spec.cli, model: $0.spec.model, effort: $0.spec.effort)
        }
        for (worker, runs) in byWorker {
            let latest = Array(runs.sorted { end($0) > end($1) }.prefix(restingAfter))
            guard latest.count == restingAfter, latest.allSatisfy(Scoreboard.hasFailed),
                  let last = latest.map(end).max(), let first = latest.map(end).min(),
                  last.timeIntervalSince(first) <= restingWindow
            else { continue }
            let until = last.addingTimeInterval(restingWindow)
            if until > now { resting[worker] = until }
        }
        return resting
    }

    /// A time of day, as `HH:MM`, for saying when a rest ends.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
