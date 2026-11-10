import AppKit
import Foundation
import Testing
@testable import VitraApp
@testable import VitraOrchestrator

private let start = Date(timeIntervalSince1970: 1_000_000)

private func run(
    _ id: String = "0123abcd",
    cli: WorkerCLI = .opencode,
    model: String = "opencode/deepseek-v4.1-flash-free",
    prompt: String = "Map the login flow.\nDetails follow.",
    directory: String = "/work/vitra",
    access: WorkerAccess = .read,
    label: String? = nil,
    state: Run.State = .running,
    seconds: TimeInterval = 38,
    output: WorkerOutput? = nil
) -> Run {
    Run(
        id: id,
        spec: WorkerSpec(cli: cli, model: model, prompt: prompt, directory: directory, access: access, label: label),
        state: state,
        pid: 4242,
        started: start,
        ended: state == .running ? nil : start.addingTimeInterval(seconds),
        output: output,
        errorTail: nil
    )
}

private let now = start.addingTimeInterval(38)

// A fixed offset, so the clock times in these tests do not depend on the machine.
private let zone = TimeZone(secondsFromGMT: -3 * 3600)!

/// A moment in `zone`, so a test can say when something happened in local time.
private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

// MARK: - Which runs belong to a project

@Test func aProjectShowsTheRunsInItsDirectoryAndBelowIt() {
    let project = CockpitProject(path: "/work/vitra")
    let runs = [
        run("aaaaaaaa", directory: "/work/vitra"),
        run("bbbbbbbb", directory: "/work/vitra/.claude/worktrees/fix-login"),
        run("cccccccc", directory: "/work/vitra-site"),
        run("dddddddd", directory: "/work"),
    ]
    #expect(WorkerBoard.runs(runs, in: project).map(\.id) == ["aaaaaaaa", "bbbbbbbb"])
}

@Test func aWorkerBelongsToTheProjectWhoseMaestroSpawnedItWhereverItRuns() {
    // A maestro often sends a worker to a git worktree kept somewhere else
    // entirely. It is still that project's worker, and that project's panel
    // is where the user looks for it.
    let project = CockpitProject(path: "/work/hapto")
    let elsewhere = Run(
        id: "aaaaaaaa",
        spec: WorkerSpec(cli: .claude, model: "sonnet", prompt: "x", directory: "/private/tmp/scratch/f3", effort: "high", project: "/work/hapto"),
        state: .running, pid: 1, started: start, ended: nil, output: nil, errorTail: nil
    )
    let another = Run(
        id: "bbbbbbbb",
        // Runs inside this project's folder, but another project's maestro sent it.
        spec: WorkerSpec(cli: .claude, model: "haiku", prompt: "x", directory: "/work/hapto/sub", effort: "low", project: "/work/site"),
        state: .running, pid: 1, started: start, ended: nil, output: nil, errorTail: nil
    )
    #expect(WorkerBoard.runs([elsewhere, another], in: project).map(\.id) == ["aaaaaaaa"])
    #expect(WorkerBoard.runs([elsewhere, another], in: CockpitProject(path: "/work/site")).map(\.id) == ["bbbbbbbb"])
}

@Test func aProjectIsNamedAfterItsFolder() {
    #expect(CockpitProject(path: "/Users/x/Dev/megalink-site").name == "megalink-site")
    #expect(CockpitProject(path: "/Users/x/Dev/megalink-site/").name == "megalink-site")
}

// MARK: - Rows

@Test func aRunningWorkerSaysWhatItMayDoInsteadOfWhatItCost() {
    let row = WorkerBoard.row(run(access: .edit, label: "Corrigir validação"), now: now)
    #expect(row.title == "Corrigir validação")
    #expect(row.kind == .running)
    #expect(row.stateText == "rodando")
    #expect(row.meta == "deepseek-v4.1-flash-free · 10:46 · 38s · edita")
    #expect(WorkerBoard.row(run(), now: now, timeZone: zone).meta == "deepseek-v4.1-flash-free · 10:46 · 38s · só leitura")
}

