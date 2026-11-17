import Foundation

/// What kind of work a worker was given.
///
/// A fixed, short list rather than free text: the point of the tag is to
/// compare like with like, and "review", "code review" and "reviewing" would
/// be three kinds with one run each.
public enum TaskKind: String, Codable, Sendable, CaseIterable {
    /// Reading, searching and mapping code; answering questions about it.
    case explore
    /// Judging work that exists: a diff, a design, a test suite.
    case review
    /// Writing or changing code, fixes included.
    case implement
    /// Writing tests or running them.
    case test
    /// Writing documentation.
    case docs
    /// Shipping reviewed work to production and seeing it land: following
    /// the project's procedure, watching it through, proving it is up.
    case deploy
    /// Anything else, and every run that was not tagged.
    case other
}

/// The orchestrator's verdict on what a worker delivered.
public struct Rating: Codable, Equatable, Sendable {
    /// 1 to 5. Five is usable as delivered; one is unusable.
    public let score: Int
    /// What was good or wrong with it, in the orchestrator's words.
    public let note: String?
    public let rated: Date

    public static let scores = 1...5

    /// The lowest score that still means the worker delivered what was asked.
    /// Three is "usable after real fixes": the orchestrator had to redo part
    /// of it, so the piece was not delivered.
    public static let satisfactory = 4

    public var isSatisfactory: Bool { score >= Self.satisfactory }

    public init(score: Int, note: String?, rated: Date) {
        self.score = score
        self.note = note
        self.rated = rated
    }
}

/// How one model has done at one kind of task.
public struct ModelScore: Equatable, Sendable {
    public let kind: TaskKind
    public let cli: WorkerCLI
    public let model: String
    /// The effort the model ran at, where that is set apart from the model.
    public let effort: String?
    /// Runs that came to a verdict: delivered, failed or lost.
    public let runs: Int
    /// How many of them the orchestrator rated.
    public let rated: Int
    /// The average rating, or nil when none was rated.
    public let averageScore: Double?
    /// Runs that did not deliver what was asked: those that never produced a
    /// result, and those whose result the orchestrator rated unsatisfactory.
    public let failures: Int
    /// The median time of the runs that delivered, or nil when none did.
    public let medianSeconds: TimeInterval?
    public let costUSD: Double
    /// How many of the runs were easy, normal and hard pieces; a record with
    /// no difficulty counts as normal.
    public let difficulties: [Difficulty: Int]

    public init(
        kind: TaskKind,
        cli: WorkerCLI,
        model: String,
        effort: String?,
        runs: Int,
        rated: Int,
        averageScore: Double?,
        failures: Int,
        medianSeconds: TimeInterval?,
        costUSD: Double,
        difficulties: [Difficulty: Int] = [:]
    ) {
        self.difficulties = difficulties
        self.kind = kind
        self.cli = cli
        self.model = model
        self.effort = effort
        self.runs = runs
        self.rated = rated
        self.averageScore = averageScore
        self.failures = failures
        self.medianSeconds = medianSeconds
        self.costUSD = costUSD
    }

    var failureRate: Double { runs == 0 ? 0 : Double(failures) / Double(runs) }

    /// Whether what it delivers is, on average, what was asked for. Nil until
    /// it has been rated at all.
    var deliversWell: Bool? { averageScore.map { $0 >= Double(Rating.satisfactory) } }

    /// How long a delivery that stands takes, counting the goes that have to
    /// be done again: a worker that delivers in four seconds one time in two
    /// costs eight. Nil when it has never delivered.
    /// What a delivery that stands costs in time and money together, so that
    /// a fast, cheap worker that does well comes before a slow, dear one that
    /// does a little better. A dollar weighs as much as a minute of waiting.
    public var burden: Double? {
        guard let expectedSeconds, runs > 0 else { return nil }
        let costPerDelivery = costUSD / Double(runs) / max(1 - failureRate, 0.01)
        return expectedSeconds + Self.secondsPerDollar * costPerDelivery
    }

    static let secondsPerDollar: Double = 60

    public var expectedSeconds: TimeInterval? {
        guard let medianSeconds, failureRate < 1 else { return nil }
        return medianSeconds / (1 - failureRate)
    }
}

