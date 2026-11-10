import CryptoKit
import Foundation
import VitraCore
import VitraOrchestrator

/// A project the cockpit has a tab for: a directory, and the conversation its
/// maestro is having there.
struct CockpitProject: Codable, Equatable {
    let path: String

    /// The id of the maestro's conversation in this project.
    ///
    /// Chosen by the cockpit and handed to claude when the maestro first
    /// starts, rather than read back from claude afterwards: workers run in
    /// the same folder and leave conversations of their own there, so "the
    /// newest conversation in this folder" is as likely a worker's as the
    /// maestro's.
    var session: String?

    init(path: String, session: String? = nil) {
        // One spelling per directory, so a trailing slash never makes a
        // second tab for the same place.
        self.path = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        self.session = session
    }

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum CockpitProjects {
    /// `projects` with `path` open; unchanged when it already is.
    static func adding(_ path: String, to projects: [CockpitProject]) -> [CockpitProject] {
        let project = CockpitProject(path: path)
        return projects.contains { $0.path == project.path } ? projects : projects + [project]
    }
}

/// What the cockpit remembers between launches: the tabs, which one was in
/// front, and each maestro's conversation. Quitting ends the maestros; this is
/// what lets reopening put everything back where it was.
struct CockpitState: Codable, Equatable {
    var projects: [CockpitProject] = []
    var selected = 0

    static var defaultURL: URL { Vitra.supportDirectory.appendingPathComponent("cockpit.json") }

    /// What was saved, or an empty cockpit when there is no file or it cannot
    /// be read: a damaged state costs the tabs, never the launch.
    static func load(from url: URL = defaultURL) -> CockpitState {
        guard let data = try? Data(contentsOf: url) else { return CockpitState() }
        let decoder = JSONDecoder()
        // The first cockpit saved a bare list of projects.
        let saved = (try? decoder.decode(CockpitState.self, from: data))
            ?? (try? decoder.decode([CockpitProject].self, from: data)).map { CockpitState(projects: $0) }
            ?? CockpitState()
        return saved.repaired
    }

    func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// The state with anything a file should not be trusted on put right.
    ///
    /// The session id is typed into a shell as part of a command, so it is
    /// kept only when it is exactly a UUID; the tab index is brought back
    /// inside the tabs there are.
    private var repaired: CockpitState {
        let projects = projects.map { project in
            let isUUID = project.session.flatMap { UUID(uuidString: $0) } != nil
            return isUUID ? project : CockpitProject(path: project.path)
        }
        let last = max(projects.count - 1, 0)
        return CockpitState(projects: projects, selected: min(max(selected, 0), last))
    }
}

/// One worker, as a row of the workers panel reads it.
struct WorkerRow: Equatable {
    enum Kind: Equatable {
        case running
        case done
        case failed
        /// Stopped on purpose: not a result, not a failure.
        case stopped
    }

    let id: String
    let title: String
    let kind: Kind
    let stateText: String
    let meta: String
    /// The worker's answer, shown when the row is opened.
    let detail: String?
}

/// One model's record at one kind of task, as a line of the ranking.
struct RankingRow: Equatable {
    let kind: String
    let model: String
    /// The average rating, or a dash when it has none.
    let score: String
    /// The median time of a delivery, or a dash when it never delivered.
    let time: String
    /// Deliveries that stood out of those tried, as "5/6".
    let deliveries: String
    let cost: String
    /// How many ratings the score rests on.
    let ratings: String
}

/// Turns runs into what the workers panel shows.
enum WorkerBoard {
    private static let longestTitle = 60
    private static let longestReason = 68

    /// The runs that belong to `project`.
    ///
    /// A run says which project's maestro asked for it, and that settles it
    /// wherever the worker was sent: maestros routinely work in a worktree
    /// kept outside the project's folder. Only a run that names no project —
    /// spawned outside the cockpit — is placed by the directory it ran in.
    static func runs(_ runs: [Run], in project: CockpitProject) -> [Run] {
        runs.filter { run in
            if let owner = run.spec.project { return owner == project.path }
            return run.spec.directory == project.path || run.spec.directory.hasPrefix(project.path + "/")
        }
    }