@Test func aWorkersEffortIsPartOfItsNameOnTheRow() {
    let spec = WorkerSpec(cli: .claude, model: "haiku", prompt: "x", directory: "/work/vitra", effort: "low")
    let haiku = Run(id: "0123abcd", spec: spec, state: .running, pid: 1, started: start, ended: nil, output: nil, errorTail: nil)
    #expect(WorkerBoard.row(haiku, now: now, timeZone: zone).meta == "haiku (low) · 10:46 · 38s · só leitura")
}

@Test func aWorkersStartShowsTheClockWhenItStartedToday() {
    #expect(WorkerBoard.startedText(at(2026, 11, 10, 10, 42), now: at(2026, 11, 10, 15, 0), timeZone: zone) == "10:42")
}

@Test func aWorkersStartShowsDayAndMonthWhenItStartedAnotherDayOfTheYear() {
    #expect(WorkerBoard.startedText(at(2026, 11, 9, 22, 54), now: at(2026, 11, 10, 15, 0), timeZone: zone) == "09/11 22:54")
}

@Test func aWorkersStartShowsTheYearWhenItStartedInAnotherYear() {
    #expect(WorkerBoard.startedText(at(2025, 11, 9, 22, 54), now: at(2026, 11, 10, 15, 0), timeZone: zone) == "09/11/2025 22:54")
}

@Test func aWorkerWithNoLabelIsTitledByTheFirstLineOfItsPrompt() {
    #expect(WorkerBoard.row(run(), now: now).title == "Map the login flow.")
    let long = String(repeating: "palavra ", count: 30)
    let title = WorkerBoard.row(run(prompt: long), now: now).title
    #expect(title.count == 60)
    #expect(title.hasSuffix("…"))
}

@Test func aFinishedWorkerShowsTimeCostAndTokens() {
    let output = WorkerOutput(text: "Done.\nSecond line.", isError: false, costUSD: 0.0234, inputTokens: 22_900, outputTokens: 186)
    let row = WorkerBoard.row(run(state: .finished(exitCode: 0), seconds: 4, output: output), now: now, timeZone: zone)
    #expect(row.kind == .done)
    #expect(row.stateText == "pronto")
    #expect(row.meta == "deepseek-v4.1-flash-free · 10:46 · 4s · $0.02 · 23k tokens")
    #expect(row.detail == "Done.\nSecond line.")
}

@Test func aRatedDeliveryShowsItsScoreBesideItsState() {
    let output = WorkerOutput(text: "Done.", isError: false)
    var rated = run(state: .finished(exitCode: 0), seconds: 4, output: output)
    rated.rating = Rating(score: 4, note: "left a TODO", rated: start)
    #expect(WorkerBoard.row(rated, now: now).stateText == "pronto · 4/5")
    #expect(WorkerBoard.row(run(state: .finished(exitCode: 0), seconds: 4, output: output), now: now).stateText == "pronto")

    // It ran and finished, but the maestro judged it not what was asked: on
    // the row that reads as a failure, which is what it was.
    rated.rating = Rating(score: 2, note: "wrong file", rated: start)
    let row = WorkerBoard.row(rated, now: now, timeZone: zone)
    #expect(row.stateText == "insatisfatório · 2/5")
    #expect(row.kind == .failed)
    #expect(row.meta == "deepseek-v4.1-flash-free · 10:46 · 4s · wrong file")
}

@Test func theRankingSaysForEachModelItsScoreItsTimeAndHowOftenItFails() {
    let scores = [
        ModelScore(kind: .explore, cli: .gemini, model: "gemini-3.8-flash", effort: nil, runs: 6, rated: 4, averageScore: 4.5, failures: 0, medianSeconds: 8, costUSD: 0.12),
        ModelScore(kind: .implement, cli: .opencode, model: "opencode/deepseek-v4.1-flash-free", effort: "high", runs: 1, rated: 0, averageScore: nil, failures: 1, medianSeconds: nil, costUSD: 0),
    ]
    #expect(WorkerBoard.ranking(scores) == [
        RankingRow(kind: "explorar", model: "gemini-3.8-flash", score: "4.5", time: "8s", deliveries: "6/6", cost: "$0.12", ratings: "4 avaliações"),
        RankingRow(kind: "implementar", model: "deepseek-v4.1-flash-free (high)", score: "—", time: "—", deliveries: "0/1", cost: "$0.00", ratings: "sem avaliação"),
    ])
}