/// Turns the history of runs into a ranking of models, per kind of task.
public enum Scoreboard {
    /// The models that have been tried, best first within each kind.
    ///
    /// Quality is a bar to clear, not a race: a worker either delivers what
    /// was asked or it does not. Among those that do, the fastest comes first
    /// — the user is waiting on the clock, and if quality alone mattered every
    /// piece would go to the strongest model. So the order is: those that
    /// deliver well, fastest first; then those nobody has rated yet, which may
    /// be good; last, those known to fall short, best of them first.
    ///
    /// Runs still going, or stopped by the user, are left out entirely: they
    /// are no verdict on the model either way. Nor is a run that did not run
    /// because its provider was out of quota, signed out or down.
    public static func scores(_ runs: [Run], kind: TaskKind? = nil) -> [ModelScore] {
        struct Key: Hashable {
            let kind: TaskKind
            let cli: WorkerCLI
            let model: String
            let effort: String?
        }
        let judged = runs.filter { run in
            guard run.providerFailure == nil else { return false }
            switch run.state {
            case .finished, .lost: return kind == nil || (run.spec.kind ?? .other) == kind
            case .running, .cancelled: return false
            }
        }
        let groups = Dictionary(grouping: judged) {
            Key(kind: $0.spec.kind ?? .other, cli: $0.spec.cli, model: $0.spec.model, effort: $0.spec.effort)
        }

        let scores = groups.map { key, runs -> ModelScore in
            let delivered = runs.filter { !hasFailed($0) }
            let ratings = runs.compactMap { $0.rating?.score }
            // A worker that ran clean and handed back the wrong thing failed
            // just as surely as one that crashed, and more usefully to know.
            let unsatisfactory = delivered.filter { $0.rating?.isSatisfactory == false }
            return ModelScore(
                kind: key.kind,
                cli: key.cli,
                model: key.model,
                effort: key.effort,
                runs: runs.count,
                rated: ratings.count,
                averageScore: ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count),
                failures: runs.count - delivered.count + unsatisfactory.count,
                // A failure's two seconds say nothing about how long a
                // delivery takes, so only deliveries are timed.
                medianSeconds: median(delivered.map(\.duration)),
                costUSD: runs.reduce(0) { $0 + ($1.output?.costUSD ?? 0) },
                difficulties: runs.reduce(into: [:]) { $0[$1.spec.difficulty ?? .normal, default: 0] += 1 }
            )
        }

