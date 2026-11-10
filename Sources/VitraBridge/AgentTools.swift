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
            Use the cheapest model that does this kind of task well — agent_models lists what is available and agent_scores how each has done so far. \
            The worker sees nothing of this conversation, so the prompt must stand on its own: the goal, the files or area, and what done looks like. \
            Spawn several and then agent_wait on all of them to run work in parallel. \
            In a git repository each editing worker is given a worktree and a branch of its own automatically, so several can edit at once; when its delivery is done and its audit read, agent_merge with its id puts the branch on your checkout and cleans up, and agent_merge with discard drops it instead. \
            Outside a repository, give workers that edit at the same time a directory each: two editing the same checkout will overwrite one another. \
            A finished editing delivery with commits is audited first by a cheap read-only worker from another provider: agent_wait starts it and says its id. Pass audit false for a change too small to be worth that gate.
            """,
            properties: [
                "cli": [
                    "type": "string",
                    "enum": .array(WorkerCLI.allCases.map { .string($0.rawValue) }),
                    "description": "Which agent CLI runs the worker.",
                ],
                "model": MCPTools.string("Model name as that CLI takes it, from agent_models: haiku, sonnet or opus for claude, opencode/…-free for opencode, a Gemini model id for gemini, a Grok id for cursor."),
                "effort": [
                    "type": "string",
                    "enum": .array(ModelCatalog.efforts.map { .string($0) }),
                    "description": "How hard the model thinks. Required for claude, from the pairs agent_models lists; optional for opencode; never for gemini, which has none, or cursor, where it is part of the model id. The same model at two efforts is two workers with separate records: start low for simple work and raise it when a delivery falls short.",
                ],
                "prompt": MCPTools.string("The whole task, self-contained."),
                "directory": MCPTools.string("Absolute path of the directory the worker runs in."),
                "access": [
                    "type": "string",
                    "enum": ["read", "edit"],
                    "description": "read (default): look, search and report, nothing is written. edit: the worker may change files in the directory.",
                ],
                "label": MCPTools.string("A few words saying what this worker is for, shown where agents are listed."),
                "override": [
                    "type": "string",
                    "description": "Only when agent_spawn refused this worker for the trial or the effort ladder and no other worker can do the piece: say why in a sentence.",
                ],
                "commands": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Commands the worker may run by itself, each the start of a command line: \"bun test\" allows \"bun test src/x.test.ts\". Give an editing worker the project's test, build or lint command so it can check its own work instead of handing that back to you. One plain command each — no shell operators — and nothing that reaches another machine, except for a task of kind deploy, which may be given ssh to the one host it deploys to (\"ssh user@host\"). claude and gemini run exactly these; opencode's editing agent runs commands already; cursor cannot be given any.",
                ],
                "kind": [
                    "type": "string",
                    "enum": .array(TaskKind.allCases.map { .string($0.rawValue) }),
                    "description": "What kind of task this is, so the model is judged against others on the same kind: explore (read, search, map code), review (judge existing work), implement (write or change code, fixes included), test (write or run tests), docs, deploy (ship reviewed work to production and watch it land), or other.",
                ],
                "audit": [
                    "type": "boolean",
                    "description": "Default true: a finished editing delivery whose branch has commits is first audited by a cheap read-only worker from another provider, and agent_wait gives the audit's id. false skips that gate for this run, for a change too small to be worth it.",
                ],
            ],
            required: ["cli", "model", "prompt", "directory"]
        ),
        MCPTools.tool(
            "agent_wait",
            "Wait for worker agents to finish and return what each one reported: its answer, whether it failed, how long it took and what it cost. Returns as soon as all of them have stopped, or at the timeout with the unfinished ones marked as still running — call again to keep waiting.",
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
            and branch away. Refuses while the worker is still running, while its audit is reading the worktree, and when \
            the checkout has uncommitted changes to tracked files. A merge that conflicts is aborted and the files are \
            named; the worktree and branch stay so the work can be sent back. Pass discard true to drop the work without \
            merging it.
            """,
            properties: [
                "id": MCPTools.string("Id from agent_spawn."),
                "discard": [
                    "type": "boolean",
                    "description": "Default false: merge the branch and clean up. true: drop the branch without merging it.",
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
            "Show how each worker has done so far, per kind of task, best first: those that deliver what was asked, fastest first; then those not rated yet; then those known to fall short. With each: average rating, runs, failures, median delivery time and cost. Check it before choosing a worker. While fewer than three providers have been rated for a kind, try a worker with no record there rather than reusing a rated one; after that take the first that fits, and still give an untried one a turn now and then.",
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
    /// How far back the trial rules look; past runs beyond it are old news.
    private static let historyLimit = 2000
    /// How far back the scoreboard looks.
    private static let scoredRuns = 2000

    private let orchestrator: Orchestrator
    private let executables: Executables
    /// The project this helper's maestro belongs to.
    private let project: String?

    /// The project the cockpit named in the maestro's shell, which this helper
    /// inherits. Absent when the helper was started outside the cockpit.
    public static var inheritedProject: String? {
        AgentIdentity.current.project
    }

    public init(executables: Executables = .discover()) {
        self.init(orchestrator: Orchestrator(executables: executables), executables: executables, project: Self.inheritedProject)
    }

    public init(orchestrator: Orchestrator, executables: Executables, project: String? = nil) {
        self.orchestrator = orchestrator
        self.executables = executables
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
                return try await Self.offThePool { [self] in
                    try merge(id: id, discard: discard)
                }
            case "agent_rate":
                return try rate(arguments)
            case "agent_scores":
                let kind = try Self.kind(in: arguments)
                let runs = orchestrator.recent(limit: Self.scoredRuns)
                return Scoreboard.summary(Scoreboard.scores(runs, kind: kind), kind: kind)
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
        let cliName = try string("cli", in: arguments)
        guard let cli = WorkerCLI(rawValue: cliName) else {
            let names = WorkerCLI.allCases.map(\.rawValue)
            let known = names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
            throw ToolError("cli must be \(known), not '\(cliName)'")
        }
        let accessName = arguments["access"]?.stringValue ?? WorkerAccess.read.rawValue
        guard let access = WorkerAccess(rawValue: accessName) else {
            throw ToolError("access must be read or edit, not '\(accessName)'")
        }

        let spec = WorkerSpec(
            cli: cli,
            model: try string("model", in: arguments),
            prompt: try string("prompt", in: arguments),
            directory: try string("directory", in: arguments),
            access: access,
            label: arguments["label"]?.stringValue,
            kind: try kind(in: arguments),
            effort: arguments["effort"]?.stringValue,
            project: project,
            commands: try commands(in: arguments),
            // Nil is the default, which is on: only an explicit false turns
            // the gate off, and an explicit true is kept as it was asked.
            audit: arguments["audit"]?.boolValue
        )
        // Held to the trial and the effort ladder, unless the maestro says
        // why it cannot be: the record is only worth choosing by if it was
        // earned by more than the first worker tried.
        let override = arguments["override"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if override.isEmpty, (try? spec.validate()) != nil,
           let problem = TrialRules.problem(with: spec, history: orchestrator.recent(limit: Self.historyLimit), providers: executables.paths.count) {
            throw ToolError(problem + " If none of those can do this piece, say why in override.")
        }
        let id = try orchestrator.spawn(spec)
        return "Started agent \(id): \(spec.worker), \(access.rawValue) access, in \(spec.directory). Call agent_wait with this id for its result."
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
    /// It blocks for as long as git takes, so its caller runs it off the
    /// cooperative pool. Reading git sets GIT_OPTIONAL_LOCKS=0 (see
    /// `Git.run`), so a status here cannot take the index lock out from under
    /// the user's own git.
    private func merge(id: String, discard: Bool) throws -> String {
        let run = try orchestrator.status(id)
        guard run.state != .running else {
            throw ToolError("agent \(id) is still running: wait for it to finish before merging")
        }
        guard let repository = run.repository, let worktree = run.worktree, let branch = run.branch else {
            throw ToolError("agent \(id) has no branch to merge: it did not edit a git repository")
        }
        // The auditor is reading this worktree; taking it away now would pull
        // the files out from under it.
        if let refusal = auditRefusal(id) {
            throw ToolError(refusal)
        }

        if !discard {
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
                _ = Git.run(["merge", "--abort"], in: repository)
                let files = conflicts.isEmpty
                    ? " — git said: " + Self.reason(merged)
                    : ": " + conflicts.joined(separator: ", ")
                throw ToolError(
                    "merge of \(branch) conflicts\(files) — the merge was aborted and \(worktree) and \(branch) "
                        + "are still there; send the work back to agent \(id) to resolve"
                )
            }
        }

        let removed = Git.run(["worktree", "remove", "--force", worktree], in: repository)
        let deleted = Git.run(["branch", "-D", branch], in: repository)

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
        if removed.succeeded {
            lines.append("Removed worktree \(worktree).")
        } else {
            lines.append("Could not remove worktree \(worktree): " + Self.reason(removed))
        }
        if deleted.succeeded {
            lines.append("Deleted branch \(branch).")
        } else {
            lines.append("Could not delete branch \(branch): " + Self.reason(deleted))
        }
        return lines.joined(separator: "\n")
    }

    /// The refusal for a run an audit is still reading, if one is.
    ///
    /// `pending` is a claim another wait has taken and is spawning behind, so
    /// there is no auditor id to name yet.
    private func auditRefusal(_ id: String) -> String? {
        guard let directory = orchestrator.directory(of: id) else { return nil }
        let record = directory.appendingPathComponent("audit")
        guard let text = try? String(contentsOf: record, encoding: .utf8) else { return nil }
        let audit = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if audit.isEmpty || audit == "pending" {
            return "an audit is still reading this worktree; agent_wait on it first"
        }
        guard let reading = try? orchestrator.status(audit), reading.state == .running else { return nil }
        return "the audit \(audit) is still reading this worktree; agent_wait on it first"
    }

    /// What git printed, trimmed, or nil when it printed nothing.
    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What git said, in one line, for a failure that has no better words.
    private static func reason(_ result: (succeeded: Bool, output: String)) -> String {
        let text = trimmed(result.output)
        return text.isEmpty ? "git gave no reason" : text.split(whereSeparator: \.isNewline).joined(separator: " ")
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

        let runs = try await orchestrator.wait(ids: ids, timeout: TimeInterval(timeout))
        var gates: [String: Gate] = [:]
        for run in runs {
            // Reading the history and starting an auditor both touch the disk
            // and one of them starts a process: keep them off the pool, as
            // agent_spawn does.
            if let gate = try? await Self.offThePool({ [self] in self.gate(for: run) }) {
                gates[run.id] = gate
            }
        }
        return runs.map { run in
            let gate = gates[run.id]
            let report = AgentReport.full(run, audit: gate?.reading)
            guard let line = gate?.line else { return report }
            return report + "\n" + line
        }.joined(separator: "\n\n")
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

        let record = directory.appendingPathComponent("audit")
        if FileManager.default.fileExists(atPath: record.path) {
            return Self.existingGate(record, orchestrator: orchestrator)
        }
        guard run.spec.audit != false else { return Gate() }

        // No commit means no diff to audit; the report already says the edits
        // are still uncommitted in the worktree.
        let counted = Git.output(["rev-list", "--count", "\(base)..\(branch)"], in: repository)
        guard let commits = counted.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
              commits > 0
        else { return Gate() }

        let history = orchestrator.recent(limit: Self.scoredRuns)
        guard let choice = Audit.chooseAuditor(
            implementer: run.spec,
            history: history,
            installed: Set(executables.paths.keys)
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
            project: run.spec.project
        )
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

    /// One line: who, what state, how long, what it cost.
    static func headline(_ run: Run) -> String {
        let state: String
        switch run.state {
        case .running: state = "running"
        case .cancelled: state = "cancelled"
        case .lost: state = "LOST (the process is gone and left no result)"
        case let .finished(exitCode):
            if run.output?.isError == true {
                state = exitCode == 0 ? "FAILED" : "FAILED (exit \(exitCode))"
            } else {
                state = "finished"
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
        if let rating = run.rating { fields.append("rated \(rating.score)/5") }
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
    static func gate(_ audit: Run) -> String {
        let state: String
        switch audit.state {
        case .running: state = "running"
        case .cancelled: state = "cancelled"
        case .lost: state = "LOST"
        case let .finished(exitCode):
            state = audit.output?.isError == true || exitCode != 0 ? "FAILED (exit \(exitCode))" : "finished"
        }
        return "gate: audit \(audit.id) by \(audit.spec.worker) \(state) — read its verdict before reviewing yourself."
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
        }
        if let audit {
            // The auditor is reading this worktree: the merge waits, and the
            // cleanup above all, or it would pull the files out from under it.
            lines.append("merge after the audit: \(audit) is reading this worktree")
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