@Test func aFailedWorkerShowsWhyOnItsMetaLine() {
    let output = WorkerOutput(text: "Failed to authenticate: OAuth session expired and could not be refreshed\nmore", isError: true)
    let failed = run(cli: .claude, model: "haiku", state: .finished(exitCode: 1), seconds: 2, output: output)
    let row = WorkerBoard.row(failed, now: now, timeZone: zone)
    #expect(row.kind == .failed)
    #expect(row.stateText == "falhou")
    // Cut at 68 characters: the row is one line wide.
    #expect(row.meta == "haiku · 10:46 · 2s · Failed to authenticate: OAuth session expired and could not be refr…")
}

@Test func cancelledAndLostWorkersAreNamedAsSuch() {
    #expect(WorkerBoard.row(run(state: .cancelled, seconds: 9), now: now).stateText == "cancelado")
    #expect(WorkerBoard.row(run(state: .cancelled, seconds: 9), now: now).kind == .stopped)
    #expect(WorkerBoard.row(run(state: .lost), now: now).stateText == "perdido")
    #expect(WorkerBoard.row(run(state: .lost), now: now).kind == .failed)
}

@Test func durationsAndTokenCountsAreShortEnoughToScan() {
    #expect(WorkerBoard.duration(4.4) == "4s")
    #expect(WorkerBoard.duration(125) == "2m 05s")
    #expect(WorkerBoard.duration(3725) == "1h 02m")
    #expect(WorkerBoard.tokens(850) == "850 tokens")
    #expect(WorkerBoard.tokens(23_086) == "23k tokens")
    #expect(WorkerBoard.tokens(1_240_000) == "1.2M tokens")
    #expect(WorkerBoard.money(0) == "$0.00")
    #expect(WorkerBoard.money(0.416) == "$0.42")
}

// MARK: - Totals

@Test func theHeaderCountsWorkersByState() {
    let done = WorkerOutput(text: "ok", isError: false)
    let failed = WorkerOutput(text: "no", isError: true)
    let runs = [
        run("aaaaaaaa"), run("bbbbbbbb"),
        run("cccccccc", state: .finished(exitCode: 0), output: done),
        run("dddddddd", state: .finished(exitCode: 1), output: failed),
    ]
    #expect(WorkerBoard.summary(runs, now: now) == "2 rodando · 1 pronto · 1 falhou")
    #expect(WorkerBoard.summary([run("cccccccc", state: .finished(exitCode: 0), output: done)], now: now) == "1 pronto")
    #expect(WorkerBoard.summary([], now: now) == "nenhum ainda")
    #expect(WorkerBoard.runningCount(runs) == 2)
}

@Test func costIsSummedOnlyFromTheGivenMoment() {
    let old = Run(
        id: "eeeeeeee",
        spec: WorkerSpec(cli: .claude, model: "haiku", prompt: "x", directory: "/work/vitra"),
        state: .finished(exitCode: 0), pid: 1,
        started: start.addingTimeInterval(-90_000), ended: start.addingTimeInterval(-89_000),
        output: WorkerOutput(text: "", isError: false, costUSD: 5, inputTokens: 1000, outputTokens: 0),
        errorTail: nil
    )
    let today = run(state: .finished(exitCode: 0), output: WorkerOutput(text: "", isError: false, costUSD: 0.25, inputTokens: 50_000, outputTokens: 8_000))
    let totals = WorkerBoard.totals([old, today, run("ffffffff")], since: start.addingTimeInterval(-3600))
    #expect(totals.cost == 0.25)
    #expect(totals.tokens == 58_000)
}

// MARK: - What is remembered between launches

