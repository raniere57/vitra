import Foundation
import VitraCore
import VitraOrchestrator

/// The tools an orchestrating agent delegates work with, and what runs them.
///
/// Unlike the panel tools these need no window: a worker is a headless process
/// and its record is a directory, so `vitra mcp` runs them itself instead of
/// forwarding them to the app.
public enum AgentTools {
    public static let all: [JSONValue] = [
        MCPTools.tool(
            "agent_spawn",
            """
            Delegate a self-contained piece of work to a worker agent on another model, and return its id at once without waiting. \
            You are the orchestrator: plan, split the work, and review what comes back; let workers do the reading and the typing. \
            Leave cli, model and effort out and Vitra picks the worker from the record of this kind of task (agent_scores shows it, agent_models lists what exists); name them only when the piece truly needs that model. \
            The worker sees nothing of this conversation, so the prompt must stand on its own: the goal, the files or area, and what done looks like. \
            Spawn several and then agent_wait on all of them to run work in parallel. \
            In a git repository each editing worker is given a worktree and a branch of its own automatically, so several can edit at once; when its delivery is done and its audit read, agent_merge with its id puts the branch on your checkout and cleans up, and agent_merge with discard drops it instead. \
            Outside a repository, give workers that edit at the same time a directory each: two editing the same checkout will overwrite one another. \
            A finished editing delivery of 40 changed lines or more is audited by a cheap read-only worker from another provider: agent_wait starts it and says its id. Pass audit true to have a smaller change audited too, false to skip the gate.
            """,
            properties: [
                "cli": [
                    "type": "string",
                    "enum": .array(WorkerCLI.allCases.map { .string($0.rawValue) }),
                    "description": "Which agent CLI runs the worker. Leave out, with model and effort, and Vitra picks the worker and says which in the result.",
                ],
                "model": MCPTools.string("Model name as that CLI takes it, from agent_models: haiku, sonnet or opus for claude, opencode/…-free for opencode, a Gemini model id for gemini, a Grok id for cursor."),
                "effort": [
                    "type": "string",
                    "enum": .array(ModelCatalog.efforts.map { .string($0) }),
                    "description": "How hard the model thinks. Required for claude when you name the worker, from the pairs agent_models lists; optional for opencode; never for gemini, which has none, or cursor, where it is part of the model id. The same model at two efforts is two workers with separate records.",
                ],
                "prompt": MCPTools.string("The whole task, self-contained."),
                "directory": MCPTools.string("Absolute path of the directory the worker runs in."),
                "access": [
                    "type": "string",
                    "enum": ["read", "edit"],
                    "description": "read (default): look, search and report, nothing is written. edit: the worker may change files in the directory.",
                ],
                "label": MCPTools.string("A few words saying what this worker is for, shown where agents are listed."),
                "commands": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Commands the worker may run by itself, each the start of a command line: \"bun test\" allows \"bun test src/x.test.ts\". Give an editing worker the project's test, build or lint command so it can check its own work instead of handing that back to you. One plain command each — no shell operators — and nothing that reaches another machine, except for a task of kind deploy, which may be given ssh to the one host it deploys to (\"ssh user@host\"). claude and gemini run exactly these; opencode's editing agent runs commands already; cursor cannot be given any. When Vitra picks the worker, giving commands keeps cursor and gemini out of the choice.",
                ],
                "kind": [
                    "type": "string",
                    "enum": .array(TaskKind.allCases.map { .string($0.rawValue) }),
                    "description": "What kind of task this is, so the model is judged against others on the same kind: explore (read, search, map code), review (judge existing work), implement (write or change code, fixes included), test (write or run tests), docs, deploy (ship reviewed work to production and watch it land), or other.",
                ],
                "audit": [
                    "type": "boolean",
                    "description": "Left out: a finished editing delivery is audited by a cheap read-only worker from another provider when it changed 40 lines or more, and agent_wait gives the audit's id. true audits it whatever its size; false skips the gate.",
                ],
                "minutes": [
                    "type": "number",
                    "description": "Time limit for this worker, 1 to 180. Left out: 45. A worker still running past it is cancelled the next time agent_wait or agent_cancel reads it, and reported as failed (timed out after N min). The automatic auditor gets 8.",
                ],
                "difficulty": [
                    "type": "string",
                    "enum": .array(Difficulty.allCases.map { .string($0.rawValue) }),
                    "description": "How hard the piece is: easy, normal or hard. Left out, Vitra judges from the prompt (hard when it names six or more files, is very long, or reshapes code across several files; easy for a short read of one file). A hard piece goes only to strong workers (claude sonnet or opus, haiku at high, Grok at high) and has no learning turns; an easy one stays off them. Say it when the default would misjudge the piece.",
                ],
            ],
            required: ["prompt", "directory"]
        ),
        MCPTools.tool(
            "agent_redo",
            """
            Send a delivery back to be fixed, with a clean context: spawns a new worker on the same piece, given the original prompt plus \
            a section \"What the previous attempt got wrong, fix exactly this:\" with your notes. An editing delivery is redone in the same \
            worktree and branch, so the new worker builds on it (a paused one gets its worktree back from the branch); the redo is the \
            delivery to audit, and agent_merge of either id merges the branch once. Use it instead of writing a new prompt from scratch. \
            Refuses while the original or its audit is still running. The same worker goes again unless you rated its delivery below 3, \
            then Vitra picks another; name cli, model and effort to choose one yourself.
            """,
            properties: [
                "id": MCPTools.string("Id of the delivery to redo, from agent_spawn."),
                "notes": MCPTools.string("What the previous attempt got wrong and must be fixed, specifically."),
                "cli": [
                    "type": "string",
                    "enum": .array(WorkerCLI.allCases.map { .string($0.rawValue) }),
                    "description": "Name the worker for the redo, with model and effort. Left out, Vitra decides.",
                ],
                "model": MCPTools.string("Model name as that CLI takes it, with cli."),
                "effort": [
                    "type": "string",
                    "enum": .array(ModelCatalog.efforts.map { .string($0) }),
                    "description": "Effort, as for agent_spawn, with cli.",
                ],
            ],
            required: ["id", "notes"]
        ),
        MCPTools.tool(
            "agent_wait",
            "Wait for worker agents to finish and return what each one reported: its answer, whether it failed, how long it took and what it cost. Returns as soon as all of them have stopped, or at the timeout with the unfinished ones marked as still running — call again to keep waiting. A worker that did not run because its provider is out of quota, signed out or down is reported as DID NOT RUN, not FAILED; when Vitra picked it, the piece is retried once on another provider and the wait goes on with the new id.",
            properties: [
                "ids": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Ids from agent_spawn.",
                ],
                "timeout_seconds": [
                    "type": "number",
                    "description": "How long to wait. Defaults to 300; 0 reports where each agent stands without waiting.",
                ],
            ],
            required: ["ids"]
        ),
        MCPTools.tool(
            "agent_list",
            "List the most recently spawned worker agents, newest first, with the state of each. Use it to find agents left running by an earlier session.",
            properties: ["limit": ["type": "number", "description": "How many to list. Defaults to 20."]],
            required: []
        ),
        MCPTools.tool(
            "agent_cancel",
            "Stop a running worker agent and every process it started. An agent that has already stopped is left as it is.",
            properties: ["id": MCPTools.string("Id from agent_spawn.")],
            required: ["id"]
        ),
        MCPTools.tool(
            "agent_merge",
            """
            Put a finished editing worker's branch onto the branch checked out in its repository, then take its worktree \
            and branch away. Refuses while the worker is still running, while its audit is reading the worktree, when \
            the checkout has uncommitted changes to tracked files or is already in the middle of a merge, and — unless \
            discard is true — when the worker left edits uncommitted in its worktree, as a failed commit does: those \
            would be deleted with it. A merge that conflicts is aborted and the files are named; the worktree and \
            branch stay so the work can be sent back. Pass discard true to drop the work without merging it. Pass pause true \
            (not with discard) to set a finished delivery aside: anything uncommitted is committed as \"wip: paused\", the \
            worktree is removed and the branch is kept; continue it later with agent_redo, or merge it with agent_merge. \
            A delivery that was redone shares its branch with the redo: merging either id merges it once.
            """,
            properties: [
                "id": MCPTools.string("Id from agent_spawn."),
                "discard": [
                    "type": "boolean",
                    "description": "Default false: merge the branch and clean up. true: drop the branch without merging it.",
                ],
                "pause": [
                    "type": "boolean",
                    "description": "Default false. true: commit what is uncommitted as wip: paused, remove the worktree, keep the branch and report its name. Not with discard.",
                ],
            ],
            required: ["id"]
        ),
        MCPTools.tool(
            "agent_models",
            "List the models a worker agent can run on, by CLI, and which CLIs are missing or signed out.",
            properties: [:],
            required: []
        ),
        MCPTools.tool(
            "agent_rate",
            "Record how good a worker's delivery was, after you have reviewed it: 5 usable as delivered, 4 right with small touch-ups, 3 usable after real fixes, 2 mostly wrong, 1 unusable. Below 4 means the worker did not deliver what was asked, and counts as a failed attempt for it. Rate every delivery you review, the bad ones above all — these ratings and the delivery times are the history future work is assigned from.",
            properties: [
                "id": MCPTools.string("Id from agent_spawn."),
                "score": ["type": "number", "description": "A whole number from 1 to 5."],
                "note": MCPTools.string("One line on what was right or wrong with it."),
            ],
            required: ["id", "score"]
        ),
        MCPTools.tool(
            "agent_scores",
            "Show how each worker has done so far, per kind of task, best first: those that deliver what was asked, fastest first; then those not rated yet; then those known to fall short. With each: average rating, runs, failures, median delivery time and cost. For each kind it also says which worker Vitra would pick next and why, and which offered workers have not been tried.",
            properties: [
                "kind": [
                    "type": "string",
                    "enum": .array(TaskKind.allCases.map { .string($0.rawValue) }),
                    "description": "Only this kind of task. Leave out for all of them.",
                ],
            ],
            required: []
        ),
    ]

    public static let names: [String] = all.compactMap { $0["name"]?.stringValue }
}

