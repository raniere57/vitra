import Foundation

/// A command-line agent the orchestrator can run headless as a worker.
public enum WorkerCLI: String, Codable, Sendable, CaseIterable {
    case claude
    case opencode
    case gemini
    case cursor

    /// The name the CLI installs under.
    var executableName: String {
        switch self {
        case .claude: return "claude"
        case .opencode: return "opencode"
        // Antigravity's CLI: the gemini CLI no longer takes the Google AI
        // subscription, and this one does.
        case .gemini: return "agy"
        case .cursor: return "cursor-agent"
        }
    }

    /// Whether the CLI reads its prompt from stdin.
    ///
    /// Stdin is preferred wherever it works: the prompt is then never an
    /// argument, so it cannot be mistaken for a flag and has no length limit.
    /// cursor-agent only takes its prompt as an argument, so the launcher
    /// appends it after the `--` its arguments end with.
    public var takesPromptOnStdin: Bool { self != .cursor && self != .gemini }

    /// The flag a prompt given as an argument is fastened to, for a CLI that
    /// takes it that way. agy reads `-p <prompt>` but refuses a prompt that
    /// looks like a flag; `-p=<prompt>` is never mistaken for one.
    public var promptFlag: String? { self == .gemini ? "-p=" : nil }
}

/// What a worker may do to the directory it runs in.
public enum WorkerAccess: String, Codable, Sendable {
    /// Look, search and report. Nothing is written.
    case read
    /// Edit files. Commands the user has not allowed are still refused.
    case edit
}

public enum OrchestratorError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSpec(String)
    case executableNotFound(WorkerCLI)
    case unknownRun(String)
    case spawnFailed(String)

    public var description: String {
        switch self {
        case let .invalidSpec(reason): return reason
        case let .executableNotFound(cli): return "the \(cli.rawValue) CLI is not installed or not on PATH"
        case let .unknownRun(id): return "no agent with id '\(id)'"
        case let .spawnFailed(reason): return "could not start the agent: \(reason)"
        }
    }
}

/// One piece of work handed to one worker.
public struct WorkerSpec: Codable, Equatable, Sendable {
    public let cli: WorkerCLI
    public let model: String
    public let prompt: String
    public let directory: String
    public let access: WorkerAccess
    /// A few words saying what this worker is for, shown wherever runs are listed.
    public let label: String?
    /// What kind of work this is, so the run is compared with others like it.
    public let kind: TaskKind?
    /// How hard the model is asked to think, where the CLI takes that apart
    /// from the model. The same model at two efforts is two workers: one is
    /// cheaper and faster, the other better, and each earns its own record.
    public let effort: String?
    /// The project whose maestro asked for this worker, when it was a cockpit's
    /// maestro that asked. Not the directory it runs in: a worker is often
    /// sent to a worktree kept somewhere else, and is still that project's.
    public let project: String?
    /// The commands the worker may run without anyone to approve them, each
    /// the start of a command line: `bun test` allows `bun test src/x.test.ts`.
    /// A worker that can edit but not run its tests cannot check its own work.
    public let commands: [String]
    /// Whether a finished editing delivery is sent to an auditor first.
    ///
    /// Nil is the default and means yes; only an explicit false turns the
    /// gate off. Optional so a record written before the gate existed still
    /// loads, and so the common case leaves nothing extra in run.json.
    public let audit: Bool?

    public init(
        cli: WorkerCLI,
        model: String,
        prompt: String,
        directory: String,
        access: WorkerAccess = .read,
        label: String? = nil,
        kind: TaskKind? = nil,
        effort: String? = nil,
        project: String? = nil,
        commands: [String] = [],
        audit: Bool? = nil
    ) {
        self.cli = cli
        self.model = model
        self.prompt = prompt
        self.directory = directory
        self.access = access
        self.label = label
        self.kind = kind
        self.effort = effort
        self.project = project
        self.commands = commands
        self.audit = audit
    }

    // Runs recorded before a field existed must still load, and a field that
    // was never set must not be written as a pile of nulls and empty lists.
    private enum CodingKeys: String, CodingKey {
        case cli, model, prompt, directory, access, label, kind, effort, project, commands, audit
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cli = try values.decode(WorkerCLI.self, forKey: .cli)
        model = try values.decode(String.self, forKey: .model)
        prompt = try values.decode(String.self, forKey: .prompt)
        directory = try values.decode(String.self, forKey: .directory)
        access = try values.decodeIfPresent(WorkerAccess.self, forKey: .access) ?? .read
        label = try values.decodeIfPresent(String.self, forKey: .label)
        kind = try values.decodeIfPresent(TaskKind.self, forKey: .kind)
        effort = try values.decodeIfPresent(String.self, forKey: .effort)
        project = try values.decodeIfPresent(String.self, forKey: .project)
        commands = try values.decodeIfPresent([String].self, forKey: .commands) ?? []
        audit = try values.decodeIfPresent(Bool.self, forKey: .audit)
    }

    static let mostCommands = 8