@Test func theCockpitReopensWithTheSameTabsTheSameOneInFrontAndEachMaestrosConversation() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(CockpitState.load(from: file) == CockpitState())

    var state = CockpitState()
    state.projects = CockpitProjects.adding("/work/vitra", to: state.projects)
    state.projects = CockpitProjects.adding("/work/site/", to: state.projects)
    state.projects = CockpitProjects.adding("/work/vitra/", to: state.projects)
    #expect(state.projects.map(\.path) == ["/work/vitra", "/work/site"])

    state.projects[1].session = "0f3c1a52-9d2e-4b7a-8c11-5e6f7a8b9c0d"
    state.selected = 1
    try state.save(to: file)

    let reopened = CockpitState.load(from: file)
    #expect(reopened == state)
    #expect(reopened.selected == 1)
    #expect(reopened.projects[1].session == "0f3c1a52-9d2e-4b7a-8c11-5e6f7a8b9c0d")
    // Adding a project that is already open keeps what is known about it.
    #expect(CockpitProjects.adding("/work/site", to: reopened.projects) == reopened.projects)
}

@Test func aListSavedByAnEarlierVersionStillOpens() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    // The first cockpit wrote a bare array of paths.
    try #"[{"path":"/work/vitra"},{"path":"/work/site"}]"#.write(to: file, atomically: true, encoding: .utf8)

    let state = CockpitState.load(from: file)
    #expect(state.projects.map(\.path) == ["/work/vitra", "/work/site"])
    #expect(state.selected == 0)
    #expect(state.projects.allSatisfy { $0.session == nil })
}

@Test func aDamagedStateCostsTheTabsNeverTheLaunch() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try "not json".write(to: file, atomically: true, encoding: .utf8)
    #expect(CockpitState.load(from: file) == CockpitState())

    // A tab index pointing past the tabs, and a session that is not an id:
    // the one is brought back in range, the other is forgotten. The session
    // ends up on a command line and must be nothing but a UUID.
    try #"{"projects":[{"path":"/work/vitra","session":"x; rm -rf ~"}],"selected":7}"#
        .write(to: file, atomically: true, encoding: .utf8)
    let state = CockpitState.load(from: file)
    #expect(state.selected == 0)
    #expect(state.projects == [CockpitProject(path: "/work/vitra")])
}

// MARK: - The maestro

@Test func aMaestroWithAConversationOnDiskResumesItAndOneWithoutStartsItUnderThatId() throws {
    let conversations = FileManager.default.temporaryDirectory.appendingPathComponent("claude-projects-\(UUID().uuidString)")
    let project = conversations.appendingPathComponent("-work-vitra")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: conversations) }
    let talked = "0f3c1a52-9d2e-4b7a-8c11-5e6f7a8b9c0d"
    let silent = "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    try "{}".write(to: project.appendingPathComponent(talked + ".jsonl"), atomically: true, encoding: .utf8)

    // Resuming an id claude never wrote down is an error at its prompt, so the
    // id is only resumed once there is a conversation behind it.
    #expect(Maestro.conversation(talked, in: conversations) == .resume(talked))
    #expect(Maestro.conversation(silent, in: conversations) == .new(silent))
    #expect(Maestro.conversation(silent, in: conversations.appendingPathComponent("missing")) == .new(silent))
}

@Test func theMaestrosMCPConfigCarriesItsRole() throws {
    // Without the role the helper serves a worker's tool set to the maestro.
    let config = try #require(try JSONSerialization.jsonObject(with: Data(Maestro.mcpConfig(binary: "/Apps/Vitra").utf8)) as? [String: Any])
    let vitra = try #require((config["mcpServers"] as? [String: Any])?["vitra"] as? [String: Any])

    #expect(vitra["command"] as? String == "/Apps/Vitra")
    #expect((vitra["env"] as? [String: String])?["VITRA_ROLE"] == "maestro")
}

@Test func theMaestroIsBriefedOnTheSharedNotes() {
    // Workers are shown the notes automatically; the maestro must know to add to them.
    #expect(Maestro.brief.contains("memory_add"))
    #expect(Maestro.brief.contains("shared notes"))
}