/// The gate on one run: what to add to its report, and, while an auditor is
/// reading, the audit's id (or "an auditor" while it is still being claimed).
private struct Gate {
    var line: String? = nil
    var reading: String? = nil
}

/// Runs the agent tools against an orchestrator.
public struct AgentToolExecutor: ToolExecutor {
    private static let defaultTimeout = 300
    private static let longestTimeout = 3600
    private static let defaultListLimit = 20
    /// How far back the picker looks; past runs beyond it are old news.
    private static let historyLimit = 2000
    /// How far back the scoreboard looks.
    private static let scoredRuns = 2000

    /// Changed lines, added plus removed, from which a delivery is audited
    /// without being asked. Below it the orchestrator's own read is the review.
    static let auditFromLines = 40

    /// Lines added plus removed between two commits, or nil when git cannot
    /// say. Binary files count as nothing.
    static func changedLines(from base: String, to branch: String, in repository: String) -> Int? {
        guard let stat = Git.output(["diff", "--numstat", "\(base)..\(branch)"], in: repository) else { return nil }
        return stat.split(whereSeparator: \.isNewline).reduce(0) { total, line in
            let fields = line.split(separator: "\t")
            return total + (fields.first.flatMap { Int($0) } ?? 0) + (fields.dropFirst().first.flatMap { Int($0) } ?? 0)
        }
    }

    /// How long the automatic auditor may run before it is cancelled as hung.
    static let auditMinutes = 8
    /// A `pending` audit claim older than this was left by a helper that died
    /// between taking it and writing the auditor's id.
    static let staleClaimAge: TimeInterval = 60

    private let orchestrator: Orchestrator
    private let executables: Executables
    /// The project this helper's maestro belongs to.
    private let project: String?
    /// How long a merge or an audit start waits for the repository's lock
    /// before it answers that the repository is busy.
    private let lockTimeout: TimeInterval

    /// The project the cockpit named in the maestro's shell, which this helper
    /// inherits. Absent when the helper was started outside the cockpit.
    public static var inheritedProject: String? {
        AgentIdentity.current.project
    }

    public init(executables: Executables = .discover()) {
        self.init(orchestrator: Orchestrator(executables: executables), executables: executables, project: Self.inheritedProject)
    }