    /// Whether `command` names one command and nothing that could widen it.
    ///
    /// The string ends up inside a permission rule, `Bash(<command>:*)`. Only
    /// letters, digits, spaces and the few marks a command line needs are let
    /// through: no wildcard, no `;`, `&`, `|`, `$`, backtick or redirection to
    /// chain or substitute a second command, and no bracket to close the rule
    /// early. A handful of commands are refused by name, because allowing
    /// their every form is allowing anything.
    ///
    /// `ssh` is the one exception, and only for a deploy: a deploy is run on
    /// the server, so the worker doing it is allowed ssh to the one host named
    /// — `ssh user@host`, never a bare `ssh` that would reach any.
    static func isPlainCommand(_ command: String, kind: TaskKind? = nil) -> Bool {
        let isPlain = command.range(of: #"^[A-Za-z0-9./_][A-Za-z0-9 ._/:=@+-]{0,79}$"#, options: .regularExpression) != nil
        let words = command.split(separator: " ").map(String.init)
        let first = words.first ?? ""
        let tooBroad = ["sudo", "rm", "sh", "bash", "zsh", "eval", "exec", "curl", "wget", "env", "xargs"]
        let isDeploySSH = kind == .deploy && words.count == 2 && !words[1].hasPrefix("-")
        return isPlain && !command.hasSuffix(" ") && !tooBroad.contains(first) && (first != "ssh" || isDeploySSH)
    }

    /// The worker as it is named wherever runs are listed and compared.
    public var worker: String {
        "\(cli.rawValue) \(model)" + (effort.map { " (\($0))" } ?? "")
    }

    /// Everything after the executable.
    ///
    /// The prompt is not here: it goes in on stdin, so a prompt that starts with
    /// a dash is never read as a flag and its length is not bounded by ARG_MAX.
    ///
    /// Neither CLI is ever told to skip its permission checks. An editing worker
    /// accepts edits; whether it may run a given command is still decided by the
    /// user's own allow rules for that CLI.
    public var arguments: [String] { arguments(browserConfig: nil) }

    /// The arguments, with Vitra's browser handed to the worker when
    /// `browserConfig` names the MCP configuration that serves it.
    public func arguments(browserConfig: String?) -> [String] {
        switch cli {
        case .claude:
            let base = ["-p", "--model", model, "--output-format", "json"] + (effort.map { ["--effort", $0] } ?? [])
            let mode = access == .edit ? ["--permission-mode", "acceptEdits"] : []
            // Each command becomes a rule that matches that command and
            // whatever follows it, and nothing else.
            // Vitra's own tools need no one's approval either: headless,
            // there is no one, and a tool that waits for approval is refused.
            let rules = (browserConfig == nil ? [] : ["mcp__vitra"]) + commands.map { "Bash(\($0):*)" }
            let server = browserConfig.map { ["--mcp-config", $0] } ?? []
            return base + mode + server + (rules.isEmpty ? [] : ["--allowedTools"] + rules)
        case .opencode:
            // opencode takes the effort as a variant of the model.
            let base = ["run", "--format", "json", "-m", model + (effort.map { "#" + $0 } ?? "")]
            // opencode's built-in plan agent is its read-only one.
            return access == .read ? base + ["--agent", "plan"] : base
        case .gemini:
            // Left in its default mode a headless agy has nobody to ask, so
            // it refuses every write and every command: that is the read-only
            // worker. accept-edits lets it write files and still run nothing.
            // (Its plan mode is not read-only, it is a different job: it
            // writes a plan and waits for a go-ahead nobody will give.)
            let base = ["--output-format", "json", "--model", model]
            return access == .edit ? base + ["--mode", "accept-edits"] : base
        case .cursor:
            let base = ["-p", "--model", model, "--output-format", "json"]
            // `ask` is cursor's read-only mode. `--trust` is what lets it start
            // at all without a terminal: it will not run headless in a folder
            // it has not been told to trust, and the folder is the project the
            // maestro is already working in. It is not `--force`, which is
            // never passed. The trailing `--` ends the options: the prompt is
            // appended after it.
            // cursor reads its MCP servers from its own file and, headless,
            // uses none it has not been told to approve.
            let servers = browserConfig == nil ? [] : ["--approve-mcps"]
            return (access == .read ? base + ["--mode", "ask"] : base) + servers + ["--trust", "--"]
        }
    }

    /// Refuses a spec that could not run, or whose fields would be read as
    /// something other than what they are. The fields come from a model.
    public func validate() throws(OrchestratorError) {
        // A model name is a flag's value; one starting with a dash would be
        // taken for a flag of its own.
        // Brackets and `=` are there for cursor's parameterised names, such as
        // gpt-5[reasoning=high].
        let isModelName = model.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._/#:~@\[\]=,-]*$"#,
            options: .regularExpression
        ) != nil
        guard isModelName else {
            throw .invalidSpec("'\(model)' is not a model name")
        }
        if let effort, !ModelCatalog.efforts.contains(effort) {
            throw .invalidSpec("effort must be one of \(ModelCatalog.efforts.joined(separator: ", ")), not '\(effort)'")
        }
        if let problem = ModelCatalog.problem(with: cli, model: model, effort: effort) {
            throw .invalidSpec(problem)
        }
        guard commands.count <= Self.mostCommands else {
            throw .invalidSpec("a worker can be allowed at most \(Self.mostCommands) commands")
        }
        for command in commands where !Self.isPlainCommand(command, kind: kind) {
            throw .invalidSpec("'\(command)' is not a command a worker can be allowed: name one plain command, such as bun test")
        }
        guard commands.isEmpty || (cli != .cursor && cli != .gemini) else {
            // Neither takes a list for one run. cursor runs everything
            // (--force) or asks; agy keeps its allowed commands in settings
            // files that would apply to every run at once. Headless, there is
            // nobody to ask, so they get none.
            throw .invalidSpec("\(cli.rawValue) workers cannot be allowed commands: use claude for a piece that must run them")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidSpec("the prompt is empty")
        }
        guard directory.hasPrefix("/") else {
            throw .invalidSpec("the directory must be an absolute path: \(directory)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .invalidSpec("no such directory: \(directory)")
        }
    }
}