@Test func theMaestroIsLaunchedWithVitrasToolsItsBriefAndItsConversation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maestro \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let binary = "/Apps/My Vitra.app/Contents/MacOS/Vitra"
    let id = "0f3c1a52-9d2e-4b7a-8c11-5e6f7a8b9c0d"
    let files = "--mcp-config '\(directory.path)/mcp.json' --settings '\(directory.path)/settings.json' --append-system-prompt-file '\(directory.path)/brief.md'\n"

    // Short enough to read: the JSON and the brief are in files, not typed out.
    let fresh = try Maestro.install(binary: binary, claude: "claude --model opus", conversation: .new(id), in: directory)
    #expect(fresh == "claude --model opus --session-id '\(id)' " + files)
    let resumed = try Maestro.install(binary: binary, claude: "claude --model opus", conversation: .resume(id), in: directory)
    #expect(resumed == "claude --model opus --resume '\(id)' " + files)

    // The config names this very binary, spaces in its path and all.
    let config = try Data(contentsOf: directory.appendingPathComponent("mcp.json"))
    let parsed = try #require(try JSONSerialization.jsonObject(with: config) as? [String: [String: [String: Any]]])
    #expect(parsed["mcpServers"]?["vitra"]?["command"] as? String == binary)
    #expect(parsed["mcpServers"]?["vitra"]?["args"] as? [String] == ["mcp"])

    let brief = try String(contentsOf: directory.appendingPathComponent("brief.md"), encoding: .utf8)
    // Delegation is the rule, with the exceptions named rather than left to
    // the maestro's sense of what counts as small.
    #expect(brief.contains("Delegate by default"))
    // Vitra picks the worker; the maestro tags the kind and passes commands.
    #expect(brief.contains("Vitra picks the worker from the record"))
    #expect(brief.contains("two deliveries"))
    #expect(brief.contains("commands"))
    #expect(!brief.contains("override"))
    #expect(!brief.contains("call agent_scores"))
    // A deploy is mostly waiting, and may be handed to a worker and rated;
    // what cannot be undone in production stays with the maestro.
    #expect(brief.contains("A deploy is a worker's job too"))
    #expect(brief.contains("undone in production"))
    #expect(brief.contains("just answer it"))
    // What a failure is, and what to do about each kind of it.
    #expect(brief.contains("did not do what was asked"))
    #expect(brief.contains("another provider"))
    // The audit gate: another provider reads the change first, and the
    // maestro's own review starts from its verdict.
    #expect(brief.contains("audited first"))
    #expect(brief.contains("rate the auditor"))
    #expect(brief.contains("agent_spawn"))
    #expect(brief.contains("agent_wait"))

    // The maestro is never reachable from outside this machine, whatever the
    // user's own Claude settings say about other sessions.
    let settings = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("settings.json"))) as? [String: Any]
    )
    #expect(settings["remoteControlAtStartup"] as? Bool == false)
    // The maestro's status line goes through Vitra, which reads the usage
    // figures off it on the way to the user's own.
    #expect(settings["statusLine"] as? [String: String] == [
        "type": "command",
        "command": "'/Apps/My Vitra.app/Contents/MacOS/Vitra' maestro-status",
    ])

    // And claude tells Vitra, through this very binary, which conversation the
    // maestro is in every time that changes.
    let hooks = try #require(settings["hooks"] as? [String: [[String: [[String: String]]]]])
    #expect(hooks["SessionStart"]?.first?["hooks"]?.first == [
        "type": "command",
        "command": "'/Apps/My Vitra.app/Contents/MacOS/Vitra' maestro-session",
    ])
}