    public init(
        orchestrator: Orchestrator,
        executables: Executables,
        project: String? = nil,
        lockTimeout: TimeInterval = RepositoryLock.defaultTimeout
    ) {
        self.orchestrator = orchestrator
        self.executables = executables
        self.lockTimeout = lockTimeout
        // One spelling per directory, as the cockpit keeps it.
        self.project = project.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    public func run(tool: String, arguments: JSONValue, pane: String?) async throws -> String {
        do {
            switch tool {
            case "agent_spawn":
                // A spawn that gets a worktree checks the whole repository out,
                // which can take a while: park it off the cooperative pool.
                return try await Self.offThePool { [orchestrator, executables, project] in
                    try Self.spawn(arguments, orchestrator: orchestrator, executables: executables, project: project)
                }
            case "agent_wait":
                return try await wait(arguments)
            case "agent_list":
                let limit = arguments["limit"]?.intValue ?? Self.defaultListLimit
                let runs = orchestrator.recent(limit: limit)
                return runs.isEmpty ? "No agents have been spawned." : runs.map(AgentReport.headline).joined(separator: "\n")
            case "agent_cancel":
                let id = try Self.string("id", in: arguments)
                return try await Self.offThePool { [orchestrator] in
                    try orchestrator.cancel(id)
                    return AgentReport.headline(try orchestrator.status(id))
                }
            case "agent_merge":
                // A merge writes the checkout and may take a while: park it
                // off the cooperative pool, as the spawn that made the branch.
                let id = try Self.string("id", in: arguments)
                let discard = arguments["discard"]?.boolValue ?? false
                let pause = arguments["pause"]?.boolValue ?? false
                guard !(discard && pause) else {
                    throw ToolError("pause and discard exclude each other: pause keeps the branch, discard drops it")
                }
                return try await Self.offThePool { [self] in
                    try merge(id: id, discard: discard, pause: pause)
                }
            case "agent_redo":
                return try await Self.offThePool { [self] in try redo(arguments) }
            case "agent_rate":
                return try rate(arguments)
            case "agent_scores":
                let kind = try Self.kind(in: arguments)
                let runs = orchestrator.recent(limit: Self.scoredRuns)
                // The listing takes seconds per CLI; it is cached, and it is
                // dropped from the text when it cannot be had.
                return try await Self.offThePool { [executables] in
                    let offers = ModelCatalog.offers(ModelCatalog.cachedListing(executables))
                    return Scoreboard.summary(
                        Scoreboard.scores(runs, kind: kind), kind: kind, offers: offers, history: runs
                    )
                }
            case "agent_models":
                return try await Self.offThePool { [executables] in
                    ModelCatalog.summary(ModelCatalog.listing(executables))
                }
            default:
                throw ToolError("unknown tool: \(tool)")
            }
        } catch let error as OrchestratorError {
            throw ToolError(error.description)
        }
    }

    private static func spawn(
        _ arguments: JSONValue,
        orchestrator: Orchestrator,
        executables: Executables,
        project: String?
    ) throws -> String {
        let accessName = arguments["access"]?.stringValue ?? WorkerAccess.read.rawValue
        guard let access = WorkerAccess(rawValue: accessName) else {
            throw ToolError("access must be read or edit, not '\(accessName)'")
        }
        let kind = try kind(in: arguments)
        let commands = try commands(in: arguments)
        let prompt = try string("prompt", in: arguments)
        let difficulty = try difficulty(in: arguments) ?? Difficulty.estimate(prompt: prompt, kind: kind, access: access)

        // Named by the orchestrator: run as asked. Otherwise Vitra picks.
        var picked: WorkerPicker.Choice?
        let cli: WorkerCLI
        let model: String
        let effort: String?
        if let named = try namedWorker(in: arguments) {
            (cli, model, effort) = named
        } else {
            let offers = ModelCatalog.offers(ModelCatalog.cachedListing(executables))
            guard let choice = WorkerPicker.pick(
                kind: kind ?? .other,
                access: access,
                needsCommands: !commands.isEmpty,
                history: orchestrator.recent(limit: Self.historyLimit),
                offers: offers,
                installed: Set(executables.paths.keys),
                difficulty: difficulty
            ) else {
                throw ToolError(
                    "no installed worker can take this piece\(commands.isEmpty ? "" : " with commands"): "
                        + "name one with cli, model and effort (agent_models lists them)"
                )
            }
            picked = choice
            cli = choice.offer.cli
            model = choice.offer.model
            effort = choice.offer.effort
        }

        let spec = WorkerSpec(
            cli: cli,
            model: model,
            prompt: prompt,
            directory: try string("directory", in: arguments),
            access: access,
            label: arguments["label"]?.stringValue,
            kind: kind,
            effort: effort,
            project: project,
            commands: commands,
            // Nil is the default, which is on: only an explicit false turns
            // the gate off, and an explicit true is kept as it was asked.
            audit: arguments["audit"]?.boolValue,
            minutes: try minutes(in: arguments),
            difficulty: difficulty
        )
        // A worker Vitra picked may be failed over to another if its provider
        // is out; one the maestro named is only reported.
        let id = try orchestrator.spawn(spec, link: Orchestrator.SpawnLink(picked: picked != nil))
        let why = picked.map { "picked \(spec.worker): \($0.reason). " } ?? ""
        return "Started agent \(id): \(spec.worker), \(access.rawValue) access, in \(spec.directory). \(why)Call agent_wait with this id for its result."
    }

    /// The worker the arguments name, or nil when they leave all of cli, model
    /// and effort out and Vitra is to pick.
    private static func namedWorker(in arguments: JSONValue) throws -> (WorkerCLI, String, String?)? {
        guard arguments["cli"]?.stringValue != nil else {
            guard arguments["model"]?.stringValue == nil, arguments["effort"]?.stringValue == nil else {
                throw ToolError("model and effort go with a cli: name the worker with all three, or leave all three out and Vitra picks")
            }
            return nil
        }
        let cliName = try string("cli", in: arguments)
        guard let cli = WorkerCLI(rawValue: cliName) else {
            let names = WorkerCLI.allCases.map(\.rawValue)
            let known = names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
            throw ToolError("cli must be \(known), not '\(cliName)'")
        }
        return (cli, try string("model", in: arguments), arguments["effort"]?.stringValue)
    }

    /// The difficulty named in the arguments, or nil when none was.
    private static func difficulty(in arguments: JSONValue) throws -> Difficulty? {
        guard let name = arguments["difficulty"]?.stringValue else { return nil }
        guard let difficulty = Difficulty(rawValue: name) else {
            throw ToolError("difficulty must be easy, normal or hard, not '\(name)'")
        }
        return difficulty
    }

    private func rate(_ arguments: JSONValue) throws -> String {
        let id = try Self.string("id", in: arguments)
        // A whole number only: 4.5 silently recorded as 4 would be a rating
        // the orchestrator did not give.
        guard case let .number(value)? = arguments["score"], value == value.rounded(), Rating.scores.contains(Int(value)) else {
            throw ToolError("score must be a whole number from 1 to 5")
        }
        try orchestrator.rate(id, score: Int(value), note: arguments["note"]?.stringValue)
        let run = try orchestrator.status(id)
        return "Rated agent \(id) \(Int(value))/5: \(run.spec.worker)."
    }

    /// Puts a finished editing run's branch on the branch checked out in its
    /// repository, then takes its worktree and branch away; or, with
    /// `discard`, takes them away without merging.
    ///
    /// A checkout already in the middle of a merge is refused outright, and
    /// only a failed merge this call started is ever aborted. The worktree is
    /// removed with `--force`, so unless the work is being discarded, a failed
    /// commit or any edit still uncommitted there stops the merge rather than
    /// being deleted with the tree.
    ///
    /// It blocks for as long as git takes, so its caller runs it off the
    /// cooperative pool. Reading git sets GIT_OPTIONAL_LOCKS=0 (see
    /// `Git.run`), so a status here cannot take the index lock out from under
    /// the user's own git.
    private func merge(id: String, discard: Bool, pause: Bool = false) throws -> String {
        let run = try orchestrator.status(id)
        guard run.state != .running else {
            throw ToolError("agent \(id) is still running: wait for it to finish before merging")
        }
        guard let repository = run.repository, let branch = run.branch else {
            throw ToolError("agent \(id) has no branch to merge: it did not edit a git repository")
        }
        // A delivery and its redos share one branch, and one worktree: they
        // are merged, paused or dropped together, once.
        let members = branchMembers(of: run)
        if let closed = members.lazy.compactMap({ closure(of: $0.id) }).first {
            return "agent \(id): branch \(branch) was already \(closed); nothing to do."
        }
        if let busy = members.first(where: { $0.state == .running }) {
            throw ToolError("agent \(busy.id) is still running on \(branch): wait for it to finish before merging")
        }
        // An auditor past its deadline is cancelled by this read, which can
        // take seconds: do it before the lock, not under it.
        for member in members { if let audit = auditID(member.id) { _ = try? orchestrator.status(audit) } }

        // Everything from here to the end is one critical section per
        // repository: the checks and the merge are not atomic, and another
        // helper's `git merge --abort` could abort this one's merge. What
        // waits for the lock is never a worker, only another merge or an
        // auditor being started.
        do {
            return try RepositoryLock.withLock(repository, timeout: lockTimeout) {
                try mergeLocked(run, members: members, repository: repository, branch: branch, discard: discard, pause: pause)
            }
        } catch let error as RepositoryLockError {
            throw ToolError(error.description)
        }
    }

    /// Every run on `run`'s branch, itself included, newest first: the
    /// delivery, the redos that went on in its branch, and what redid those.
    private func branchMembers(of run: Run) -> [Run] {
        guard let branch = run.branch, let repository = run.repository else { return [run] }
        let others = orchestrator.recent(limit: Self.historyLimit)
            .filter { $0.id != run.id && $0.branch == branch && $0.repository == repository }
        return ([run] + others).sorted { $0.started > $1.started }
    }

    /// The member whose worktree is still on disk, if any.
    private func liveMember(_ members: [Run]) -> Run? {
        members.first { $0.worktree.map { FileManager.default.fileExists(atPath: $0) } == true }
    }

    /// What became of the branch, when a merge or a discard settled it:
    /// "merged through agent x".
    private func closure(of id: String) -> String? {
        guard let directory = orchestrator.directory(of: id) else { return nil }
        return Self.claimText(directory.appendingPathComponent("closed"))
    }

    /// Writes down on every run of the branch how it ended, so a second
    /// agent_merge of any of them says so instead of failing on a branch that
    /// is gone.
    private func markClosed(_ members: [Run], _ text: String) {
        for member in members {
            guard let directory = orchestrator.directory(of: member.id) else { continue }
            try? Data(text.utf8).write(to: directory.appendingPathComponent("closed"), options: .atomic)
        }
    }

    /// The part of `merge` that holds the repository's lock.
    private func mergeLocked(
        _ run: Run, members: [Run], repository: String, branch: String, discard: Bool, pause: Bool
    ) throws -> String {
        let id = run.id
        // The auditor is reading this worktree; taking it away now would pull
        // the files out from under it.
        for member in members {
            if let refusal = auditRefusal(member.id) { throw ToolError(refusal) }
        }
        // The worktree that is still there, if the work was not paused.
        let live = liveMember(members)
        let worktree = live?.worktree

        // A merge somebody else started is theirs to finish or abort: taking
        // it over would bury their resolution, and aborting it would throw it
        // away. Nothing here touches a checkout that is mid-merge, not even a
        // discard.
        guard !Self.isMerging(repository) else {
            throw ToolError(
                "the checkout at \(repository) is already in the middle of a merge: "
                    + "finish or abort it, then call agent_merge for \(id) again"
            )
        }

        if pause {
            return try pauseLocked(run, members: members, live: live, repository: repository, branch: branch)
        }

        if !discard {
            // The worktree is removed with --force below, so anything still
            // uncommitted there would be deleted with it. A failed commit is
            // exactly that case, and a status catches edits made after one.
            // (A paused delivery has no worktree: its branch is all of it.)
            if let live, let worktree {
                if let failure = live.commitError {
                    let reason = failure.isEmpty ? "git gave no reason" : failure
                    throw ToolError(
                        "agent \(live.id)'s commit failed (\(reason)): the edits are still uncommitted in \(worktree) — "
                            + "commit them there, or pass discard true to drop them"
                    )
                }
                let tree = Git.run(["status", "--porcelain"], in: worktree)
                guard tree.succeeded else {
                    throw ToolError("could not read the worktree at \(worktree): " + Self.reason(tree))
                }
                guard tree.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ToolError(
                        "agent \(live.id) has edits still uncommitted in \(worktree): "
                            + "commit them there before merging, or pass discard true to drop them"
                    )
                }
            }

            // A checkout with uncommitted work would make the merge refuse
            // halfway, or bury the user's changes in it: say so and stop,
            // never stashing what is not ours.
            let status = Git.run(["status", "--porcelain", "--untracked-files=no"], in: repository)
            guard status.succeeded else {
                throw ToolError("could not read the checkout at \(repository): " + Self.reason(status))
            }
            guard status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError(
                    "the checkout at \(repository) has uncommitted changes to tracked files: "
                        + "commit them, then call agent_merge for \(id) again"
                )
            }

            let merged = Git.run(["merge", "--no-edit", branch], in: repository)
            guard merged.succeeded else {
                // The conflicts are read before the abort clears them from the
                // index. The worktree and branch stay, so the work can go back
                // to the worker that made it.
                let conflicts = (Git.output(["diff", "--name-only", "--diff-filter=U"], in: repository) ?? "")
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                // Only the merge this call just started may be aborted: a
                // merge that was already in progress was refused above.
                let aborted = Self.abortMerge(repository)
                let files = conflicts.isEmpty
                    ? " — git said: " + Self.reason(merged)
                    : ": " + conflicts.joined(separator: ", ")
                throw ToolError(
                    "merge of \(branch) conflicts\(files) — "
                        + (aborted ? "the merge was aborted and " : "nothing was merged and ")
                        + "\(worktree.map { $0 + " and " } ?? "")\(branch) are still there; send the work back to agent \(id) to resolve"
                )
            }
        }

