import CryptoKit
import Foundation
import os
import VitraBridge
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

    /// Whether the maestro delegates to workers or works alone.
    var mode: MaestroMode

    /// The side panel put away (⌘⇧\), the maestro given the whole window.
    /// Kept per project: one is watched, another only talked to.
    var sidePanelHidden: Bool

    init(path: String, session: String? = nil, mode: MaestroMode = .orchestrator, sidePanelHidden: Bool = false) {
        // One spelling per directory, so a trailing slash never makes a
        // second tab for the same place.
        self.path = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        self.session = session
        self.mode = mode
        self.sidePanelHidden = sidePanelHidden
    }

    private enum CodingKeys: String, CodingKey { case path, session, mode, sidePanelHidden }

    /// Files saved before the mode existed, or with one this build does not
    /// know, open in the orchestrator mode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try container.decode(String.self, forKey: .path),
            session: try container.decodeIfPresent(String.self, forKey: .session),
            mode: (try? container.decodeIfPresent(MaestroMode.self, forKey: .mode)) ?? .orchestrator,
            sidePanelHidden: (try? container.decodeIfPresent(Bool.self, forKey: .sidePanelHidden)) ?? false
        )
    }

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// How a project's maestro works: handing pieces to workers, or alone.
enum MaestroMode: String, Codable, Equatable {
    case orchestrator
    case solo

    /// The header's title for the mode.
    var title: String { self == .solo ? "Solo" : "Maestro" }
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
            return isUUID ? project : CockpitProject(path: project.path, mode: project.mode, sidePanelHidden: project.sidePanelHidden)
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

    /// When a run started: the clock time if it started on the day of `now`,
    /// day and month if it was another day, and the year too if it was
    /// another year. "Today" is judged in `timeZone`, the same zone the clock
    /// is read in, so a run started just before midnight stays on its own day.
    static func startedText(_ started: Date, now: Date, timeZone: TimeZone = .current) -> String {
        clocks.withLockUnchecked { $0.text(started, now: now, timeZone: timeZone) }
    }

    /// One calendar and one formatter per zone and format, kept for the life
    /// of the app: every row of every refresh asks for one, and building a
    /// `DateFormatter` costs far more than using it. Behind a lock because a
    /// formatter is not safe to share between threads.
    private static let clocks = OSAllocatedUnfairLock(uncheckedState: Clocks())

    private struct Clocks {
        private var calendars: [String: Calendar] = [:]
        private var formatters: [String: DateFormatter] = [:]

        mutating func text(_ started: Date, now: Date, timeZone: TimeZone) -> String {
            let calendar = calendars[timeZone.identifier] ?? {
                var made = Calendar(identifier: .gregorian)
                made.timeZone = timeZone
                calendars[timeZone.identifier] = made
                return made
            }()
            let format: String
            if calendar.isDate(started, inSameDayAs: now) {
                format = "HH:mm"
            } else if calendar.component(.year, from: started) == calendar.component(.year, from: now) {
                format = "dd/MM HH:mm"
            } else {
                format = "dd/MM/yyyy HH:mm"
            }
            let key = timeZone.identifier + "|" + format
            let formatter = formatters[key] ?? {
                let made = DateFormatter()
                // POSIX digits regardless of the machine's language or calendar settings.
                made.locale = Locale(identifier: "en_US_POSIX")
                made.calendar = calendar
                made.timeZone = timeZone
                made.dateFormat = format
                formatters[key] = made
                return made
            }()
            return formatter.string(from: started)
        }
    }

