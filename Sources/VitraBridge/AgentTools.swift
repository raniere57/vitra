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
            In a git repository each editing worker is given a worktree and a branch of its own automatically, so several can edit at once; its report says how to merge the branch. \
            Outside a repository, give workers that edit at the same time a directory each: two editing the same checkout will overwrite one another.
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
        ProcessInfo.processInfo.environment["VITRA_PROJECT"].flatMap { $0.isEmpty ? nil : $0 }
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
            commands: try commands(in: arguments)
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
        return runs.map(AgentReport.full).joined(separator: "\n\n")
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
    static func full(_ run: Run) -> String {
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
        lines.append(contentsOf: branchLines(run))
        if !run.worktreeSkipped.isEmpty {
            lines.append("worktree setup skipped: " + run.worktreeSkipped.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    /// Where an editing worker's work is and how to take it.
    ///
    /// The worker was given a worktree and a branch of its own, so the
    /// orchestrator never has to hunt for the files: these two lines say how
    /// much the branch holds against the commit it was made from, and the
    /// commands that put it on the branch the maestro is working on and then
    /// take the worktree away.
    ///
    /// The paths are quoted: a repository called `my project; rm -rf ~` is a
    /// name, not a command, and the line is meant to be pasted into a shell.
    /// When the commit failed the first line says so instead of reporting "no
    /// changes", which would leave the worker's edits stranded and unmentioned
    /// in the worktree.
    private static func branchLines(_ run: Run) -> [String] {
        guard let branch = run.branch, let base = run.baseCommit,
              let top = run.repository, let tree = run.worktree
        else { return [] }
        let topArgument = ShellQuote.quote(top)
        let branchArgument = ShellQuote.quote(branch)
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
        lines.append(
            "merge: git -C \(topArgument) merge \(branchArgument) — then clean up: "
                + "git -C \(topArgument) worktree remove \(ShellQuote.quote(tree)) && "
                + "git -C \(topArgument) branch -d \(branchArgument)"
        )
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