        let removed = worktree.map { Git.run(["worktree", "remove", "--force", $0], in: repository) }
        let deleted = Git.run(["branch", "-D", branch], in: repository)
        markClosed(members, "\(discard ? "discarded" : "merged") through agent \(id)")

        var lines: [String]
        if discard {
            lines = ["Discarded agent \(id): \(branch) was not merged."]
        } else {
            var result = "Merged \(branch) into the checkout at \(repository)"
            let log = Self.trimmed(Git.output(["log", "-1", "--oneline"], in: repository))
            if !log.isEmpty { result += ": " + log }
            if let base = run.baseCommit {
                let stat = Self.trimmed(Git.output(["diff", "--shortstat", "\(base)..HEAD"], in: repository))
                if !stat.isEmpty { result += " — " + stat }
            }
            lines = [result]
        }
        if let removed, let worktree {
            if removed.succeeded {
                lines.append("Removed worktree \(worktree).")
            } else {
                lines.append("Could not remove worktree \(worktree): " + Self.reason(removed))
            }
        }
        if deleted.succeeded {
            lines.append("Deleted branch \(branch).")
        } else {
            lines.append("Could not delete branch \(branch): " + Self.reason(deleted))
        }
        let others = members.filter { $0.id != id }.map(\.id)
        if !others.isEmpty {
            lines.append("Also closed, on the same branch: " + others.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// Sets a finished delivery aside: what is uncommitted in its worktree is
    /// committed as `wip: paused`, the worktree is removed and the branch is
    /// kept. Under the repository's lock, like a merge, which could otherwise
    /// remove the tree from under it.
    private func pauseLocked(
        _ run: Run, members: [Run], live: Run?, repository: String, branch: String
    ) throws -> String {
        let id = run.id
        guard case .finished = run.state else {
            throw ToolError("agent \(id) did not finish: only a finished delivery can be paused")
        }
        guard let live, let worktree = live.worktree else {
            return "Agent \(id) is already paused: branch \(branch) is kept and there is no worktree. "
                + "Continue it with agent_redo, or merge it with agent_merge."
        }

        var lines: [String] = []
        let committed = try commitPausedWork(in: worktree, run: live)
        if committed { lines.append("Committed what was uncommitted as \"wip: paused\".") }

        let removed = Git.run(["worktree", "remove", "--force", worktree], in: repository)
        guard removed.succeeded else {
            throw ToolError("could not remove the worktree at \(worktree): " + Self.reason(removed))
        }
        for member in members {
            guard let directory = orchestrator.directory(of: member.id) else { continue }
            FileManager.default.createFile(atPath: directory.appendingPathComponent("paused").path, contents: nil)
        }
        lines.insert("Paused agent \(id): branch \(branch) is kept and worktree \(worktree) is removed.", at: 0)
        lines.append("Continue it with agent_redo (the worktree is recreated from the branch), or merge it later with agent_merge.")
        return lines.joined(separator: "\n")
    }

    /// Commits whatever the worktree holds uncommitted, as the shell around a
    /// worker does — without what the project's setup linked or copied in —
    /// and answers whether there was anything to commit.
    private func commitPausedWork(in worktree: String, run: Run) throws -> Bool {
        let added = Git.run(["add", "-A"], in: worktree)
        guard added.succeeded else { throw ToolError("could not stage the work in \(worktree): " + Self.reason(added)) }
        let excludes = orchestrator.directory(of: run.id)
            .flatMap { Self.claimText($0.appendingPathComponent("worktree-excludes")) }?
            .split(whereSeparator: \.isNewline).map { ":(literal)\($0)" } ?? []
        if !excludes.isEmpty {
            let reset = Git.run(["reset", "-q", "--"] + excludes, in: worktree)
            guard reset.succeeded else { throw ToolError("could not stage the work in \(worktree): " + Self.reason(reset)) }
        }
        guard !Git.run(["diff", "--cached", "--quiet"], in: worktree).succeeded else { return false }
        let commit = Git.run([
            "-c", "user.name=Vitra worker", "-c", "user.email=worker@vitra.local",
            "commit", "-q", "-m", "wip: paused",
        ], in: worktree)
        guard commit.succeeded else {
            throw ToolError(
                "could not commit the work in \(worktree), so nothing was paused: " + Self.reason(commit)
            )
        }
        // The failed commit this replaces is no longer a failure.
        if let directory = orchestrator.directory(of: run.id) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("commit-error"))
        }
        return true
    }