    static func row(_ run: Run, now: Date, timeZone: TimeZone = .current) -> WorkerRow {
        let model = shortName(run.spec.model, effort: run.spec.effort)
        let started = startedText(run.started, now: now, timeZone: timeZone)
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
            meta: ([model, started, elapsed, tail, chooser(run)].compactMap { $0 }).joined(separator: " · "),
            detail: run.output?.text
        )
    }

    /// Who chose the worker and why, as few words: `Vitra · 1º da sua
    /// escalação`, `Vitra · opus sem cota`. Nil for a worker named by hand.
    static func chooser(_ run: Run) -> String? {
        guard run.wasPicked else { return nil }
        guard let pick = run.pick else { return "Vitra" }
        let why: String
        switch pick.code {
        case .learning: why = "vez de teste"
        case .record: why = "fora da escalação, pelo histórico"
        case .cheapest: why = "fora da escalação, o mais barato"
        case .lineup:
            if let passed = pick.passed, let cause = pick.cause {
                let causes: [PickReason.Cause: String] = [
                    .quota: "sem cota", .signedOut: "sem login", .down: "fora do ar", .resting: "em pausa",
                    .demoted: "rebaixado", .slow: "lento", .unavailable: "indisponível",
                ]
                why = "\(passed) \(causes[cause] ?? "indisponível")"
            } else {
                why = "\(pick.position ?? 1)º da sua escalação"
            }
        }
        return (run.retryOf == nil ? "Vitra · " : "Vitra, após falha · ") + why
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
    static func shortName(_ model: String, effort: String?) -> String {
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

    static func firstLine(_ text: String) -> String {
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
    Workers do the work: you reach them with the vitra agent_spawn tool, \
    collect what they deliver with agent_wait, and review every delivery before you report.

    Delegate what is big or can run in parallel: a change that spans several files or more than about thirty \
    lines, an investigation that takes more than a handful of reads or commands, and anything that splits into \
    self-contained pieces. Starting a worker costs minutes — it reads the project from nothing — so that is only \
    worth it when the piece is bigger than the start.

    Do the small things yourself, at once: a change to one or two files of up to about thirty lines, a fix you \
    can already see, a quick question you can answer from what you already know or from a glance at a file — just \
    answer it. Keep for yourself too: planning and decisions; the final review; and what cannot be undone in \
    production — deleting or rewriting production data, changing credentials.

    A deploy is a worker's job too, of kind deploy, once you have reviewed what is being shipped. Watching a build \
    and reading logs is waiting, and waiting in your context is the most expensive kind. Give the worker the \
    project's exact procedure and the commands it needs (an ssh to the one host, the deploy script), and require \
    proof in its report: what it ran, the health check, the log lines that show the new version up. Rate it on \
    whether it followed the procedure, watched the deploy through to the end instead of assuming, said plainly when \
    something failed, and how long it took. The best and fastest becomes the one who deploys.

    Tag every agent_spawn with its kind of task, how hard it is (difficulty: easy, normal or hard) and the commands \
    the piece needs. That is all you say about who does it: Vitra picks the worker from the user's lineup for that \
    difficulty and the record, and the result says who and why. After reviewing a delivery, always record your verdict with agent_rate, honestly; a poor delivery rated \
    well sends the next task to the wrong worker.

    A delivery that changed forty lines or more is audited by a cheap read-only worker from another provider: \
    agent_wait starts that audit and gives its id. The audit is specialised by what the change touches, and a \
    change to security, data or concurrency gets a strong auditor. Do not sit waiting for it: read the change yourself while the \
    auditor reads, then take its verdict and check the places it points at; rate the auditor too. A smaller change \
    has no audit, and your own read is the review. When the verdict asks for fixes, send them back to the \
    implementer before you report.

    Once you accept the work — and the audit, when there is one, is read —, take it with agent_merge: it merges the worker's branch into \
    the checkout and removes its worktree and branch. If you are dropping the work instead, call agent_merge with \
    discard. A merge that conflicts is aborted and names the files, with the worktree and branch left in place: \
    send the work back to the implementer to resolve them, then merge again.

    The project has a shared terminal, in Vitra's Terminal tab, that the user types in too. terminal_read shows \
    what is on it: read it when the user refers to something they ran or saw there. terminal_run types a command \
    into it, for what the user should watch or keep using afterwards — a dev server, a long build, a log being \
    followed; for everything else use your own shell. Workers can read it and cannot type in it.

    The project has shared notes that every worker is shown automatically when it starts, so you do not need to \
    explain the project again in each prompt. When a delivery reveals something durable — how to build or test, a \
    trap that was hit, where something lives — add it with memory_add rather than repeating it in every prompt.

    Let workers check their own work, narrowly. Pass the test command in the worker's commands and tell it to run \
    only the tests of what it touched, not the whole suite; run the whole suite once yourself, after the merge.

    A worker fails in one of two ways, and each has its answer.

    It did not run: it crashed, timed out, or its CLI was signed out or its API down. Nothing was delivered, so there \
    is nothing to rate. Spawn the piece again; Vitra passes over a worker that keeps failing. A provider that is out of \
    quota is retried on another by Vitra, so there is nothing to do about it.

    It ran but did not do what was asked: the result is wrong, incomplete, or needed real fixes from you. That is a \
    failure too, and the more important one. Rate it for what it is — below 4 — and say why in the note. You may give \
    the same worker one more try. A delivery that needs fixes goes back with agent_redo and notes rather than a new \
    prompt from scratch. If it falls short a second time, rate it below 3 and redo it again: Vitra then gives it to \
    another worker. If the piece is harder than you said, spawn it again as hard.
    """

    /// The MCP configuration that gives the maestro Vitra's tools, as JSON.
    ///
    /// Passed on the command line rather than written into the user's own
    /// Claude settings: the tools exist for sessions the cockpit starts, and
    /// nothing is left behind in a file the user did not ask to have changed.
    /// The role in its environment is what gives the helper the maestro's tools.
    /// In solo mode the role says so, and the helper serves no agent tools.
    static func mcpConfig(binary: String, mode: MaestroMode = .orchestrator) -> String {
        let environment = mode == .solo
            ? [VitraMCPConfig.roleKey: StdioBridge.soloRole]
            : VitraMCPConfig.maestroEnvironment()
        return VitraMCPConfig.claudeConfig(binary: binary, environment: environment)
    }

    /// What the maestro is told in solo mode, instead of the brief.
    static let soloBrief = """
    You work alone in this session: do the work yourself. Vitra's browser, terminal, screen and memory tools are available.
    """

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
        mode: MaestroMode = .orchestrator,
        prompt: String? = nil,
        in directory: URL
    ) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Separate files per mode: the folder is shared by every project, and
        // one project's solo launch must not rewrite another's orchestrator files.
        let isSolo = mode == .solo
        let config = directory.appendingPathComponent(isSolo ? "mcp-solo.json" : "mcp.json")
        let instructions = directory.appendingPathComponent(isSolo ? "solo.md" : "brief.md")
        let settings = directory.appendingPathComponent("settings.json")
        try Data(mcpConfig(binary: binary, mode: mode).utf8).write(to: config, options: .atomic)
        try Data((isSolo ? soloBrief : brief).utf8).write(to: instructions, options: .atomic)
        try Data(Self.settings(binary: binary).utf8).write(to: settings, options: .atomic)
        return launchLine(
            claude: claude,
            conversation: conversation,
            config: config.path,
            settings: settings.path,
            brief: instructions.path,
            prompt: prompt
        )
    }

    /// What a maestro that was cut off mid-turn is told when it comes back.
    static func resumePrompt(mode: MaestroMode) -> String {
        let base = "O Vitra foi reiniciado enquanto você trabalhava. Continue de onde parou, sem refazer o que já estava pronto."
        return mode == .solo
            ? base
            : base + " Se havia operários em andamento, confira cada um com agent_wait antes de delegar de novo."
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
    static func conversation(_ id: String, in directory: URL = conversationsDirectory, project: String? = nil) -> Conversation {
        let file = id + ".jsonl"
        // claude names a project's folder after its absolute path, with every
        // "/" and "." turned into "-". Looking there first is one stat; listing
        // every project under ~/.claude/projects is not.
        if let project {
            let encoded = project
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ".", with: "-")
            let direct = directory.appendingPathComponent(encoded).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: direct.path) {
                return .resume(id)
            }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let exists = folders.contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(file).path)
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
        // The attention hooks are added beside SessionStart, never over it.
        var hooks = AttentionHook.settingsHooks(binary: binary)
        hooks["SessionStart"] = [["hooks": [hook]]]
        let settings: [String: Any] = [
            "remoteControlAtStartup": false,
            "hooks": hooks,
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
        brief: String,
        prompt: String? = nil
    ) -> String {
        let pickUp: [String] = switch conversation {
        case let .new(id): ["--session-id", ShellQuote.quote(id)]
        case let .resume(id): ["--resume", ShellQuote.quote(id)]
        }
        // A first prompt only for a conversation carried on: it is what tells
        // a maestro cut off mid-turn to go on, and a new one has nothing to go on with.
        var first: [String] = []
        if let prompt, case .resume = conversation { first = [ShellQuote.quote(prompt)] }
        return ([claude] + pickUp + [
            "--mcp-config", ShellQuote.quote(config),
            "--settings", ShellQuote.quote(settings),
            "--append-system-prompt-file", ShellQuote.quote(brief),
        ] + first).joined(separator: " ") + "\n"
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
    /// The maestro's session name: the last `/rename` title, else claude's
    /// generated one. Optional, so files noted before it existed still decode.
    let session: String?

    init(name: String, effort: String?, session: String? = nil) {
        self.name = name
        self.effort = effort
        self.session = session
    }
}

/// The name of the session a transcript belongs to, as claude records it.
///
/// `/rename` appends `{"type":"custom-title","customTitle":...}`; claude's own
/// generated name is `{"type":"agent-name","agentName":...}`. The last custom
/// title wins, else the last generated name. Only the tail of the file is read,
/// since transcripts run to many megabytes and the status line runs often.
enum SessionName {
    static let tailBytes = 256 * 1024

    static func named(atTranscript path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let tail = try? handle.readToEnd()
        else { return nil }
        return name(inTail: tail)
    }

    /// The name in a transcript's tail. A line cut by the start of the tail is
    /// not JSON, so it is skipped like any other line that does not parse.
    static func name(inTail tail: Data) -> String? {
        let customMarker = Data(#""custom-title""#.utf8)
        let generatedMarker = Data(#""agent-name""#.utf8)
        var custom: String?
        var generated: String?
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            let isCustom = line.range(of: customMarker) != nil
            let isGenerated = line.range(of: generatedMarker) != nil
            guard isCustom || isGenerated,
                  let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else { continue }
            if isCustom, custom == nil, entry["type"] as? String == "custom-title",
               let title = entry["customTitle"] as? String, !title.isEmpty {
                custom = title
            }
            if isGenerated, generated == nil, entry["type"] as? String == "agent-name",
               let title = entry["agentName"] as? String, !title.isEmpty {
                generated = title
            }
            if custom != nil { break }
        }
        return custom ?? generated
    }
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
        let session = (input["transcript_path"] as? String).flatMap(SessionName.named(atTranscript:))
        return MaestroModel(name: name, effort: effort.flatMap { $0.isEmpty ? nil : $0 }, session: session)
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
