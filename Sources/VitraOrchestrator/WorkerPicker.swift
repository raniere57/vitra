import Foundation

/// Chooses the worker for a piece of work, from the user's lineup and the
/// record, with no model in the loop: the maestro says what kind of piece it
/// is and how hard, never who does it.
///
/// A worker is a CLI, a model and an effort: haiku at low and haiku at high
/// are two workers with separate records. The order is:
///
/// 1. Who may run at all: installed, offered, not excluded, able to run the
///    commands asked for, its provider not out, not resting after three
///    failures in a row.
/// 2. Every other piece of a kind and difficulty is a learning turn while
///    there is somebody to learn about: a demoted lineup worker gets its
///    chance back, else the cheapest worker with fewer than two deliveries on
///    the kind, or one back from the cold (strong ones only for a hard piece).
///    A worker that failed or was rated below 4 is left in the cold for a day,
///    and for twice as long each time it does badly again in a row.
/// 3. A worker outside the lineup that has proved itself takes an easy or
///    normal piece from the lineup's: rated 4 or more, no dearer, and more
///    than twice as fast on the kind (three deliveries each).
/// 3. The first worker of the difficulty's lineup that may run and is not
///    demoted: average below 4 over two ratings or more on the kind, or more
///    than twice as slow as the next lineup worker (three deliveries each).
/// 4. Workers not in the lineup, by the record: the fastest rated 4 or more,
///    else the cheapest. The lineup is a preference, not a fence.
///
/// Pure: the choice is a function of its inputs, so it can be tested without
/// spawning anything.
public enum WorkerPicker {
    public struct Choice: Equatable, Sendable {
        public let offer: ModelCatalog.Offer
        public let pick: PickReason
        /// Why, in a few words: it is shown to the orchestrator.
        public var reason: String { pick.text }
    }

    /// Why a lineup worker is passed over on its record.
    public enum Demotion: Equatable, Sendable {
        case rating(Double)
        /// More than twice as slow as the named worker.
        case slow(than: ModelCatalog.Offer)
    }

    /// Ratings a lineup worker needs before its average can demote it.
    static let ratingsToDemote = 2
    /// Deliveries each of two workers needs before their times are compared.
    static let deliveriesToCompare = 3
    /// How many times slower than the next worker demotes one.
    static let slowerThan = 2.0