    /// The refusal for a run an audit is still reading, if one is.
    ///
    /// `pending` is a claim another wait has taken and is spawning behind, so
    /// there is no auditor id to name yet.
    ///
    /// An audit that stopped, however it ended — failed, cancelled, timed out —
    /// refuses nothing, and neither does a claim abandoned before its auditor
    /// was recorded.
    private func auditRefusal(_ id: String) -> String? {
        guard let directory = orchestrator.directory(of: id) else { return nil }
        let record = directory.appendingPathComponent("audit")
        guard let audit = Self.claimText(record) else { return nil }
        if audit.isEmpty || audit == "pending" {
            return Self.isAbandoned(record) ? nil : "an audit is still reading this worktree; agent_wait on it first"
        }
        guard let reading = try? orchestrator.status(audit), reading.state == .running else { return nil }
        return "the audit \(audit) is still reading this worktree; agent_wait on it first"
    }

    /// The id of the audit recorded for run `id`, when there is one.
    private func auditID(_ id: String) -> String? {
        guard let directory = orchestrator.directory(of: id),
              let text = Self.claimText(directory.appendingPathComponent("audit")),
              !text.isEmpty, text != "pending"
        else { return nil }
        return text
    }

    /// What the claim file says, trimmed, or nil when there is no claim.
    private static func claimText(_ record: URL) -> String? {
        (try? String(contentsOf: record, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the claim is a `pending` one nobody finished: older than
    /// `staleClaimAge` by its modification date, with no auditor id in it.
    private static func isAbandoned(_ record: URL) -> Bool {
        guard let text = claimText(record), text.isEmpty || text == "pending",
              let modified = (try? FileManager.default.attributesOfItem(atPath: record.path))?[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(modified) > staleClaimAge
    }

    /// What git printed, trimmed, or nil when it printed nothing.
    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `repository` has a merge in progress.
    private static func isMerging(_ repository: String) -> Bool {
        Git.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repository).succeeded
    }

    /// Aborts the merge this call started, if its conflict left one on, and
    /// says whether it did. A checkout that was already merging was refused
    /// before the merge, so a merge still in progress here is this call's.
    private static func abortMerge(_ repository: String) -> Bool {
        guard isMerging(repository) else { return false }
        return Git.run(["merge", "--abort"], in: repository).succeeded
    }

    /// What git said, in one line, for a failure that has no better words.
    private static func reason(_ result: (succeeded: Bool, output: String)) -> String {
        let text = trimmed(result.output)
        return text.isEmpty ? "git gave no reason" : text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// The time limit named in the arguments, when one was: a whole number,
    /// not 4.5 silently kept as 4. The range is the spec's to check.
    private static func minutes(in arguments: JSONValue) throws -> Int? {
        guard let value = arguments["minutes"], value != .null else { return nil }
        guard case let .number(number) = value, number == number.rounded(), abs(number) < 1e6 else {
            throw ToolError("minutes must be a whole number from 1 to 180")
        }
        return Int(number)
    }

    /// The commands the worker may run, when any were named.
    private static func commands(in arguments: JSONValue) throws -> [String] {
        guard let value = arguments["commands"], value != .null else { return [] }
        let strings = value.arrayValue?.compactMap(\.stringValue)
        guard let strings, strings.count == value.arrayValue?.count else {
            throw ToolError("commands must be an array of command strings")
        }
        return strings
    }

    /// The kind of task named in the arguments, or nil when none was.
    private static func kind(in arguments: JSONValue) throws -> TaskKind? {
        guard let name = arguments["kind"]?.stringValue else { return nil }
        guard let kind = TaskKind(rawValue: name) else {
            let names = TaskKind.allCases.map(\.rawValue)
            let known = names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
            throw ToolError("kind must be \(known), not '\(name)'")
        }
        return kind
    }

    private func wait(_ arguments: JSONValue) async throws -> String {
        let values = arguments["ids"]?.arrayValue ?? []
        let ids = values.compactMap(\.stringValue)
        // Every id or none: an id dropped for not being a string would come
        // back as an agent silently missing from the answer.
        guard !ids.isEmpty, ids.count == values.count else {
            throw ToolError("ids must be a non-empty array of agent ids")
        }
        let requested = arguments["timeout_seconds"]?.intValue ?? Self.defaultTimeout
        let timeout = min(max(requested, 0), Self.longestTimeout)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))

        // A run whose provider was out is taken over by another worker, and
        // the wait goes on with that one, in the time that is left.
        var current = ids
        var failovers: [Int: String] = [:]
        var runs: [Run]
        while true {
            runs = try await orchestrator.wait(ids: current, timeout: max(deadline.timeIntervalSinceNow, 0))
            var moved = false
            for (index, run) in runs.enumerated() where run.providerFailure != nil {
                guard let outcome = try await Self.offThePool({ [self] in self.failover(run) }) else { continue }
                failovers[index] = outcome.line
                if let successor = outcome.id, successor != current[index] {
                    current[index] = successor
                    moved = true
                }
            }
            if !moved { break }
        }
        var gates: [String: Gate] = [:]
        for run in runs {
            // Reading the history and starting an auditor both touch the disk
            // and one of them starts a process: keep them off the pool, as
            // agent_spawn does.
            if let gate = try? await Self.offThePool({ [self] in self.gate(for: run) }) {
                gates[run.id] = gate
            }
        }
        return runs.enumerated().map { index, run in
            let gate = gates[run.id]
            var report = AgentReport.full(run, audit: gate?.reading)
            if let line = failovers[index] { report = line + "\n" + report }
            guard let line = gate?.line else { return report }
            return report + "\n" + line
        }.joined(separator: "\n\n")
    }

    // MARK: Failover

    /// What became of a run whose provider was out: the run that took over,
    /// when one did, and the line that says so.
    private struct Failover {
        let id: String?
        let line: String
    }

    /// Hands a run Vitra picked, and whose provider did not let it run, to the
    /// next pick from another CLI: the same prompt, kind, access, commands,
    /// label and directory, in a worktree of its own when it edits. Once per
    /// original run, whoever asks: the successor is written beside the run,
    /// and later calls report it. A worker the maestro named, and a run that
    /// is itself a retry, are only reported.
    private func failover(_ run: Run) -> Failover? {
        guard let failure = run.providerFailure, run.wasPicked, run.retryOf == nil,
              let directory = orchestrator.directory(of: run.id)
        else { return nil }
        let record = directory.appendingPathComponent("retry")
        let cause = "[\(run.id)] did not run (\(failure.name))"

        // The claim is taken before the spawn, as for an audit: two waits on
        // the same run must not start two retries.
        if Self.isAbandoned(record) { try? FileManager.default.removeItem(at: record) }
        switch Self.claim(record) {
        case .exists:
            let text = Self.claimText(record) ?? ""
            guard !text.isEmpty, text != "pending", let successor = try? orchestrator.status(text) else {
                return Failover(id: nil, line: cause + " — being retried on another worker")
            }
            return Failover(id: text, line: cause + " — retried as [\(text)] on \(successor.spec.worker)")
        case .failed:
            return nil
        case .created:
            break
        }

        let offers = ModelCatalog.offers(ModelCatalog.cachedListing(executables))
        guard let choice = WorkerPicker.pick(
            kind: run.spec.kind ?? .other,
            access: run.spec.access,
            needsCommands: !run.spec.commands.isEmpty,
            history: orchestrator.recent(limit: Self.historyLimit),
            offers: offers,
            installed: Set(executables.paths.keys),
            excluded: [run.spec.cli],
            difficulty: run.spec.difficulty ?? .normal
        ) else {
            try? FileManager.default.removeItem(at: record)
            return Failover(id: nil, line: cause + " — no worker from another provider can take it; spawn it again when one is free")
        }
        let spec = WorkerSpec(
            cli: choice.offer.cli, model: choice.offer.model, prompt: run.spec.prompt, directory: run.spec.directory,
            access: run.spec.access, label: run.spec.label, kind: run.spec.kind, effort: choice.offer.effort,
            project: run.spec.project, commands: run.spec.commands, audit: run.spec.audit,
            minutes: run.spec.minutes, difficulty: run.spec.difficulty
        )
        do {
            let successor = try orchestrator.spawn(spec, link: Orchestrator.SpawnLink(picked: true, retryOf: run.id))
            try? Data(successor.utf8).write(to: record, options: .atomic)
            discardEmptyWorktree(of: run)
            return Failover(id: successor, line: cause + " — retried as [\(successor)] on \(spec.worker)")
        } catch {
            try? FileManager.default.removeItem(at: record)
            return Failover(id: nil, line: cause + " — could not retry it on \(spec.worker): \(error)")
        }
    }

    /// Takes away the worktree and branch of a run that never ran, once its
    /// successor has a tree of its own. Left alone when it holds anything.
    private func discardEmptyWorktree(of run: Run) {
        guard let repository = run.repository, let tree = run.worktree, let branch = run.branch,
              let base = run.baseCommit
        else { return }
        try? RepositoryLock.withLock(repository, timeout: lockTimeout) {
            let commits = Git.output(["rev-list", "--count", "\(base)..\(branch)"], in: repository)
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let edits = Git.output(["status", "--porcelain", "--untracked-files=no"], in: tree)
            guard commits == 0, let edits, Self.trimmed(edits).isEmpty else { return }
            _ = Git.run(["worktree", "remove", "--force", tree], in: repository)
            _ = Git.run(["branch", "-D", branch], in: repository)
        }
    }

    // MARK: Redo

    /// Spawns a new worker on the same piece with what the last attempt got
    /// wrong, in the delivery's own worktree and branch when it can build on
    /// them, so it goes on from what was delivered instead of starting over.
    private func redo(_ arguments: JSONValue) throws -> String {
        let id = try Self.string("id", in: arguments)
        let notes = try Self.string("notes", in: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { throw ToolError("notes are empty: say what the previous attempt got wrong") }
        let original = try orchestrator.status(id)
        guard original.state != .running else {
            throw ToolError("agent \(id) is still running: wait for it to finish before redoing it")
        }
        let members = branchMembers(of: original)
        if let busy = members.first(where: { $0.state == .running }) {
            throw ToolError("agent \(busy.id) is still running on the same branch: wait for it to finish before redoing")
        }
        for member in members {
            if let audit = auditID(member.id) { _ = try? orchestrator.status(audit) }
            if let refusal = auditRefusal(member.id) { throw ToolError(refusal) }
        }

        let (cli, model, effort, why) = try redoWorker(for: original, arguments)
        let spec = original.spec
        let continuing = original.spec.access == .edit ? continuation(of: original, members: members) : nil
        let redone = WorkerSpec(
            cli: cli, model: model,
            prompt: Self.redoPrompt(spec.prompt, notes: notes, branch: continuing?.branch),
            directory: spec.directory, access: spec.access,
            label: ((spec.label ?? "").isEmpty ? spec.worker : spec.label ?? "") + " (redo)",
            kind: spec.kind, effort: effort, project: spec.project, commands: spec.commands,
            audit: spec.audit, minutes: spec.minutes, difficulty: spec.difficulty
        )
        let link = Orchestrator.SpawnLink(redoOf: id, continuing: continuing)

        // Going on in a tree that a merge could remove is held under the lock.
        let started: String
        do {
            started = try continuing.map { continuing in
                try RepositoryLock.withLock(continuing.repository, timeout: lockTimeout) {
                    // The tree was looked for before the lock; a merge may have taken it since.
                    guard liveMember(branchMembers(of: original)) != nil || continuing.tree == nil else {
                        throw ToolError("agent \(id)'s worktree was removed while redoing it: ask again")
                    }
                    return try orchestrator.spawn(redone, link: link)
                }
            } ?? orchestrator.spawn(redone, link: link)
        } catch let error as RepositoryLockError {
            throw ToolError(error.description)
        }

        // The redo is the delivery to audit now: the old audit does not stand
        // for it, and the old run must not start another of its own.
        for member in members {
            guard let directory = orchestrator.directory(of: member.id) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("audit"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("paused"))
        }
        if let directory = orchestrator.directory(of: id) {
            try? Data(started.utf8).write(to: directory.appendingPathComponent("redo"), options: .atomic)
        }

        let place: String
        switch continuing {
        case nil: place = spec.access == .edit ? "in a fresh worktree" : "as a new read-only run"
        case let continuing? where continuing.tree != nil: place = "in the same worktree and branch (\(continuing.branch))"
        case let continuing?: place = "in a worktree recreated from branch \(continuing.branch)"
        }
        return "Started agent \(started): \(redone.worker), \(spec.access.rawValue) access, redo of \(id), \(place). "
            + "\(why). Call agent_wait with this id for its result."
    }

    /// The worker for a redo: the one named; else the same worker, unless its
    /// delivery was rated below 3, when the next pick that is not it.
    private func redoWorker(
        for original: Run, _ arguments: JSONValue
    ) throws -> (cli: WorkerCLI, model: String, effort: String?, why: String) {
        if let (cli, model, effort) = try Self.namedWorker(in: arguments) { return (cli, model, effort, "as named") }
        let spec = original.spec
        let rating = original.rating?.score
        if rating.map({ $0 >= Self.redoWithSameWorker }) ?? true {
            return (spec.cli, spec.model, spec.effort, "the same worker goes again\(rating.map { ", rated \($0)/5" } ?? "")")
        }
        let offers = ModelCatalog.offers(ModelCatalog.cachedListing(executables))
        guard let choice = WorkerPicker.pick(
            kind: spec.kind ?? .other,
            access: spec.access,
            needsCommands: !spec.commands.isEmpty,
            history: orchestrator.recent(limit: Self.historyLimit),
            offers: offers,
            installed: Set(executables.paths.keys),
            excludedWorkers: [ModelCatalog.Offer(cli: spec.cli, model: spec.model, effort: spec.effort)],
            difficulty: spec.difficulty ?? .normal
        ) else {
            throw ToolError(
                "its delivery was rated \(rating ?? 0)/5 and no other installed worker can take the piece: "
                    + "name one with cli, model and effort (agent_models lists them)"
            )
        }
        return (choice.offer.cli, choice.offer.model, choice.offer.effort,
                "picked: \(choice.reason); \(spec.worker) delivered a \(rating ?? 0)/5")
    }

    /// The lowest rating of its delivery with which the same worker is trusted
    /// with the redo.
    static let redoWithSameWorker = 3

    /// The branch a redo goes on from, when there is one: the delivery edited
    /// a repository and its branch still exists, with its worktree or without.
    private func continuation(of run: Run, members: [Run]) -> Orchestrator.Continuation? {
        guard let repository = run.repository, let branch = run.branch, let base = run.baseCommit,
              Git.run(["rev-parse", "--verify", "-q", "refs/heads/\(branch)"], in: repository).succeeded
        else { return nil }
        let live = liveMember(members)
        return Orchestrator.Continuation(
            repository: repository, branch: branch, base: base, tree: live?.worktree, owner: (live ?? run).id
        )
    }

    /// The original prompt with what the last attempt got wrong.
    static func redoPrompt(_ prompt: String, notes: String, branch: String?) -> String {
        let site = branch.map { "\n\nThe previous attempt's changes are already in this directory, on branch \($0): build on them." } ?? ""
        return prompt + "\n\nWhat the previous attempt got wrong, fix exactly this:\n" + notes + site
    }

    /// The quality gate on a finished editing delivery: starts a cheap
    /// read-only auditor from another provider once, and reports the audit
    /// that already exists on every later wait.
    ///
    /// An empty gate means there is nothing to gate: the run did not finish
    /// cleanly, did not edit, has no branch or no commit on it, or its spawn
    /// said `audit: false`. A gate that cannot be started is said in the
    /// report rather than failing the wait: the delivery is still the
    /// orchestrator's to review.
    private func gate(for run: Run) -> Gate {
        guard case .finished(exitCode: 0) = run.state,
              run.output?.isError != true,
              run.spec.access == .edit,
              let branch = run.branch,
              let base = run.baseCommit,
              let repository = run.repository,
              let worktree = run.worktree,
              let directory = orchestrator.directory(of: run.id)
        else { return Gate() }

        // A delivery that was redone is audited in its redo, not again here.
        if let redone = Self.claimText(directory.appendingPathComponent("redo")), !redone.isEmpty {
            return Gate(line: "gate: agent \(redone) redid this delivery — audit and merge that one.")
        }
        let record = directory.appendingPathComponent("audit")
        // A claim abandoned half-way is not an audit: it is taken over below.
        if FileManager.default.fileExists(atPath: record.path), !Self.isAbandoned(record) {
            return Self.existingGate(record, orchestrator: orchestrator)
        }
        guard run.spec.audit != false else { return Gate() }

        // No commit means no diff to audit; the report already says the edits
        // are still uncommitted in the worktree.
        let counted = Git.output(["rev-list", "--count", "\(base)..\(branch)"], in: repository)
        guard let commits = counted.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
              commits > 0
        else { return Gate() }

        // A small change is quicker for the orchestrator to read than for an
        // auditor to start on: the gate is for changes big enough to hide
        // something, unless the spawn asked for it by name.
        if run.spec.audit != true,
           let lines = Self.changedLines(from: base, to: branch, in: repository),
           lines < Self.auditFromLines {
            return Gate(line: "gate: no audit — a small change (\(lines) \(lines == 1 ? "line" : "lines")); review it yourself.")
        }

        let history = orchestrator.recent(limit: Self.scoredRuns)
        guard let choice = Audit.chooseAuditor(
            implementer: run.spec,
            history: history,
            installed: Set(executables.paths.keys),
            offers: ModelCatalog.offers(ModelCatalog.cachedListing(executables))
        ) else {
            return Gate(line: "gate: no auditor from another provider is available — review this delivery yourself.")
        }

        // A diff that cannot be read is not an empty diff: an auditor started
        // on it would judge nothing, and say `ship` about nothing.
        let read = Git.run(["diff", "\(base)..\(branch)"], in: repository)
        guard read.succeeded else {
            let reason = read.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return Gate(line: "gate: no audit — could not read the diff: "
                + (reason.isEmpty ? "git gave no reason" : reason))
        }

        let label = run.spec.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let spec = WorkerSpec(
            cli: choice.cli,
            model: choice.model,
            prompt: Audit.prompt(task: run.spec.prompt, diff: read.output, label: run.spec.label),
            directory: worktree,
            access: .read,
            label: "auditoria: " + (label.isEmpty ? run.id : label),
            kind: .review,
            effort: choice.effort,
            project: run.spec.project,
            minutes: Self.auditMinutes
        )

        // Claim and spawn hold the repository's lock, the same one a merge
        // holds while it removes the worktree: a merge cannot delete the tree
        // an auditor is being started in, and an auditor cannot be started in
        // a tree already deleted. The diff and the choice above were made
        // outside it, so the lock is held for the spawn only.
        do {
            return try RepositoryLock.withLock(repository, timeout: lockTimeout) {
                claimAndSpawn(spec, run: run, worktree: worktree, record: record)
            }
        } catch let error as RepositoryLockError {
            if case .busy = error {
                return Gate(line: "gate: audit not started, the repository is busy — agent_wait again to start it.")
            }
            return Gate(line: "gate: could not start an auditor: \(error) — review this delivery yourself.")
        } catch {
            return Gate(line: "gate: could not start an auditor: \(error) — review this delivery yourself.")
        }
    }

    /// The claim and the auditor's spawn, under the repository's lock.
    private func claimAndSpawn(_ spec: WorkerSpec, run: Run, worktree: String, record: URL) -> Gate {
        // A merge that got the lock first has taken the worktree away.
        guard FileManager.default.fileExists(atPath: worktree) else { return Gate() }

        // A claim abandoned by a helper that died is not an audit; the lock
        // makes the removal safe, since nobody else is between claim and spawn.
        if Self.isAbandoned(record) { try? FileManager.default.removeItem(at: record) }

        // The claim is taken before the spawn, not after: two waits finishing
        // the same delivery at once would otherwise both read no record, both
        // spawn an auditor, and both pay for it.
        switch Self.claim(record) {
        case .exists:
            return Self.existingGate(record, orchestrator: orchestrator)
        case let .failed(reason):
            return Gate(line: "gate: could not start an auditor: \(reason) — review this delivery yourself.")
        case .created:
            break
        }

        do {
            let id = try orchestrator.spawn(spec)
            do {
                // Atomic replace of the claim: a reader sees `pending` or the
                // id, never half of either.
                try Data(id.utf8).write(to: record, options: .atomic)
            } catch {
                // An audit nobody can find again would be started twice and
                // paid for twice: stop it rather than leave it unrecorded.
                try? orchestrator.cancel(id)
                try? FileManager.default.removeItem(at: record)
                return Gate(line: "gate: could not record the audit — review this delivery yourself.")
            }
            return Gate(
                line: "gate: audit \(id) by \(spec.worker) started — agent_wait on it and read its verdict before reviewing yourself.",
                reading: id
            )
        } catch {
            // The claim is the retry token: with no auditor behind it, a
            // later wait has to be able to take it.
            try? FileManager.default.removeItem(at: record)
            return Gate(line: "gate: could not start an auditor: \(error) — review this delivery yourself.")
        }
    }

    /// What an existing `audit` file says.
    ///
    /// `pending` is a claim another wait has taken and is spawning behind:
    /// report the audit as starting rather than start a second one. An id is
    /// looked up so a running audit is known to be reading the worktree.
    private static func existingGate(_ record: URL, orchestrator: Orchestrator) -> Gate {
        let existing = ((try? String(contentsOf: record, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty || existing == "pending" {
            return Gate(line: "gate: audit starting", reading: "an auditor")
        }
        guard let audit = try? orchestrator.status(existing) else {
            return Gate(line: "gate: audit \(existing) — its record is gone; review this delivery yourself.")
        }
        return Gate(line: AgentReport.gate(audit), reading: audit.state == .running ? audit.id : nil)
    }

    /// Takes the audit slot for a run, creating the record only if nobody else
    /// has: the one caller that creates it is the only one that may spawn.
    private enum Claim {
        case created
        case exists
        case failed(String)
    }

    private static func claim(_ record: URL) -> Claim {
        let descriptor = open(record.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else {
            return errno == EEXIST ? .exists : .failed(String(cString: strerror(errno)))
        }
        let pending = Data("pending".utf8)
        let written = pending.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        let reason = String(cString: strerror(errno))
        close(descriptor)
        guard written == pending.count else {
            try? FileManager.default.removeItem(at: record)
            return .failed(reason)
        }
        return .created
    }

    /// Runs blocking work on a thread of its own.
    ///
    /// Cancelling waits for a process to die and listing models waits for a
    /// CLI to answer. The cooperative pool has one thread per core; parked on
    /// either, it would stop answering the client's pings.
    private static func offThePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static func string(_ name: String, in arguments: JSONValue) throws -> String {
        guard let value = arguments[name]?.stringValue else { throw ToolError("missing argument: \(name)") }
        return value
    }
}

/// A run, as text for the orchestrating model.
enum AgentReport {
    /// A worker can write a great deal; past this its answer is cut so one
    /// chatty worker cannot crowd the orchestrator's context.
    static let longestAnswer = 16000
    /// Seconds without a write to stdout or stderr before a running worker is
    /// reported as silent.
    static let silenceThreshold: TimeInterval = 120
    /// How many changed files the branch line lists before "and N more".
    static let mostFiles = 8

    /// One line: who, what state, how long, what it cost.
    static func headline(_ run: Run) -> String {
        let state: String
        switch run.state {
        case .running: state = "running"
        case .cancelled: state = "cancelled"
        case .lost: state = "LOST (the process is gone and left no result)"
        case let .finished(exitCode):
            if let failure = run.providerFailure {
                // Its provider did not let it run: not the worker's failure.
                state = "DID NOT RUN (\(failure.name)): \(failure.reason)"
            } else if run.timedOutAfter != nil {
                state = "FAILED (timed out)"
            } else if run.output?.isError == true {
                state = exitCode == 0 ? "FAILED" : "FAILED (exit \(exitCode))"
            } else {
                state = run.isPaused ? "paused" : "finished"
            }
        }

        var fields = [
            "[\(run.id)] \(state)",
            run.spec.worker,
            "\(Int(run.duration.rounded()))s",
        ]
        if let output = run.output {
            fields.append(String(format: "$%.4f", output.costUSD))
            fields.append("\(output.inputTokens) in / \(output.outputTokens) out")
        }
        // A worker that has written nothing for minutes may be hung. (claude's
        // json mode writes stdout only at the end, so there it is a hint, not proof.)
        if run.state == .running, let silent = run.silentFor, silent > silenceThreshold {
            fields.append("silent for \(Int(silent.rounded()))s")
        }
        if let rating = run.rating { fields.append("rated \(rating.score)/5") }
        if run.isPaused, state != "paused" { fields.append("paused") }
        if let redone = run.redoOf { fields.append("redo of \(redone)") }
        if let retried = run.retryOf { fields.append("retry of \(retried)") }
        // The label is free text from a model and the headline is one line: a
        // newline in it would let a label pass for the lines that follow.
        let label = (run.spec.label ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
        if !label.isEmpty { fields.append(label) }
        return fields.joined(separator: " · ")
    }

    /// The headline, then the worker's answer and anything it left on stderr.
    ///
    /// `audit` is the auditor reading the worktree, when one is: while it
    /// runs, the report must not tell the orchestrator to take that worktree
    /// away underneath it.
    static func full(_ run: Run, audit: String? = nil) -> String {
        var lines = [headline(run)]
        if let text = run.output?.text, !text.isEmpty {
            lines.append(text.count > longestAnswer
                ? text.prefix(longestAnswer) + "\n… (cut: \(text.count - longestAnswer) more characters)"
                : text)
        }
        // stderr is worth showing when something went wrong and it says
        // something the answer does not already.
        let wentWrong = run.output?.isError == true || run.state == .lost
        if wentWrong, let errorTail = run.errorTail, errorTail != run.output?.text {
            // (When stderr was all the worker said, it is already the answer above.)
            lines.append("stderr: " + errorTail)
        }
        lines.append(contentsOf: branchLines(run, audit: audit))
        if !run.worktreeSkipped.isEmpty {
            lines.append("worktree setup skipped: " + run.worktreeSkipped.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    /// The gate line for an audit that already exists: who is auditing and
    /// where it stands, so a second wait reports it instead of starting another.
    ///
    /// An audit that did not give a verdict — timed out, failed, cancelled,
    /// lost — blocks nothing: the line says to review the delivery oneself.
    static func gate(_ audit: Run) -> String {
        let who = "gate: audit \(audit.id) by \(audit.spec.worker)"
        let readIt = " — read its verdict before reviewing yourself."
        let noVerdict = " — review this delivery yourself."
        switch audit.state {
        case .running: return who + " running" + readIt
        case .cancelled: return who + " cancelled" + noVerdict
        case .lost: return who + " LOST" + noVerdict
        case let .finished(exitCode):
            if audit.timedOutAfter != nil { return "gate: audit \(audit.id) timed out" + noVerdict }
            if audit.output?.isError == true || exitCode != 0 { return who + " FAILED (exit \(exitCode))" + noVerdict }
            return who + " finished" + readIt
        }
    }

    /// The files the branch changed, `  path | +added -deleted`, at most
    /// `mostFiles` of them and then `  and N more`.
    private static func fileLines(base: String, branch: String, in repository: String) -> [String] {
        guard let numstat = Git.output(["diff", "--numstat", "\(base)..\(branch)"], in: repository) else { return [] }
        let files = numstat.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            // A binary file has no line counts: git prints dashes.
            let counts = Int(fields[0]) != nil && Int(fields[1]) != nil ? "+\(fields[0]) -\(fields[1])" : "binary"
            return "  \(fields[2]) | \(counts)"
        }
        return Array(files.prefix(mostFiles)) + (files.count > mostFiles ? ["  and \(files.count - mostFiles) more"] : [])
    }

    /// Where an editing worker's work is and how to take it.
    ///
    /// The worker was given a worktree and a branch of its own, so the
    /// orchestrator never has to hunt for the files: these two lines say how
    /// much the branch holds against the commit it was made from, and which
    /// tool puts it on the branch the maestro is working on and then takes the
    /// worktree away.
    ///
    /// When the commit failed the first line says so instead of reporting "no
    /// changes", which would leave the worker's edits stranded and unmentioned
    /// in the worktree.
    private static func branchLines(_ run: Run, audit: String?) -> [String] {
        guard let branch = run.branch, let base = run.baseCommit,
              let top = run.repository, let tree = run.worktree
        else { return [] }
        var lines: [String] = []
        if let failure = run.commitError {
            let reason = failure.isEmpty ? "git gave no reason" : failure
            lines.append("commit failed: \(reason) — the edits are still uncommitted in \(tree)")
        } else {
            let stat = Git.output(["diff", "--shortstat", "\(base)..\(branch)"], in: top)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(
                "changes on branch \(branch) (base \(base.prefix(7))): "
                    + (stat.map { $0.isEmpty ? "no changes" : $0 } ?? "no changes")
            )
            lines.append(contentsOf: fileLines(base: base, branch: branch, in: top))
        }
        if let audit {
            // The auditor is reading this worktree: the merge waits, and the
            // cleanup above all, or it would pull the files out from under it.
            lines.append("merge after the audit: \(audit) is reading this worktree")
        } else if run.isPaused {
            lines.append(
                "paused: worktree removed, branch \(branch) kept — agent_redo \(run.id) to continue it, "
                    + "or agent_merge \(run.id) to merge it"
            )
        } else {
            lines.append("merge: agent_merge \(run.id)")
        }
        return lines
    }
}

/// Sends the agent tools to the orchestrator and everything else to the panel.
public struct RoutingExecutor: ToolExecutor {
    private let agents: any ToolExecutor
    private let panel: any ToolExecutor

    public init(agents: any ToolExecutor, panel: any ToolExecutor) {
        self.agents = agents
        self.panel = panel
    }

    public func run(tool: String, arguments: JSONValue, pane: String?) async throws -> String {
        let executor = AgentTools.names.contains(tool) ? agents : panel
        return try await executor.run(tool: tool, arguments: arguments, pane: pane)
    }
}
