import Foundation
import VitraOrchestrator

/// One compact fact about a provider, shown in the tab bar only when it is
/// not business as usual.
struct ProviderChip: Equatable {
    enum Level: Equatable {
        /// Worth knowing: a worker CLI that is out of quota.
        case muted
        case warm
        case hot
    }

    let text: String
    let level: Level
    let tooltip: String
}

/// Works out which chips to show from what the cockpit already has in memory.
enum ProviderChips {
    static let warmFrom = 80.0
    static let hotFrom = 95.0
    /// A run counts as a quota failure only when it ended this fast: a limit
    /// is refused at the door, not after real work.
    static let quickFailure: TimeInterval = 60
    /// How far back a failure is still news, and how long a limit is assumed to last.
    static let window: TimeInterval = 3600
    /// Past this the usage figure is no longer the week's.
    private static let usageStaleAfter: TimeInterval = 48 * 3600

    static func derive(runs: [Run], usage: SubscriptionUsage?, now: Date, timeZone: TimeZone = .current) -> [ProviderChip] {
        var chips: [ProviderChip] = []
        if let week = usage?.sevenDay, let updated = usage?.updated, now.timeIntervalSince(updated) < usageStaleAfter, week >= warmFrom {
            chips.append(ProviderChip(
                text: "claude semana \(Int(week.rounded()))%",
                level: week >= hotFrom ? .hot : .warm,
                tooltip: "Uso semanal da assinatura Claude"
            ))
        }
        for cli in WorkerCLI.allCases {
            guard let failedAt = quotaFailure(of: cli, in: runs, now: now) else { continue }
            chips.append(ProviderChip(
                text: "\(cli.rawValue) sem cota · volta ~\(clock(failedAt.addingTimeInterval(window), in: timeZone))",
                level: .muted,
                tooltip: "A última tarefa de \(cli.rawValue) falhou por limite de uso; a volta é uma estimativa"
            ))
        }
        return chips
    }

    /// When the CLI's latest finished run failed on a quota or limit, if it did.
    ///
    /// Only the latest: a success since then means the limit is gone.
    static func quotaFailure(of cli: WorkerCLI, in runs: [Run], now: Date) -> Date? {
        let latest = runs
            .filter { $0.spec.cli == cli && $0.ended != nil }
            .max { ($0.ended ?? .distantPast) < ($1.ended ?? .distantPast) }
        guard let latest, let ended = latest.ended,
              now.timeIntervalSince(ended) < window,
              ended.timeIntervalSince(latest.started) < quickFailure,
              isFailure(latest),
              matchesQuota([latest.output?.text, latest.errorTail])
        else { return nil }
        return ended
    }

    private static func isFailure(_ run: Run) -> Bool {
        if run.output?.isError == true { return true }
        if case let .finished(code) = run.state { return code != 0 }
        return false
    }

    static func matchesQuota(_ texts: [String?]) -> Bool {
        let text = texts.compactMap { $0 }.joined(separator: "\n").lowercased()
        let phrases = ["usage limit", "limit reached", "quota", "rate limit"]
        return phrases.contains { text.contains($0) }
            || text.range(of: "(?<![0-9])429(?![0-9])", options: .regularExpression) != nil
    }

    private static func clock(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