@Test func theCockpitFollowsTheConversationTheMaestroIsActuallyIn() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let started = "0f3c1a52-9d2e-4b7a-8c11-5e6f7a8b9c0d"
    let resumed = "32f5150d-53d4-4a1c-93ad-bc218b3e0a29"
    let hook = { (session: String, cwd: String) in
        Data(#"{"session_id":"\#(session)","cwd":"\#(cwd)","hook_event_name":"SessionStart","source":"resume"}"#.utf8)
    }

    #expect(Maestro.rememberedSession(for: "/work/hapto", in: directory) == nil)

    // The maestro starts under the id the cockpit gave it…
    Maestro.recordSession(hookInput: hook(started, "/work/hapto"), project: "/work/hapto", in: directory)
    #expect(Maestro.rememberedSession(for: "/work/hapto", in: directory) == started)

    // …and then the user picks another conversation with /resume. That one is
    // where they are, and that one is what reopening must bring back.
    Maestro.recordSession(hookInput: hook(resumed, "/work/hapto"), project: "/work/hapto", in: directory)
    #expect(Maestro.rememberedSession(for: "/work/hapto", in: directory) == resumed)

    // Each project keeps its own.
    #expect(Maestro.rememberedSession(for: "/work/site", in: directory) == nil)
    // With no project named, the folder claude is in stands for it.
    Maestro.recordSession(hookInput: hook(started, "/work/site"), project: nil, in: directory)
    #expect(Maestro.rememberedSession(for: "/work/site", in: directory) == started)

    // Nothing that is not exactly a session id is ever remembered: it ends up
    // on a command line.
    Maestro.recordSession(hookInput: hook("x; rm -rf ~", "/work/hapto"), project: "/work/hapto", in: directory)
    Maestro.recordSession(hookInput: Data("not json".utf8), project: "/work/hapto", in: directory)
    Maestro.recordSession(hookInput: Data(), project: "/work/hapto", in: directory)
    #expect(Maestro.rememberedSession(for: "/work/hapto", in: directory) == resumed)
}

// MARK: - The ranking and the side tabs

@Test @MainActor func theRankingLaysOutASectionPerKindAndSaysSoWhenThereIsNothingYet() throws {
    _ = NSApplication.shared
    let rows = [
        RankingRow(kind: "explorar", model: "deepseek-v4.1-flash-free", score: "5.0", time: "4s", deliveries: "1/1", cost: "$0.00", ratings: "1 avaliação"),
        RankingRow(kind: "explorar", model: "gemini-3.5-flash", score: "4.0", time: "13s", deliveries: "1/1", cost: "$0.00", ratings: "1 avaliação"),
        RankingRow(kind: "implementar", model: "haiku", score: "—", time: "—", deliveries: "0/2", cost: "$0.00", ratings: "sem avaliação"),
    ]
    func texts(_ view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
    }
    let view = RankingView()
    view.show(rows)
    // A heading per kind, and under it each worker with its place in that
    // kind, its name and four captioned figures.
    let captions = ["nota", "tempo", "entregas", "custo"]
    func card(_ place: String, _ row: RankingRow) -> [String] {
        [place, row.model, row.ratings] + zip([row.score, row.time, row.deliveries, row.cost], captions).flatMap { [$0, $1] }
    }
    #expect(texts(view) == ["EXPLORAR"] + card("1", rows[0]) + card("2", rows[1]) + ["IMPLEMENTAR"] + card("1", rows[2]))
    // Shown again, it is replaced, not added to.
    view.show([])
    #expect(texts(view).first == "Ainda não há entregas para comparar")
    #expect(texts(view).count == 2)
}

@Test @MainActor func theTabsOfTheSideAreNamedAndOnlyAPageOrAFileTakesHalfTheWindow() {
    #expect(SideTab.allCases.map(\.title) == ["Workers", "Ranking", "Navegador", "Arquivos", "Git", "Terminal"])
    #expect(SideTab.allCases.filter(\.isWide) == [.browser, .files, .terminal])
    _ = NSApplication.shared
    let tabs = SideTabs()
    var chosen: [SideTab] = []
    tabs.onSelect = { chosen.append($0) }
    tabs.select(.git)
    #expect(tabs.selected == .git)
    // Selecting from code is not a click: nothing is reported back.
    #expect(chosen.isEmpty)
}

