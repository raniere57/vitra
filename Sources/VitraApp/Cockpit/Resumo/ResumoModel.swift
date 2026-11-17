import Foundation
import VitraOrchestrator

/// What the runs of a stretch of time cost and came to.
struct SpendTotals: Equatable, Sendable {
    var cost = 0.0
    var tokens = 0
    /// Runs that finished and handed back a result.
    var deliveries = 0
    /// Runs that were lost or whose result is an error, provider failures included.
    var failures = 0
}

/// Whether a provider can take work now, as the runs on disk tell it.
enum Availability: Equatable, Sendable {
    case ok
    /// Its latest run hit a usage limit; back, by the picker's reckoning, at `until`.
    case noQuota(until: Date)
    /// Its latest run found the service down; tried again from `until`.
    case down(until: Date)
    /// Its latest run asked for a sign-in: out until the user signs in again.
    case signedOut
    /// The picker's circuit breaker rests one or more of its workers.
    case resting(until: Date, workers: [String])
}

/// One line of the providers table.
struct ProviderRow: Equatable, Sendable {
    let cli: WorkerCLI
    let deliveries: Int
    let cost: Double
    /// The median time of today's deliveries, nil when there were none.
    let medianSeconds: TimeInterval?
    let availability: Availability
}

/// A day's worker cost, for the sparkline.
struct DayCost: Equatable, Sendable {
    /// The start of the day.
    let day: Date
    let cost: Double
}

/// The Claude subscription's two windows, as the maestro's status line last
/// wrote them. Nil fields were not reported.
struct SubscriptionBars: Equatable, Sendable {
    enum Level: Equatable, Sendable { case calm, warm, hot }
    let week: Double?
    let fiveHour: Double?

    static func level(_ percent: Double) -> Level {
        percent >= ProviderChips.hotFrom ? .hot : (percent >= ProviderChips.warmFrom ? .warm : .calm)
    }
}

/// Everything the Resumo tab shows, worked out in one go off the main thread.
struct Resumo: Sendable {
    let today: SpendTotals
    let week: SpendTotals
    let allToday: SpendTotals
    let allWeek: SpendTotals
    let providers: [ProviderRow]
    let subscription: SubscriptionBars?
    let days: [DayCost]
    /// The project's last trabalhos, newest first.
    let trabalhos: [Trabalho]
    let facts: [String]
    let now: Date
    let calendar: Calendar

    static let shownTrabalhos = 20
    static let days = 7
    /// Past this the usage figure is no longer the week's.
    static let usageStaleAfter: TimeInterval = 48 * 3600

    /// - Parameters:
    ///   - runs: every run read, of every project, newest or not.
    ///   - project: the project on screen.
    static func make(
        runs: [Run], project: CockpitProject, usage: SubscriptionUsage?, now: Date, calendar: Calendar = .current
    ) -> Resumo {
        let mine = WorkerBoard.runs(runs, in: project)
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let groups = Trabalho.group(mine)
        return Resumo(
            today: totals(mine, from: today),
            week: totals(mine, from: weekStart),
            allToday: totals(runs, from: today),
            allWeek: totals(runs, from: weekStart),
            providers: providerRows(runs, now: now, calendar: calendar),
            subscription: subscriptionBars(usage, now: now),
            days: dailyCost(mine, now: now, calendar: calendar),
            trabalhos: Array(groups.prefix(shownTrabalhos)),
            facts: Retrospective.facts(
                runs: mine.filter { $0.started >= weekStart }, trabalhos: groups.filter { $0.started >= weekStart }
            ),
            now: now,
            calendar: calendar
        )
    }

    // MARK: - Totals

    static func totals(_ runs: [Run], from start: Date) -> SpendTotals {
        runs.filter { $0.started >= start }.reduce(into: SpendTotals()) { totals, run in
            totals.cost += run.output?.costUSD ?? 0
            totals.tokens += (run.output?.inputTokens ?? 0) + (run.output?.outputTokens ?? 0)
            if isDelivery(run) { totals.deliveries += 1 }
            if Scoreboard.hasFailed(run) { totals.failures += 1 }
        }
    }

    static func isDelivery(_ run: Run) -> Bool {
        if case .finished = run.state { return !Scoreboard.hasFailed(run) }
        return false
    }

    // MARK: - Providers