        let order = Dictionary(uniqueKeysWithValues: TaskKind.allCases.enumerated().map { ($1, $0) })
        return scores.sorted { left, right in
            if left.kind != right.kind { return (order[left.kind] ?? 0) < (order[right.kind] ?? 0) }
            let tier = { (score: ModelScore) in score.deliversWell == true ? 0 : (score.deliversWell == nil ? 1 : 2) }
            if tier(left) != tier(right) { return tier(left) < tier(right) }
            // Those that fall short are ranked by how short; the rest by speed.
            if tier(left) == 2, left.averageScore != right.averageScore {
                return (left.averageScore ?? 0) > (right.averageScore ?? 0)
            }
            if left.burden != right.burden {
                return (left.burden ?? .infinity) < (right.burden ?? .infinity)
            }
            if left.averageScore != right.averageScore {
                return (left.averageScore ?? -1) > (right.averageScore ?? -1)
            }
            return (left.model, left.effort ?? "") < (right.model, right.effort ?? "")
        }
    }

    /// The ranking as text for the orchestrating model.
    ///
    /// With `offers`, each kind also says who the picker would choose next
    /// and which offered workers have no run on it: that holds for a kind
    /// with no runs at all too, which is where it matters most.
    public static func summary(
        _ scores: [ModelScore],
        kind: TaskKind? = nil,
        offers: [ModelCatalog.Offer] = [],
        history: [Run] = [],
        lineup: Lineup = .standard,
        now: Date = Date()
    ) -> String {
        guard !scores.isEmpty || !offers.isEmpty else {
            let what = kind.map { "a \($0.rawValue) task" } ?? "a run"
            return "No worker has finished \(what) yet, so there is nothing to compare."
        }
        var lines = ["Worker models by kind of task, best first (score is the average of your agent_rate ratings, 1 to 5):"]
        // (Within a kind: those rated 4 or better, fastest first; then the unrated; then the rest.)
        for each in kind.map({ [$0] }) ?? TaskKind.allCases {
            let ofKind = scores.filter { $0.kind == each }
            let extra = [
                nextLine(offers, history: history, kind: each, lineup: lineup, now: now),
                untriedLine(offers, history: history, kind: each),
            ].compactMap { $0 } + (each == .review ? focusLines(history) : [])
            guard !ofKind.isEmpty || !extra.isEmpty else { continue }
            lines.append(each.rawValue)
            lines.append(contentsOf: ofKind.map { "  " + line($0) })
            lines.append(contentsOf: extra)
        }
        let resting = WorkerPicker.resting(history, now: now)
        if !resting.isEmpty {
            lines.append("resting")
            lines.append(contentsOf: resting.sorted { $0.key.name < $1.key.name }.map {
                "  \($0.key.name) — resting until \(WorkerPicker.clock($0.value)) after \(WorkerPicker.restingAfter) failures in a row"
            })
        }
        // With no catalogue there is nothing to pick from, and no lineup to show.
        if !offers.isEmpty {
            lines.append(contentsOf: lineupLines(lineup, history: history, kinds: kind.map { [$0] } ?? TaskKind.allCases))
        }
        return lines.joined(separator: "\n")
    }

    /// The user's three lineups, in order, each worker marked where its record
    /// demotes it.
    static func lineupLines(_ lineup: Lineup, history: [Run], kinds: [TaskKind]) -> [String] {
        var lines = ["the user's lineup (Vitra picks the first that may run and is not demoted)"]
        for difficulty in [Difficulty.hard, .normal, .easy] {
            let tier = lineup.tier(difficulty)
            let workers = tier.enumerated().map { index, worker in
                let next = tier.dropFirst(index + 1).first
                let marks = kinds.compactMap { kind -> String? in
                    switch WorkerPicker.demotion(of: worker, kind: kind, difficulty: difficulty, history: history, next: next) {
                    case let .rating(average)?: return "rated \(String(format: "%.1f", average)) on \(kind.rawValue)"
                    case .slow?: return "slow on \(kind.rawValue)"
                    case nil: return nil
                    }
                }
                let mark = marks.isEmpty ? "" : " [demoted: " + marks.joined(separator: ", ") + "]"
                return "\(index + 1). \(worker.name)\(mark)"
            }
            lines.append("  \(difficulty.rawValue): " + (workers.isEmpty ? "empty" : workers.joined(separator: ", ")))
        }
        return lines
    }

    /// Who the picker would choose next for `kind` (a piece that only reads
    /// and runs no commands), and why; nil when nothing is offered or may run.
    static func nextLine(
        _ offers: [ModelCatalog.Offer], history: [Run], kind: TaskKind, lineup: Lineup = .standard, now: Date = Date()
    ) -> String? {
        guard let choice = WorkerPicker.pick(
            kind: kind, access: .read, needsCommands: false, history: history,
            offers: offers, installed: Set(offers.map(\.cli)), lineup: lineup, now: now
        ) else { return nil }
        return "  vitra picks next: \(choice.offer.name) — \(choice.reason)"
    }

    /// Rated audits of a focus needed before its best auditor is named.
    static let ratedAuditsPerFocus = 2

    /// One line per audit focus with two rated audits or more: the auditor
    /// rated best on it, so the record says who audits security well.
    static func focusLines(_ history: [Run]) -> [String] {
        let rated = history.filter { $0.spec.isAudit && $0.rating != nil && $0.providerFailure == nil }
        return AuditFocus.allCases.compactMap { focus in
            let audits = rated.filter { $0.spec.auditFocus?.contains(focus) == true }
            guard audits.count >= ratedAuditsPerFocus else { return nil }
            let byWorker = Dictionary(grouping: audits) { $0.spec.worker }.map { worker, runs in
                (worker, Double(runs.compactMap { $0.rating?.score }.reduce(0, +)) / Double(runs.count), runs.count)
            }
            guard let best = byWorker.max(by: { ($0.1, $0.2, $1.0) < ($1.1, $1.2, $0.0) }) else { return nil }
            return "  audits of \(focus.rawValue): best rated \(best.0) — "
                + String(format: "%.1f/5 over %d of %d rated", best.1, best.2, audits.count)
        }
    }

    /// How many untried workers are named before the rest are counted.
    static let untriedNamed = 15

    /// The offered workers with no run of `kind` in `history`, as one line
    /// for that kind; nil when there are none or nothing is offered.
    public static func untriedLine(_ offers: [ModelCatalog.Offer], history: [Run], kind: TaskKind) -> String? {
        // A worker is its CLI, model and effort: haiku at low having run says
        // nothing of haiku at high.
        let ofKind = history.filter { ($0.spec.kind ?? .other) == kind && $0.providerFailure == nil }
        let untried = offers.filter { offer in !ofKind.contains { WorkerPicker.isRun($0, of: offer) } }
        guard !untried.isEmpty else { return nil }
        let named = untried.prefix(untriedNamed).map(\.name)
        let rest = untried.count - named.count
        let tail = rest > 0 ? ", and \(rest) more" : ""
        return "  not tried yet: " + named.joined(separator: ", ") + tail
    }

    private static func line(_ score: ModelScore) -> String {
        var fields = [
            score.averageScore.map { String(format: "%.1f/5 over %d rated", $0, score.rated) } ?? "unrated",
            "\(score.runs) \(score.runs == 1 ? "run" : "runs")",
            "\(score.failures) failed",
        ]
        if let median = score.medianSeconds {
            fields.append("median \(Int(median.rounded()))s")
            fields.append(String(format: "$%.2f", score.costUSD))
        }
        // Said only when some piece was not a normal one: otherwise it is noise.
        if score.difficulties.contains(where: { $0.key != .normal }) {
            fields.append(Difficulty.allCases.compactMap { level in
                score.difficulties[level].map { "\($0) \(level.rawValue)" }
            }.joined(separator: ", "))
        }
        let effort = score.effort.map { " (\($0))" } ?? ""
        return "\(score.cli.rawValue) \(score.model)\(effort) — " + fields.joined(separator: " · ")
    }

    /// Whether a run did not deliver: it was lost, or its result is an error.
    public static func hasFailed(_ run: Run) -> Bool {
        run.state == .lost || run.output?.isError == true
    }

    public static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