    /// Delivered runs a worker needs on a kind before it stops being tried.
    static let deliveriesToLearn = 2
    /// Every this-many-th piece of a kind goes to the least used worker.
    static let explorationEvery = 2
    /// How long a worker that did badly on a kind is left out of it; doubled
    /// for each bad run in a row, up to the cap.
    static let cold: TimeInterval = 24 * 3600
    static let coldCap: TimeInterval = 32 * 24 * 3600
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
    ///   - lineup: the user's preference per difficulty.
    ///   - switchedOff: CLIs the user switched off in the Projeto tab; read
    ///     from `~/.vitra/providers.json` unless given.
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
        lineup: Lineup = .standard,
        switchedOff: Set<WorkerCLI> = Set(ProviderSwitches.load().off),
        now: Date = Date()
    ) -> Choice? {
        // Not a verdict on anyone: a run the user stopped is not a try, and a
        // run whose provider was out of quota or down is not a run at all.
        let ofKind = history.filter {
            ($0.spec.kind ?? .other) == kind && $0.state != .cancelled && $0.providerFailure == nil
        }
        let stalls = stallCauses(history, now: now)
        let resters = resting(history, now: now)

        /// What keeps `offer` from this piece, or nil when it may run.
        func blocker(_ offer: ModelCatalog.Offer) -> PickReason.Cause? {
            guard offers.contains(offer), installed.contains(offer.cli), !excluded.contains(offer.cli),
                  !excludedWorkers.contains(offer)
            else { return .unavailable }
            if switchedOff.contains(offer.cli) { return .switchedOff }
            switch offer.cli {
            case .claude, .opencode: break
            case .cursor: if needsCommands { return .unavailable }
            case .gemini: if needsCommands || access != .read || !geminiKinds.contains(kind) { return .unavailable }
            }
            if let stall = stalls[offer.cli] { return stall }
            return resters[offer] == nil ? nil : .resting
        }

        let eligible = offers.filter { blocker($0) == nil }
        let tier = lineup.tier(difficulty)
        let tierEligible = tier.filter { blocker($0) == nil }
        func demoted(_ worker: ModelCatalog.Offer) -> Demotion? {
            let next = tierEligible.drop { $0 != worker }.dropFirst().first
            return demotion(of: worker, kind: kind, difficulty: difficulty, history: history, next: next)
        }
        func candidate(_ offer: ModelCatalog.Offer) -> Candidate {
            Candidate(
                offer: offer, order: offers.firstIndex(of: offer) ?? offers.count,
                runs: ofKind.filter { isRun($0, of: offer) }, difficulty: difficulty
            )
        }

        // A redo is not the piece to learn on: it already went wrong once.
        if excludedWorkers.isEmpty, let learner = learningTurn(
            kind: kind, difficulty: difficulty, ofKind: ofKind, offers: offers, eligible: eligible,
            demotedInLineup: tierEligible.filter { demoted($0) != nil }, candidate: candidate, now: now,
            everRan: { offer in history.contains { isRun($0, of: offer) } }
        ) {
            return Choice(offer: learner, pick: PickReason(code: .learning, text: "learning turn"))
        }

        if let index = tier.firstIndex(where: { blocker($0) == nil && demoted($0) == nil }) {
            // Proved outside the lineup, and over twice as fast as its pick.
            let mine = candidate(tier[index])
            let proven = difficulty == .hard || mine.deliveries < deliveriesToCompare ? [] :
                strengthPool(eligible.filter { !tier.contains($0) }, difficulty: difficulty).map(candidate).filter {
                    $0.deliveries >= deliveriesToCompare && $0.ratings >= ratingsToDemote
                        && ($0.average ?? 0) >= Double(Rating.satisfactory) && $0.coldUntil.map { $0 <= now } ?? true
                        && $0.costRank <= mine.costRank && $0.medianSeconds * slowerThan < mine.medianSeconds
                }
            if let faster = proven.min(by: { ($0.medianSeconds, $0.order) < ($1.medianSeconds, $1.order) }) {
                return Choice(offer: faster.offer, pick: PickReason(
                    code: .record,
                    text: "not in the lineup: rated \(Rating.satisfactory)+ and over twice as fast as \(shortName(mine.offer)) on \(kind.rawValue)"
                ))
            }
            return lineupChoice(
                tier, at: index, difficulty: difficulty, kind: kind,
                why: { blocker($0) ?? demoted($0).map { _ in .demoted } }, demoted: demoted, resters: resters
            )
        }

        // Nobody in the lineup may run: the others, by their record.
        let others = strengthPool(eligible.filter { !tier.contains($0) }, difficulty: difficulty).map(candidate)
            // Known bad on this kind, at this effort: never picked on its own.
            .filter { $0.average.map { $0 >= Double(Rating.satisfactory) } ?? true }
            .filter { $0.coldUntil.map { $0 <= now } ?? true }
            // Nor one that has run twice here and delivered nothing.
            .filter { $0.runs.count < deliveriesToLearn || $0.delivered > 0 }
        let good = others.filter { ($0.average ?? 0) >= Double(Rating.satisfactory) }
        if let best = good.min(by: {
            ($0.medianSeconds, $0.medianCost, $0.order) < ($1.medianSeconds, $1.medianCost, $1.order)
        }) {
            return Choice(offer: best.offer, pick: PickReason(
                code: .record, text: "not in the lineup: fastest rated \(Rating.satisfactory)+ on \(kind.rawValue)"
            ))
        }
        if let cheapest = others.min(by: { ($0.costRank, $0.order) < ($1.costRank, $1.order) }) {
            return Choice(offer: cheapest.offer, pick: PickReason(
                code: .cheapest, text: "not in the lineup: cheapest that may run"
            ))
        }
        // Only demoted lineup workers are left: the first of them.
        guard let fallback = tierEligible.first, let index = tier.firstIndex(of: fallback) else { return nil }
        return Choice(offer: fallback, pick: PickReason(
            code: .lineup,
            text: "\(ordinal(index + 1)) in your lineup: demoted, but nobody else may run",
            position: index + 1
        ))
    }

    /// The choice of `tier[index]`, saying why those before it were passed.
    private static func lineupChoice(
        _ tier: [ModelCatalog.Offer], at index: Int, difficulty: Difficulty, kind: TaskKind,
        why: (ModelCatalog.Offer) -> PickReason.Cause?, demoted: (ModelCatalog.Offer) -> Demotion?,
        resters: [ModelCatalog.Offer: Date]
    ) -> Choice {
        let worker = tier[index]
        let place = ordinal(index + 1)
        // A worker that is not installed or cannot run this piece is not news;
        // one that is out, resting or demoted is.
        let skipped = tier.prefix(index).compactMap { worker in why(worker).map { (worker, $0) } }
        guard let (passed, cause) = skipped.first(where: { $0.1 != .unavailable }) else {
            return Choice(offer: worker, pick: PickReason(
                code: .lineup, text: "\(place) in your lineup for \(difficulty.rawValue) pieces", position: index + 1
            ))
        }
        let said: String
        switch cause {
        case .quota: said = "is out of quota"
        case .signedOut: said = "is signed out"
        case .down: said = "is down"
        case .resting:
            said = "is resting until \(resters[passed].map(clock) ?? "later") after \(restingAfter) failures in a row"
        case .demoted, .slow:
            switch demoted(passed) {
            case let .rating(average)?: said = "is demoted, rated \(String(format: "%.1f", average)) on \(kind.rawValue)"
            case let .slow(than)?: said = "is demoted, over twice as slow as \(shortName(than)) on \(kind.rawValue)"
            case nil: said = "is demoted"
            }
        case .unavailable: said = "cannot take this piece"
        case .switchedOff: said = "is switched off"
        }
        let slow: Bool = if case .slow = demoted(passed) { true } else { false }
        // A switch is the CLI's, not the model's: say which CLI.
        let who = cause == .switchedOff ? passed.cli.rawValue : shortName(passed)
        return Choice(offer: worker, pick: PickReason(
            code: .lineup, text: "\(place) in your lineup: \(who) \(said)", position: index + 1,
            passed: passed.model.split(separator: "/").last.map(String.init) ?? passed.model,
            cause: cause == .demoted && slow ? .slow : cause
        ))
    }

    /// The worker for this piece when it is a learning turn, or nil.
    ///
    /// Every fifth piece of a kind and difficulty, unless the last one was a
    /// learning turn too: the lineup's first keeps the work it is given.
    private static func learningTurn(
        kind: TaskKind, difficulty: Difficulty, ofKind: [Run], offers: [ModelCatalog.Offer],
        eligible: [ModelCatalog.Offer], demotedInLineup: [ModelCatalog.Offer],
        candidate: (ModelCatalog.Offer) -> Candidate, now: Date, everRan: (ModelCatalog.Offer) -> Bool
    ) -> ModelCatalog.Offer? {
        let same = ofKind.filter { ($0.spec.difficulty ?? .normal) == difficulty }
        guard !same.isEmpty, same.count % explorationEvery == 0,
              same.max(by: { $0.started < $1.started })?.pick?.code != .learning
        else { return nil }
        // A hard piece learns among strong workers only.
        let pool = difficulty == .hard ? eligible.filter(isStrong) : strengthPool(eligible, difficulty: difficulty)
        func isCold(_ offer: ModelCatalog.Offer) -> Bool { candidate(offer).coldUntil.map { $0 > now } ?? false }
        if let back = demotedInLineup.first(where: { pool.contains($0) && !isCold($0) }) { return back }
        func cliRuns(_ offer: ModelCatalog.Offer) -> Int { ofKind.filter { $0.spec.cli == offer.cli }.count }
        return pool.map(candidate)
            .filter { !isCold($0.offer) }
            // Still unknown here, or back from the cold for another chance.
            .filter { $0.deliveredHere < deliveriesToLearn || $0.coldUntil != nil }
            .filter { lowerEffortTried($0.offer, offers: offers, ofKind: ofKind) }
            // A worker that never ran anything goes before one known from another kind.
            .map { (candidate: $0, used: everRan($0.offer) ? 1 : 0) }
            .min {
                ($0.candidate.costRank, $0.used, cliRuns($0.candidate.offer), $0.candidate.order)
                    < ($1.candidate.costRank, $1.used, cliRuns($1.candidate.offer), $1.candidate.order)
            }?
            .candidate.offer
    }

    /// A hard piece goes to a strong worker when one may run, an easy one to a
    /// light worker when one may.
    private static func strengthPool(_ workers: [ModelCatalog.Offer], difficulty: Difficulty) -> [ModelCatalog.Offer] {
        let strong = workers.filter(isStrong)
        let light = workers.filter { !isStrong($0) }
        switch difficulty {
        case .hard: return strong.isEmpty ? workers : strong
        case .easy: return light.isEmpty ? workers : light
        case .normal: return workers
        }
    }

    /// Why the record passes over `worker`, a lineup worker, on this kind:
    /// rated below 4 on average over two ratings or more, or more than twice
    /// as slow on this kind and difficulty as `next`, the lineup worker after
    /// it, with three deliveries each.
    public static func demotion(
        of worker: ModelCatalog.Offer, kind: TaskKind, difficulty: Difficulty, history: [Run], next: ModelCatalog.Offer?
    ) -> Demotion? {
        func runs(_ offer: ModelCatalog.Offer) -> [Run] {
            history.filter {
                ($0.spec.kind ?? .other) == kind && $0.state != .cancelled && $0.providerFailure == nil && isRun($0, of: offer)
            }
        }
        let mine = runs(worker)
        let ratings = mine.compactMap { $0.rating?.score }
        if ratings.count >= ratingsToDemote {
            let average = Double(ratings.reduce(0, +)) / Double(ratings.count)
            if average < Double(Rating.satisfactory) { return .rating(average) }
        }
        guard let next else { return nil }
        func times(_ runs: [Run]) -> [TimeInterval] {
            runs.filter { ($0.spec.difficulty ?? .normal) == difficulty && isDelivery($0) }.map(\.duration)
        }
        let own = times(mine)
        let theirs = times(runs(next))
        guard own.count >= deliveriesToCompare, theirs.count >= deliveriesToCompare,
              let slow = Scoreboard.median(own), let fast = Scoreboard.median(theirs),
              slow > slowerThan * fast
        else { return nil }
        return .slow(than: next)
    }

    /// "1st", "2nd", "3rd", "4th".
    static func ordinal(_ number: Int) -> String {
        let suffix: String
        switch (number % 10, number % 100) {
        case (1, let tens) where tens != 11: suffix = "st"
        case (2, let tens) where tens != 12: suffix = "nd"
        case (3, let tens) where tens != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(number)\(suffix)"
    }

    /// A worker as a reason has room for it: `opus (low)`, `glm-5.3-flash-free`.
    public static func shortName(_ offer: ModelCatalog.Offer) -> String {
        (offer.model.split(separator: "/").last.map(String.init) ?? offer.model) + (offer.effort.map { " (\($0))" } ?? "")
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
        /// Deliveries at the piece's own difficulty: a worker known on normal
        /// pieces is still unknown on hard ones, and learns there too.
        var deliveredHere: Int { Self.delivered(runs.filter { ($0.spec.difficulty ?? .normal) == difficulty }).count }

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

        var deliveries: Int { Self.delivered(ranked).count }
        var ratings: Int { ranked.compactMap { $0.rating?.score }.count }

        /// Until when the worker is left out of this kind: its latest runs
        /// here failed or were rated below satisfactory. A day for one, twice
        /// as long for each more in a row; nil when the latest verdict is good.
        var coldUntil: Date? {
            var streak = 0
            var last: Date?
            for run in runs.sorted(by: { $0.started > $1.started }) {
                if Scoreboard.hasFailed(run) || run.rating.map({ !$0.isSatisfactory }) == true {
                    streak += 1
                    last = last ?? run.ended ?? run.started
                } else if run.rating != nil {
                    break
                }
            }
            guard let last else { return nil }
            return last.addingTimeInterval(min(WorkerPicker.cold * pow(2, Double(streak - 1)), WorkerPicker.coldCap))
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
    }

    /// Whether `run` is `offer`: the same CLI, model and effort.
    public static func isRun(_ run: Run, of offer: ModelCatalog.Offer) -> Bool {
        run.spec.cli == offer.cli && run.spec.model == offer.model && run.spec.effort == offer.effort
    }

    // MARK: Strength

    /// Whether `offer` is a worker for a hard piece: claude sonnet and opus at
    /// any effort, claude haiku only at high, and the Groks at high or xhigh.
    /// opencode's free models are never strong, and nor is gemini.
    public static func isStrong(_ offer: ModelCatalog.Offer) -> Bool {
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
    public static func split(cli: WorkerCLI, model: String, effort: String?) -> (base: String, effort: String?) {
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
        Set(stallCauses(history, now: now).keys)
    }

    /// The CLIs to leave alone for now, each with what its provider said; a
    /// quick failure with no words is taken for a quota.
    static func stallCauses(_ history: [Run], now: Date) -> [WorkerCLI: PickReason.Cause] {
        var stalled: [WorkerCLI: PickReason.Cause] = [:]
        for (cli, runs) in Dictionary(grouping: history, by: \.spec.cli) {
            guard let latest = runs.max(by: { $0.started < $1.started }) else { continue }
            if let said = runs.filter({ $0.providerFailure != nil }).max(by: { $0.started < $1.started }),
               let failure = said.providerFailure {
                let recovered = runs.contains { $0.started > said.started && isDelivery($0) }
                let since = now.timeIntervalSince(said.ended ?? said.started)
                if !recovered, failure.stall.map({ since < $0 }) ?? true {
                    switch failure {
                    case .quota: stalled[cli] = .quota
                    case .signedOut: stalled[cli] = .signedOut
                    case .unavailable: stalled[cli] = .down
                    }
                }
                // The words settle it, whichever way: no guessing from speed.
                if latest.providerFailure != nil { continue }
            }
            guard case let .finished(exitCode) = latest.state,
                  exitCode != 0 || Scoreboard.hasFailed(latest),
                  latest.duration < quickFailure,
                  now.timeIntervalSince(latest.started) < quotaMemory
            else { continue }
            stalled[cli] = .quota
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
    public static func resting(_ history: [Run], now: Date) -> [ModelCatalog.Offer: Date] {
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
