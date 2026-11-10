import Foundation

/// Two rules agent_spawn holds the maestro to, so the record it chooses by
/// is earned and not just the first worker it happened to like.
///
/// - Trial: until workers from three providers have been rated on a kind of
///   task, a worker already rated on it is not used again for it.
/// - Ladder: a model is tried at its lowest effort before a higher one. A
///   cheap, fast worker that does the job well is the better worker, and
///   that is only found out by trying it first.
public enum TrialRules {
    /// How many providers must have a rating on a kind before reuse is free.
    public static let providersToCompare = 3

    static let ladder = ["minimal", "low", "medium", "high", "xhigh", "max"]

    /// Why `spec` should not run now, given every run so far; nil when it may.
    /// `providers` is how many worker CLIs are installed.
    public static func problem(with spec: WorkerSpec, history: [Run], providers: Int) -> String? {
        let kind = spec.kind ?? .other
        let judged = history.filter { ($0.spec.kind ?? .other) == kind && $0.state != .running && $0.state != .cancelled }
        let (base, effort) = split(spec)

        // Ladder first: it names the worker to use instead.
        if let effort, let rank = ladder.firstIndex(of: effort), let lowest = lowestEffort(spec, base: base),
           let lowestRank = ladder.firstIndex(of: lowest), rank > lowestRank {
            let triedLower = judged.contains { run in
                guard run.spec.cli == spec.cli else { return false }
                let (otherBase, otherEffort) = split(run.spec)
                return otherBase == base && (otherEffort.flatMap { ladder.firstIndex(of: $0) } ?? 0) < rank
            }
            if !triedLower {
                return "\(spec.cli.rawValue) \(base) has not been tried on \(kind.rawValue) at a lower effort yet: "
                    + "use \(named(spec, base: base, effort: lowest)) first. A higher effort is for after the lower one fell short."
            }
        }

        let rated = judged.filter { $0.rating != nil }
        let ratedProviders = Set(rated.map(\.spec.cli))
        let needed = min(providersToCompare, max(providers, 1))
        let alreadyRated = rated.contains { $0.spec.cli == spec.cli && $0.spec.model == spec.model && $0.spec.effort == spec.effort }
        if ratedProviders.count < needed, alreadyRated {
            return "\(kind.rawValue) is still in its trial: \(ratedProviders.count) of \(needed) providers have a rating on it, "
                + "and \(spec.worker) already has one. Use a worker with no record on \(kind.rawValue) — from a provider "
                + "not rated yet, fast and cheap first (agent_models lists them)."
        }
        return nil
    }

    /// The model without its effort, and the effort: apart for claude and
    /// opencode, inside the id for cursor and gemini (grok-4.7-low-fast).
    static func split(_ spec: WorkerSpec) -> (base: String, effort: String?) {
        switch spec.cli {
        case .claude, .opencode:
            return (spec.model, spec.effort)
        case .cursor, .gemini:
            let words = spec.model.split(separator: "-").map(String.init)
            guard let index = words.lastIndex(where: { ladder.contains($0) }) else { return (spec.model, nil) }
            var rest = words
            rest.remove(at: index)
            return (rest.joined(separator: "-"), words[index])
        }
    }

    /// The lowest effort `spec`'s model is offered at.
    private static func lowestEffort(_ spec: WorkerSpec, base: String) -> String? {
        switch spec.cli {
        case .claude:
            let efforts = ModelCatalog.claudeWorkers.first { $0.model == base }?.efforts ?? []
            return efforts.min { (ladder.firstIndex(of: $0) ?? 0) < (ladder.firstIndex(of: $1) ?? 0) }
        case .opencode, .cursor, .gemini:
            return "low"
        }
    }

    /// How a worker at `effort` is written for this CLI.
    private static func named(_ spec: WorkerSpec, base: String, effort: String) -> String {
        switch spec.cli {
        case .claude, .opencode: return "\(base) at effort \(effort)"
        case .cursor, .gemini:
            // The effort goes back where it was: grok-4.7-low-fast, not grok-4.7-fast-low.
            let words = spec.model.split(separator: "-").map(String.init)
            guard let index = words.lastIndex(where: { ladder.contains($0) }) else { return base }
            var renamed = words
            renamed[index] = effort
            return renamed.joined(separator: "-")
        }
    }
}