    static func row(_ run: Run, now: Date) -> WorkerRow {
        let model = shortName(run.spec.model, effort: run.spec.effort)
        let elapsed = duration((run.ended ?? now).timeIntervalSince(run.started))
        let kind = kind(of: run)

        let tail: String
        switch kind {
        case .running:
            tail = run.spec.access == .edit ? "edita" : "só leitura"
        case .done:
            let output = run.output
            tail = money(output?.costUSD ?? 0) + " · " + tokens((output?.inputTokens ?? 0) + (output?.outputTokens ?? 0))
        case .failed:
            // For a delivery judged unsatisfactory the reason is the
            // maestro's note, not the worker's own account of a job well done.
            let judged = delivered(run) ? run.rating?.note : nil
            tail = shortened(firstLine(judged ?? run.output?.text ?? run.errorTail ?? "sem resposta"), to: longestReason)
        case .stopped:
            tail = "parado por você"
        }

        return WorkerRow(
            id: run.id,
            title: shortened(run.spec.label.flatMap { $0.isEmpty ? nil : firstLine($0) } ?? firstLine(run.spec.prompt), to: longestTitle),
            kind: kind,
            stateText: (delivered(run) && run.rating?.isSatisfactory == false ? "insatisfatório" : stateText(run.state, kind))
                + (run.rating.map { " · \($0.score)/5" } ?? ""),
            meta: [model, elapsed, tail].joined(separator: " · "),
            detail: run.output?.text
        )
    }

    /// "2 rodando · 1 pronto", for the panel's header.
    static func summary(_ runs: [Run], now: Date) -> String {
        let kinds = runs.map(kind(of:))
        let parts = [
            (WorkerRow.Kind.running, "rodando"),
            (.done, kinds.filter { $0 == .done }.count == 1 ? "pronto" : "prontos"),
            (.failed, kinds.filter { $0 == .failed }.count == 1 ? "falhou" : "falharam"),
        ].compactMap { kind, word -> String? in
            let count = kinds.filter { $0 == kind }.count
            return count == 0 ? nil : "\(count) \(word)"
        }
        return parts.isEmpty ? "nenhum ainda" : parts.joined(separator: " · ")
    }

    static func runningCount(_ runs: [Run]) -> Int {
        runs.filter { $0.state == .running }.count
    }

    /// What the runs started at or after `since` cost, and how many tokens
    /// they moved.
    static func totals(_ runs: [Run], since: Date) -> (cost: Double, tokens: Int) {
        runs.filter { $0.started >= since }.reduce(into: (cost: 0.0, tokens: 0)) { totals, run in
            totals.cost += run.output?.costUSD ?? 0
            totals.tokens += (run.output?.inputTokens ?? 0) + (run.output?.outputTokens ?? 0)
        }
    }

    /// The scoreboard as the ranking window shows it.
    static func ranking(_ scores: [ModelScore]) -> [RankingRow] {
        scores.map { score in
            RankingRow(
                kind: kindName(score.kind),
                model: shortName(score.model, effort: score.effort),
                score: score.averageScore.map { String(format: "%.1f", $0) } ?? "—",
                time: score.medianSeconds.map(duration) ?? "—",
                deliveries: "\(score.runs - score.failures)/\(score.runs)",
                cost: money(score.costUSD),
                ratings: score.rated == 0 ? "sem avaliação" : "\(score.rated) \(score.rated == 1 ? "avaliação" : "avaliações")"
            )
        }
    }

    /// Whether the worker ran to the end and reported a result.
    private static func delivered(_ run: Run) -> Bool {
        if case .finished = run.state { return run.output?.isError != true }
        return false
    }

    /// A model as a row has room for it: without its provider, with its effort.
    private static func shortName(_ model: String, effort: String?) -> String {
        (model.split(separator: "/").last.map(String.init) ?? model) + (effort.map { " (\($0))" } ?? "")
    }

    static func kindName(_ kind: TaskKind) -> String {
        switch kind {
        case .explore: return "explorar"
        case .review: return "revisar"
        case .implement: return "implementar"
        case .test: return "testar"
        case .docs: return "documentar"
        case .deploy: return "deploy"
        case .other: return "outros"
        }
    }

