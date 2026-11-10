import Foundation

/// The quality gate every editing delivery goes through before the orchestrator
/// reads it.
///
/// Reviewing a delivery is the most expensive part of the orchestrator's job:
/// it rereads everything the worker wrote. A cheap, read-only worker from
/// another provider can do that first, and the orchestrator then reads a
/// verdict and the few places it points at. Another provider is the point: a
/// worker from the same family tends to miss what its sibling missed, and to
/// approve what it would have written itself.
public enum Audit {
    /// How much of a diff the auditor is shown.
    ///
    /// A large change can run to megabytes, and the auditor has the files in
    /// its directory: past this the prompt says the diff was cut and points at
    /// them, rather than crowding out the task and the answer.
    public static let longestDiff = 60_000

    /// The workers tried when none of the ranked reviewers can take the piece.
    ///
    /// Cheap and fast by design: the gate is meant to cost a fraction of the
    /// review it saves. Effort is nil where the CLI carries it inside the
    /// model id.
    static let cheapAuditors: [(cli: WorkerCLI, model: String, effort: String?)] = [
        (.opencode, "opencode/glm-5.3-flash-free", nil),
        (.cursor, "grok-4.7-low-fast", nil),
        (.claude, "haiku", "low"),
        (.gemini, "gemini-3.8-flash-low", nil),
    ]

    /// The worker that should audit `implementer`'s delivery, or nil when no
    /// worker may.
    ///
    /// Reviewers that have earned a record at review come first, in the order
    /// `Scoreboard` puts them; then the fixed cheap list. Both are filtered by
    /// what can actually run now: the CLI must be installed, must not be the
    /// implementer's own, and must not be refused by the trial rules for a
    /// review. Pure, so the choice can be tested without spawning anything.
    public static func chooseAuditor(
        implementer: WorkerSpec,
        history: [Run],
        installed: Set<WorkerCLI>
    ) -> (cli: WorkerCLI, model: String, effort: String?)? {
        let ranked = Scoreboard.scores(history, kind: .review).map {
            (cli: $0.cli, model: $0.model, effort: $0.effort)
        }
        for candidate in ranked + cheapAuditors {
            guard candidate.cli != implementer.cli, installed.contains(candidate.cli) else { continue }
            let spec = WorkerSpec(
                cli: candidate.cli,
                model: candidate.model,
                prompt: "review a change",
                directory: "/",
                access: .read,
                kind: .review,
                effort: candidate.effort
            )
            guard TrialRules.problem(with: spec, history: history, providers: installed.count) == nil else { continue }
            return candidate
        }
        return nil
    }

    /// What the auditor is asked: judge this change, edit nothing, and lead
    /// with a verdict the orchestrator can act on without reading the rest.
    public static func prompt(task: String, diff: String, label: String?) -> String {
        let shown = diff.count > longestDiff
            ? String(diff.prefix(longestDiff))
                + "\n… (the diff was cut: \(diff.count - longestDiff) more characters. "
                + "The changed files are in this directory — read them directly.)"
            : diff
        let name = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heading = name.isEmpty ? "" : "The change is called: \(name)\n\n"
        return """
        You are auditing a change another worker made, before the orchestrator reads it. You are read-only: \
        do not edit, commit, revert or run anything that writes. The change is checked out in this directory, \
        so read the files when the diff alone does not tell you enough.

        \(heading)The task the worker was given:
        \(task)

        The change, as a diff:
        \(shown)

        Answer with your verdict on the first line and nothing before it: exactly one of `ship`, \
        `ship after fixes` or `do not ship`. Then list only real problems, most severe first. For each, give \
        file:line and a concrete failure scenario: what input or sequence makes it go wrong, and what the user \
        then sees. Say whether the change does what was asked, whether it has bugs, whether the tests would \
        catch a regression, whether it opens a security hole, and whether it changes anything beyond the task. \
        No praise, no style nits, no summary of the diff.
        """
    }
}