    static func providerRows(_ runs: [Run], now: Date, calendar: Calendar) -> [ProviderRow] {
        let today = calendar.startOfDay(for: now)
        let resting = WorkerPicker.resting(runs, now: now)
        return WorkerCLI.allCases.map { cli in
            let ofCLI = runs.filter { $0.spec.cli == cli }
            let delivered = ofCLI.filter { $0.started >= today && isDelivery($0) }
            return ProviderRow(
                cli: cli,
                deliveries: delivered.count,
                cost: ofCLI.filter { $0.started >= today }.reduce(0) { $0 + ($1.output?.costUSD ?? 0) },
                medianSeconds: Scoreboard.median(delivered.map(\.duration)),
                availability: availability(cli, runs: ofCLI, resting: resting, now: now)
            )
        }
    }

    /// The provider's own words on its latest run come first; failing those,
    /// whether the picker rests any of its workers.
    static func availability(
        _ cli: WorkerCLI, runs: [Run], resting: [ModelCatalog.Offer: Date], now: Date
    ) -> Availability {
        if let latest = runs.filter({ $0.spec.cli == cli }).max(by: { $0.started < $1.started }),
           let failure = latest.providerFailure {
            let since = latest.ended ?? latest.started
            switch failure {
            case .signedOut: return .signedOut
            case .quota:
                let until = since.addingTimeInterval(failure.stall ?? 0)
                if until > now { return .noQuota(until: until) }
            case .unavailable:
                let until = since.addingTimeInterval(failure.stall ?? 0)
                if until > now { return .down(until: until) }
            }
        }
        let mine = resting.filter { $0.key.cli == cli }
        guard let until = mine.values.max() else { return .ok }
        let names = mine.keys.map { WorkerBoard.shortName($0.model, effort: $0.effort) }.sorted()
        return .resting(until: until, workers: names)
    }

    static func subscriptionBars(_ usage: SubscriptionUsage?, now: Date) -> SubscriptionBars? {
        guard let usage, now.timeIntervalSince(usage.updated) < usageStaleAfter,
              usage.sevenDay != nil || usage.fiveHour != nil
        else { return nil }
        return SubscriptionBars(week: usage.sevenDay, fiveHour: usage.fiveHour)
    }

    // MARK: - Sparkline

    /// The worker cost of each of the last `count` days, oldest first, a day
    /// with no runs at zero.
    static func dailyCost(_ runs: [Run], now: Date, calendar: Calendar, count: Int = days) -> [DayCost] {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        var costs = Dictionary(uniqueKeysWithValues: starts.map { ($0, 0.0) })
        for run in runs {
            let day = calendar.startOfDay(for: run.started)
            if costs[day] != nil { costs[day, default: 0] += run.output?.costUSD ?? 0 }
        }
        return starts.map { DayCost(day: $0, cost: costs[$0] ?? 0) }
    }

    /// The index of the dearest day, nil when every day cost nothing.
    static func peak(_ days: [DayCost]) -> Int? {
        guard let top = days.indices.max(by: { days[$0].cost < days[$1].cost }), days[top].cost > 0 else { return nil }
        return top
    }

    // MARK: - Words

    static func availabilityText(_ availability: Availability, calendar: Calendar) -> String {
        switch availability {
        case .ok: return "ok"
        case let .noQuota(until): return "sem cota · volta ~\(clock(until, calendar: calendar))"
        case let .down(until): return "fora do ar · volta ~\(clock(until, calendar: calendar))"
        case .signedOut: return "deslogado"
        case let .resting(until, _): return "descansando até \(clock(until, calendar: calendar))"
        }
    }

    static func clock(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// "seg", "ter"… for a day under the sparkline.
    static func weekday(_ date: Date, calendar: Calendar) -> String {
        let names = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]
        return names[(calendar.component(.weekday, from: date) - 1) % 7]
    }

    /// "312k tokens · 6 entregas · 1 falha", or less when there is less to say.
    static func countsText(_ totals: SpendTotals) -> String {
        let deliveries = "\(totals.deliveries) \(totals.deliveries == 1 ? "entrega" : "entregas")"
        let failures = totals.failures == 0 ? nil : "\(totals.failures) \(totals.failures == 1 ? "falha" : "falhas")"
        return [deliveries, failures].compactMap { $0 }.joined(separator: " · ")
    }
}