    // MARK: - Formatting

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, total % 3600 / 60)
    }

    static func tokens(_ count: Int) -> String {
        if count < 1000 { return "\(count) tokens" }
        if count < 1_000_000 { return "\(Int((Double(count) / 1000).rounded()))k tokens" }
        return String(format: "%.1fM tokens", Double(count) / 1_000_000)
    }

    static func money(_ dollars: Double) -> String {
        String(format: "$%.2f", dollars)
    }

    private static func kind(of run: Run) -> WorkerRow.Kind {
        switch run.state {
        case .running: return .running
        case .cancelled: return .stopped
        case .lost: return .failed
        case .finished:
            // Finished and judged not to be what was asked is a failure, the
            // same as one that never delivered.
            return run.output?.isError == true || run.rating?.isSatisfactory == false ? .failed : .done
        }
    }

    private static func stateText(_ state: Run.State, _ kind: WorkerRow.Kind) -> String {
        switch kind {
        case .running: return "rodando"
        case .done: return "pronto"
        case .stopped: return "cancelado"
        case .failed: return state == .lost ? "perdido" : "falhou"
        // (An unsatisfactory delivery is named in `row`, which knows the rating.)
        }
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func shortened(_ text: String, to length: Int) -> String {
        text.count <= length ? text : text.prefix(length - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// How the orchestrating agent is started in a project's terminal.
enum Maestro {
    /// Where the cockpit keeps what it writes for the maestro and hears from it.
    static var supportDirectory: URL { Vitra.supportDirectory.appendingPathComponent("maestro") }

    /// What the maestro is told about its job, on top of its own instructions.
    static let brief = """
    You are the orchestrator in Vitra. Your job is to plan, delegate, review and answer — not to do the work yourself. \
    Workers on cheaper models do the work: you reach them with the vitra agent_spawn tool (agent_models lists them), \
    collect what they deliver with agent_wait, and review every delivery before you report.

    Delegate by default. Any change to code, however small it looks, and any investigation that takes more than a \
    handful of reads or commands goes to a worker, split into self-contained pieces that can run in parallel. "It is \
    quicker to do it myself" is not a reason: your attention is the expensive resource here, and theirs is cheap.

    Keep for yourself only these: planning and decisions; the final review; a quick question you can answer from \
    what you already know or from a glance at a file, which needs no worker — just answer it; and what cannot be \
    undone in production — deleting or rewriting production data, changing credentials — which you run yourself.

    A deploy is a worker's job too, of kind deploy, once you have reviewed what is being shipped. Watching a build \
    and reading logs is waiting, and waiting in your context is the most expensive kind. Give the worker the \
    project's exact procedure and the commands it needs (an ssh to the one host, the deploy script), and require \
    proof in its report: what it ran, the health check, the log lines that show the new version up. Rate it on \
    whether it followed the procedure, watched the deploy through to the end instead of assuming, said plainly when \
    something failed, and how long it took. The best and fastest becomes the one who deploys.

    If you do yourself something a worker could have done, say so in one line and say why.

    Choose each worker from its record. Tag every agent_spawn with its kind of task, and before choosing call \
    agent_scores for that kind. A worker is a model at an effort: haiku at low and haiku at high are two workers with \
    separate records. The best worker is the cheapest, fastest one that does the job well — quality is a bar to \
    clear, and past it a fast, cheap worker beats a slow, dear one that does a little better; agent_scores is ordered \
    that way. That is only found out by trying the cheap ones, so agent_spawn holds you to two rules: until workers \
    from three providers have been rated on a kind, a worker already rated on it is not used for it again; and a \
    model runs at its lowest effort before a higher one. Start each kind with the fast, cheap workers — a free \
    opencode model, gemini flash at low, a grok at low, haiku at low — and move up only when one falls short. When \
    agent_spawn refuses a worker, pick another; pass override only when no other worker can do the piece, and say \
    why. After the trial, take the first in agent_scores that fits, and still give an untried worker about one piece \
    in five. After reviewing a delivery, always record your verdict with agent_rate, honestly; a poor delivery rated \
    well sends the next task to the wrong worker.

    The project has a shared terminal, in Vitra's Terminal tab, that the user types in too. terminal_read shows \
    what is on it: read it when the user refers to something they ran or saw there. terminal_run types a command \
    into it, for what the user should watch or keep using afterwards — a dev server, a long build, a log being \
    followed; for everything else use your own shell. Workers can read it and cannot type in it.

    Let workers check their own work. When a piece has a test, build or lint command, pass it in the worker's \
    commands so it can run it and fix what fails before delivering, instead of handing the checking back to you.

    A worker fails in one of two ways, and each has its answer.

    It did not run: it crashed, timed out, or its CLI was signed out or its API down. Nothing was delivered, so there \
    is nothing to rate. Give the piece straight to another worker, preferably one from another provider — a different \
    cli — since whatever stopped this one may stop its neighbours too.

    It ran but did not do what was asked: the result is wrong, incomplete, or needed real fixes from you. That is a \
    failure too, and the more important one. Rate it for what it is — below 4 — and say why in the note. You may give \
    the same worker one more try with a sharper prompt. If it falls short a second time, stop retrying: give the piece \
    to a more capable worker, a stronger model or a higher effort, whichever you judge fits the task.
    """

    /// The MCP configuration that gives the maestro Vitra's tools, as JSON.
    ///
    /// Passed on the command line rather than written into the user's own
    /// Claude settings: the tools exist for sessions the cockpit starts, and
    /// nothing is left behind in a file the user did not ask to have changed.
    static func mcpConfig(binary: String) -> String {
        let config: [String: Any] = ["mcpServers": ["vitra": ["command": binary, "args": ["mcp"]]]]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes the maestro's MCP configuration and brief into `directory` and
    /// returns the line that starts it, as typed into the project's shell.
    ///
    /// Both go in files rather than on the command line. Typed out, the JSON
    /// and the brief fill the first screen of every project with text meant
    /// for the model, before the user has typed a word.
    ///
    /// `claude` is the command with whatever flags the user configured for it.
    static func install(
        binary: String,
        claude: String,
        conversation: Conversation,
        in directory: URL
    ) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("mcp.json")
        let instructions = directory.appendingPathComponent("brief.md")
        let settings = directory.appendingPathComponent("settings.json")
        try Data(mcpConfig(binary: binary).utf8).write(to: config, options: .atomic)
        try Data(brief.utf8).write(to: instructions, options: .atomic)
        try Data(Self.settings(binary: binary).utf8).write(to: settings, options: .atomic)
        return launchLine(
            claude: claude,
            conversation: conversation,
            config: config.path,
            settings: settings.path,
            brief: instructions.path
        )
    }

    /// How the maestro picks up its conversation.
    enum Conversation: Equatable {
        /// Start a conversation under this id.
        case new(String)
        /// Carry on the conversation with this id.
        case resume(String)
    }

    /// Where claude keeps its conversations, one folder per project.
    static var conversationsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    /// Whether to start `id` or resume it.
    ///
    /// claude writes a conversation down only once something has been said in
    /// it, and resuming an id it never wrote down is an error at its prompt.
    /// So an id is resumed only when its file is there; until then the same id
    /// is simply started again.
    static func conversation(_ id: String, in directory: URL = conversationsDirectory) -> Conversation {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let exists = folders.contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(id + ".jsonl").path)
        }
        return exists ? .resume(id) : .new(id)
    }

    /// Settings laid over the user's own for the maestro's session alone.
    ///
    /// Remote Control is off: the maestro runs without asking for permission,
    /// and a session like that is not one to leave reachable from another
    /// device, whatever the user's default for ordinary sessions is.
    ///
    /// The hook is how the cockpit learns which conversation the maestro is
    /// in. claude runs it whenever a session starts — at launch, and again
    /// when the user moves to another conversation with /resume or /clear —
    /// and hands it the session's id.
    static func settings(binary: String) -> String {
        let hook: [String: Any] = ["type": "command", "command": ShellQuote.quote(binary) + " maestro-session"]
        let settings: [String: Any] = [
            "remoteControlAtStartup": false,
            "hooks": ["SessionStart": [["hooks": [hook]]]],
            "statusLine": ["type": "command", "command": MaestroStatus.command(binary: binary)],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Which conversation the maestro is in

    /// Where the hook leaves each project's current conversation.
    static var sessionsDirectory: URL {
        Vitra.supportDirectory.appendingPathComponent("maestro/sessions")
    }

    /// What `Vitra maestro-session` does with the hook's input: notes the
    /// session as the one `project`'s maestro is in.
    ///
    /// Kept apart from the cockpit's own state file on purpose. This runs in a
    /// separate, short-lived process while the app is open and holding its
    /// state in memory; two writers of one file would lose each other's
    /// changes. Failures are silent: whatever a SessionStart hook prints goes
    /// into the conversation.
    static func recordSession(hookInput: Data, project: String?, in directory: URL = sessionsDirectory) {
        guard let input = (try? JSONSerialization.jsonObject(with: hookInput)) as? [String: Any],
              let session = input["session_id"] as? String,
              UUID(uuidString: session) != nil,
              let path = project ?? input["cwd"] as? String
        else { return }
        let record = ["path": CockpitProject(path: path).path, "session": session]
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: sessionFile(for: path, in: directory), options: .atomic)
    }

    /// The conversation `project`'s maestro was last in, when one was noted.
    static func rememberedSession(for project: String, in directory: URL = sessionsDirectory) -> String? {
        guard let data = try? Data(contentsOf: sessionFile(for: project, in: directory)),
              let record = try? JSONDecoder().decode([String: String].self, from: data),
              record["path"] == CockpitProject(path: project).path,
              let session = record["session"],
              UUID(uuidString: session) != nil
        else { return nil }
        return session
    }

    /// One file per project, named by a digest of its path: a path is not a
    /// file name, and two paths must never share one.
    static func sessionFile(for project: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(CockpitProject(path: project).path.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    static func launchLine(
        claude: String,
        conversation: Conversation,
        config: String,
        settings: String,
        brief: String
    ) -> String {
        let pickUp: [String] = switch conversation {
        case let .new(id): ["--session-id", ShellQuote.quote(id)]
        case let .resume(id): ["--resume", ShellQuote.quote(id)]
        }
        return ([claude] + pickUp + [
            "--mcp-config", ShellQuote.quote(config),
            "--settings", ShellQuote.quote(settings),
            "--append-system-prompt-file", ShellQuote.quote(brief),
        ]).joined(separator: " ") + "\n"
    }
}

/// How much of the subscription has been used, as claude last reported it.
struct SubscriptionUsage: Codable, Equatable {
    /// Percent of the weekly limit used.
    let sevenDay: Double?
    /// Percent of the five-hour limit used.
    let fiveHour: Double?
    let updated: Date
}

/// The model a project's maestro is running on, and how hard it is thinking.
struct MaestroModel: Codable, Equatable {
    let name: String
    let effort: String?
}

/// The usage figure as the maestro's bar shows it.
struct UsageLabel: Equatable {
    enum Level: Equatable {
        case calm
        /// Three quarters gone: worth a look.
        case warm
        /// Nearly out.
        case hot
    }

    let text: String
    let level: Level
}

/// The maestro's status line, which Vitra sits in front of.
///
/// claude hands its status line command the session's state as JSON, the
/// subscription's usage limits among it. That is the only place those figures
/// are offered without reading the user's credentials and calling the API with
/// them. So the maestro's status line is `Vitra maestro-status`: it notes the
/// usage for the cockpit's bar, then runs the status line the user already had
/// and prints what that prints, so nothing changes in the terminal.
enum MaestroStatus {
    private static let warmFrom = 75.0
    private static let hotFrom = 90.0
    /// Past this the figure is no longer the week's usage, and none is shown.
    private static let staleAfter: TimeInterval = 48 * 3600

    static var usageFile: URL { Maestro.supportDirectory.appendingPathComponent("usage.json") }
    static var userSettings: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    static func command(binary: String) -> String {
        ShellQuote.quote(binary) + " maestro-status"
    }

    /// The usage in a status line's input, or nil when it carries none —
    /// claude has no limits to report before a session's first reply.
    static func usage(fromStatusInput data: Data, now: Date) -> SubscriptionUsage? {
        guard let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = input["rate_limits"] as? [String: Any]
        else { return nil }
        let used = { (window: String) in
            ((limits[window] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue
        }
        let usage = SubscriptionUsage(sevenDay: used("seven_day"), fiveHour: used("five_hour"), updated: now)
        return usage.sevenDay == nil && usage.fiveHour == nil ? nil : usage
    }

    /// The model and effort in what claude hands its status line.
    ///
    /// The model is always there. The effort is read from wherever this
    /// version of claude puts it, and failing that from `fallbackEffort` —
    /// the user's own setting, which is what a session starts with.
    static func model(fromStatusInput data: Data, fallbackEffort: String?) -> MaestroModel? {
        guard let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let model = input["model"] as? [String: Any],
              let name = (model["display_name"] ?? model["id"]) as? String, !name.isEmpty
        else { return nil }
        let level = { (value: Any?) -> String? in
            (value as? String) ?? ((value as? [String: Any])?["level"] as? String)
        }
        let effort = level(input["effort"]) ?? level(model["effort"]) ?? level(input["effort_level"]) ?? fallbackEffort
        return MaestroModel(name: name, effort: effort.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Where a project's model is noted: beside the usage, in the folder the
    /// window already watches, so the bar redraws when it changes.
    static func modelFile(for project: String, in directory: URL = Maestro.supportDirectory) -> URL {
        let name = Maestro.sessionFile(for: project, in: directory).lastPathComponent
        return directory.appendingPathComponent("model-" + name)
    }

    static func model(for project: String, in directory: URL = Maestro.supportDirectory) -> MaestroModel? {
        (try? Data(contentsOf: modelFile(for: project, in: directory)))
            .flatMap { try? JSONDecoder().decode(MaestroModel.self, from: $0) }
    }

    /// Notes the model, only when it changed: the status line runs many times
    /// a minute, and every write here redraws the window.
    static func note(_ model: MaestroModel, for project: String, in directory: URL = Maestro.supportDirectory) {
        guard self.model(for: project, in: directory) != model else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(model).write(to: modelFile(for: project, in: directory), options: .atomic)
    }

    private static var settingsEffort: String? {
        ((try? Data(contentsOf: userSettings))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["effortLevel"] as? String
    }

    static func save(_ usage: SubscriptionUsage, to url: URL = usageFile) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(usage).write(to: url, options: .atomic)
    }

    static func load(from url: URL = usageFile) -> SubscriptionUsage? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SubscriptionUsage.self, from: $0) }
    }

    static func label(_ usage: SubscriptionUsage?, now: Date) -> UsageLabel? {
        guard let usage, let week = usage.sevenDay, now.timeIntervalSince(usage.updated) < staleAfter else { return nil }
        let level: UsageLabel.Level = week >= hotFrom ? .hot : (week >= warmFrom ? .warm : .calm)
        return UsageLabel(text: "semana \(Int(week.rounded()))%", level: level)
    }

    /// The status line the user set up for themselves, to be run after ours.
    static func userStatusCommand(settings: URL = userSettings, ours: String) -> String? {
        guard let data = try? Data(contentsOf: settings),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = (root["statusLine"] as? [String: Any])?["command"] as? String,
              !command.isEmpty, command != ours
        else { return nil }
        return command
    }

    /// What `Vitra maestro-status` does: notes the usage, then hands the same
    /// input to the user's own status line and lets it print.
    static func run(input: Data, binary: String) {
        if let usage = usage(fromStatusInput: input, now: Date()) { save(usage) }
        let fields = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        let project = ProcessInfo.processInfo.environment["VITRA_PROJECT"]
            ?? (fields?["workspace"] as? [String: Any])?["project_dir"] as? String
            ?? fields?["cwd"] as? String
        if let project, let model = model(fromStatusInput: input, fallbackEffort: settingsEffort) {
            note(model, for: project)
        }
        guard let command = userStatusCommand(ours: command(binary: binary)) else { return }

        let process = Process()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = stdin
        guard (try? process.run()) != nil else { return }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}