// MARK: - Subscription usage

@Test func theWeeklyUsageIsReadFromWhatClaudeHandsItsStatusLine() throws {
    let input = Data(#"""
    {"session_id":"x","model":{"display_name":"Fable 5.2"},
     "rate_limits":{"five_hour":{"used_percentage":12.4,"resets_at":1794300000},"seven_day":{"used_percentage":43.6,"resets_at":1794800000}}}
    """#.utf8)
    let usage = try #require(MaestroStatus.usage(fromStatusInput: input, now: start))
    #expect(usage.sevenDay == 43.6)
    #expect(usage.fiveHour == 12.4)
    #expect(usage.updated == start)

    // Before the first reply of a session claude has no limits to report, and
    // a status with none must not wipe the figure already on screen.
    #expect(MaestroStatus.usage(fromStatusInput: Data(#"{"session_id":"x"}"#.utf8), now: start) == nil)
    #expect(MaestroStatus.usage(fromStatusInput: Data("not json".utf8), now: start) == nil)
}

@Test func theUsageSurvivesBetweenTheStatusLineAndTheApp() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(MaestroStatus.load(from: file) == nil)

    let usage = SubscriptionUsage(sevenDay: 43.6, fiveHour: 12.4, updated: start)
    MaestroStatus.save(usage, to: file)
    #expect(MaestroStatus.load(from: file) == usage)
}

@Test func theBarShowsTheWeekRoundedAndWarnsAsItFills() {
    let at = { (week: Double?) in SubscriptionUsage(sevenDay: week, fiveHour: nil, updated: start) }
    #expect(MaestroStatus.label(at(43.6), now: start) == UsageLabel(text: "semana 44%", level: .calm))
    #expect(MaestroStatus.label(at(75), now: start) == UsageLabel(text: "semana 75%", level: .warm))
    #expect(MaestroStatus.label(at(92.2), now: start) == UsageLabel(text: "semana 92%", level: .hot))
    #expect(MaestroStatus.label(at(nil), now: start) == nil)
    #expect(MaestroStatus.label(nil, now: start) == nil)
    // A figure from days ago is not the week's usage any more; better none.
    #expect(MaestroStatus.label(at(43.6), now: start.addingTimeInterval(49 * 3600)) == nil)
}

@Test func theUsersOwnStatusLineStillRunsAndTheMaestrosNeverCallsItself() throws {
    let settings = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: settings) }
    let ours = "'/Apps/Vitra.app/Contents/MacOS/Vitra' maestro-status"

    #expect(MaestroStatus.userStatusCommand(settings: settings, ours: ours) == nil)

    try #"{"statusLine":{"type":"command","command":"bash \"/x/caveman-statusline.sh\""}}"#
        .write(to: settings, atomically: true, encoding: .utf8)
    #expect(MaestroStatus.userStatusCommand(settings: settings, ours: ours) == #"bash "/x/caveman-statusline.sh""#)

    // Should the user's settings ever name the maestro's own command, running
    // it from itself would never end.
    try #"{"statusLine":{"type":"command","command":"'/Apps/Vitra.app/Contents/MacOS/Vitra' maestro-status"}}"#
        .write(to: settings, atomically: true, encoding: .utf8)
    #expect(MaestroStatus.userStatusCommand(settings: settings, ours: ours) == nil)
}

@Test @MainActor func quittingTakesAHeldKeyNotATap() {
    let began = Date(timeIntervalSince1970: 100)
    #expect(!QuitHold.isLongEnough(from: began, to: began.addingTimeInterval(0.2)))
    #expect(QuitHold.isLongEnough(from: began, to: began.addingTimeInterval(QuitHold.holdFor)))
}

@Test func theMaestrosModelAndEffortAreReadFromItsStatusLineAndKeptPerProject() throws {
    let input = Data(#"{"model":{"id":"claude-fable-5-2","display_name":"Fable 5.2"},"cwd":"/work/hapto"}"#.utf8)
    // The effort is not always in what claude sends; the user's setting stands in.
    #expect(MaestroStatus.model(fromStatusInput: input, fallbackEffort: "high") == MaestroModel(name: "Fable 5.2", effort: "high"))
    let withEffort = Data(#"{"model":{"display_name":"Opus 5.5"},"effort":{"level":"xhigh"}}"#.utf8)
    #expect(MaestroStatus.model(fromStatusInput: withEffort, fallbackEffort: "high") == MaestroModel(name: "Opus 5.5", effort: "xhigh"))
    #expect(MaestroStatus.model(fromStatusInput: Data("{}".utf8), fallbackEffort: "high") == nil)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    MaestroStatus.note(MaestroModel(name: "Fable 5.2", effort: "high"), for: "/work/hapto", in: directory)
    #expect(MaestroStatus.model(for: "/work/hapto", in: directory) == MaestroModel(name: "Fable 5.2", effort: "high"))
    #expect(MaestroStatus.model(for: "/work/site", in: directory) == nil)
}

@Test func aSessionsNameIsTheLastCustomTitleElseTheGeneratedOne() {
    let custom = #"{"type":"custom-title","customTitle":"revisão do PR 61","sessionId":"s1"}"#
    let generated = #"{"type":"agent-name","agentName":"quero revisar o PR","sessionId":"s1"}"#
    let message = #"{"type":"assistant","message":{"content":"olá"}}"#

    #expect(SessionName.name(inTail: Data(generated.utf8)) == "quero revisar o PR")
    #expect(SessionName.name(inTail: Data(custom.utf8)) == "revisão do PR 61")
    // Both present: the custom title wins whichever comes last.
    #expect(SessionName.name(inTail: Data([generated, message, custom].joined(separator: "\n").utf8)) == "revisão do PR 61")
    #expect(SessionName.name(inTail: Data([custom, generated].joined(separator: "\n").utf8)) == "revisão do PR 61")
    #expect(SessionName.name(inTail: Data(message.utf8)) == nil)
    #expect(SessionName.name(inTail: Data()) == nil)
}

@Test func aPartialFirstLineOfTheTailIsSkipped() {
    let custom = #"{"type":"custom-title","customTitle":"revisão do PR 61","sessionId":"s1"}"#
    // The tail was cut mid-line: the fragment is not JSON and must not be read.
    let cut = #"{"type":"agent-name","agentName":"quero rev"#
    let tail = [cut, #"{"type":"assistant"}"#, custom].joined(separator: "\n")
    #expect(SessionName.name(inTail: Data(tail.utf8)) == "revisão do PR 61")
    #expect(SessionName.name(inTail: Data(cut.utf8)) == nil)
}

@Test func aSessionsNameIsReadFromTheTranscriptFile() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    let filler = String(repeating: #"{"type":"assistant","message":"xxxxxxxxxxxxxxxxxxxxxxxx"}"# + "\n", count: 20_000)
    let text = #"{"type":"agent-name","agentName":"antigo"}"# + "\n" + filler
    try text.write(to: file, atomically: true, encoding: .utf8)
    // The generated name is far back, past the tail: nothing is found.
    #expect(SessionName.named(atTranscript: file.path) == nil)
    let input = Data(#"{"model":{"display_name":"Fable 5.2"},"transcript_path":"\#(file.path)"}"#.utf8)
    #expect(MaestroStatus.model(fromStatusInput: input, fallbackEffort: nil)?.session == nil)
    try (text + #"{"type":"custom-title","customTitle":"PR 61"}"#).write(to: file, atomically: true, encoding: .utf8)
    #expect(MaestroStatus.model(fromStatusInput: input, fallbackEffort: nil)?.session == "PR 61")
}

@Test func aModelNotedBeforeSessionsExistedStillDecodes() throws {
    let old = Data(#"{"name":"Fable 5.2","effort":"high"}"#.utf8)
    #expect(try JSONDecoder().decode(MaestroModel.self, from: old) == MaestroModel(name: "Fable 5.2", effort: "high"))
    #expect(try JSONDecoder().decode(MaestroModel.self, from: old).session == nil)
}
