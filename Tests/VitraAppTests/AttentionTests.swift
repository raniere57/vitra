import Foundation
import Testing
import VitraOrchestrator
@testable import VitraApp

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let project = "/Users/x/Dev/vitra"

private func hook(_ event: String, type: String? = nil, message: String? = nil) -> Data {
    var json: [String: Any] = ["hook_event_name": event, "session_id": "s", "cwd": project]
    if let type { json["notification_type"] = type }
    if let message { json["message"] = message }
    return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
}

private func update(_ event: String, type: String? = nil, message: String? = nil, previous: AttentionRecord? = nil, now: Date = t0) -> AttentionUpdate {
    AttentionHook.update(event: event, input: hook(event, type: type, message: message), project: project, now: now, previous: previous)
}

// MARK: - Hook payload -> state

@Test func stopMeansWaiting() {
    #expect(update("Stop") == .write(AttentionRecord(state: .waiting, message: nil, since: t0, path: project)))
}

@Test func promptSubmitMeansWorking() {
    guard case let .write(record) = update("UserPromptSubmit") else { Issue.record("expected a write"); return }
    #expect(record.state == .working)
}

@Test func sessionEndRemovesTheState() {
    #expect(update("SessionEnd") == .remove)
}

@Test func permissionNotificationNeedsPermissionAndKeepsItsMessage() {
    let result = update("Notification", type: "permission_prompt", message: "Claude needs your permission to use Bash")
    #expect(result == .write(AttentionRecord(state: .needsPermission, message: "Claude needs your permission to use Bash", since: t0, path: project)))
}

@Test func idleNotificationMeansWaiting() {
    guard case let .write(record) = update("Notification", type: "idle_prompt", message: "Claude is waiting for your input") else {
        Issue.record("expected a write"); return
    }
    #expect(record.state == .waiting)
}

@Test func notificationWithoutATypeIsToldByItsWords() {
    guard case let .write(permission) = update("Notification", message: "Claude needs your permission to use Edit"),
          case let .write(idle) = update("Notification", message: "Claude is waiting for your input")
    else { Issue.record("expected writes"); return }
    #expect(permission.state == .needsPermission)
    #expect(idle.state == .waiting)
}

@Test func notificationOfAnotherKindAsksNothing() {
    #expect(update("Notification", type: "auth_success", message: "signed in") == .ignore)
}

@Test func unknownEventIsIgnored() {
    #expect(update("PreToolUse") == .ignore)
}

@Test func garbageInputStillMapsFromTheEventName() {
    let result = AttentionHook.update(event: "Stop", input: Data("not json".utf8), project: project, now: t0, previous: nil)
    #expect(result == .write(AttentionRecord(state: .waiting, message: nil, since: t0, path: project)))
}

@Test func repeatingAStateKeepsWhenItBeganAndItsMessage() {
    let first = AttentionRecord(state: .waiting, message: "was here", since: t0, path: project)
    let result = update("Notification", type: "idle_prompt", previous: first, now: t0.addingTimeInterval(60))
    #expect(result == .write(first))
}

@Test func changingStateRestartsTheClock() {
    let first = AttentionRecord(state: .waiting, message: nil, since: t0, path: project)
    let later = t0.addingTimeInterval(60)
    #expect(update("UserPromptSubmit", previous: first, now: later) == .write(AttentionRecord(state: .working, message: nil, since: later, path: project)))
}

@Test func longMessagesAreCut() {
    guard case let .write(record) = update("Notification", type: "permission_prompt", message: String(repeating: "x", count: 500)) else {
        Issue.record("expected a write"); return
    }
    #expect(record.message?.count == 200)
}

@Test func projectIsTheCockpitsOneWhenNamedElseTheWorkingFolder() {
    #expect(AttentionHook.project(input: hook("Stop"), environment: "/Users/x/other") == CockpitProject(path: "/Users/x/other").path)
    #expect(AttentionHook.project(input: hook("Stop"), environment: nil) == CockpitProject(path: project).path)
    #expect(AttentionHook.project(input: Data(), environment: "") == nil)
}

// MARK: - State file

@Test func recordSurvivesTheFile() throws {
    let record = AttentionRecord(state: .needsPermission, message: "pede", since: t0, path: project)
    let data = try #require(AttentionRecord.encode(record))
    #expect(AttentionRecord.decode(data) == record)
    #expect(AttentionRecord.decode(Data("nope".utf8)) == nil)
}

@Test func hookRunLeavesAFileTheAppReadsAndSessionEndTakesItAway() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-attention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    Attention.run(event: "Stop", input: hook("Stop"), environmentProject: nil, now: t0, in: directory)
    #expect(Attention.load(for: project, in: directory)?.state == .waiting)
    #expect(Attention.load(for: "/Users/x/another", in: directory) == nil)

    Attention.run(event: nil, input: hook("UserPromptSubmit"), environmentProject: nil, now: t0, in: directory)
    #expect(Attention.load(for: project, in: directory)?.state == .working)

    Attention.run(event: "SessionEnd", input: hook("SessionEnd"), environmentProject: nil, now: t0, in: directory)
    #expect(Attention.load(for: project, in: directory) == nil)
}

@Test func maestroSettingsHaveEveryHookAndStillTheStatusLine() throws {
    let json = Maestro.settings(binary: "/Apps/Vitra")
    let settings = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let hooks = try #require(settings["hooks"] as? [String: Any])
    #expect(Set(hooks.keys) == Set(["SessionStart"] + AttentionHook.events))
    let stop = try #require(((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
    #expect(stop["command"] as? String == "'/Apps/Vitra' hook Stop")
    #expect((settings["statusLine"] as? [String: Any])?["command"] as? String == "'/Apps/Vitra' maestro-status")
}

// MARK: - Policy

@Test func aTabCallsOnPermissionAtOnceAndOnWaitingAfterTheQuietPeriod() {
    let waiting = AttentionRecord(state: .waiting, message: nil, since: t0, path: project)
    let permission = AttentionRecord(state: .needsPermission, message: nil, since: t0, path: project)
    let working = AttentionRecord(state: .working, message: nil, since: t0, path: project)
    #expect(AttentionPolicy.isCalling(permission, now: t0))
    #expect(!AttentionPolicy.isCalling(waiting, now: t0.addingTimeInterval(2)))
    #expect(AttentionPolicy.isCalling(waiting, now: t0.addingTimeInterval(AttentionPolicy.quietPeriod)))
    #expect(!AttentionPolicy.isCalling(working, now: t0.addingTimeInterval(600)))
    #expect(!AttentionPolicy.isCalling(nil, now: t0))
    #expect(AttentionPolicy.untilCalling(waiting, now: t0.addingTimeInterval(2)) == 3)
    #expect(AttentionPolicy.untilCalling(waiting, now: t0.addingTimeInterval(9)) == nil)
}

@Test func labelNamesTheStateAndHowLong() {
    let waiting = AttentionRecord(state: .waiting, message: nil, since: t0, path: project)
    let permission = AttentionRecord(state: .needsPermission, message: nil, since: t0, path: project)
    #expect(AttentionPolicy.label(waiting, now: t0.addingTimeInterval(2)) == nil)
    #expect(AttentionPolicy.label(waiting, now: t0.addingTimeInterval(40)) == "aguardando você · agora")
    #expect(AttentionPolicy.label(permission, now: t0.addingTimeInterval(190)) == "pede permissão · 3 min")
    #expect(AttentionPolicy.elapsed(7_300) == "2 h")
    #expect(AttentionPolicy.body(waiting) == "O maestro terminou e aguarda você")
}

// MARK: - Notification throttle

@Test func alertsOnTheTransitionIntoWaitingOnce() {
    let throttle = AttentionThrottle()
    #expect(!throttle.shouldAlert(project: "a", state: .working, now: t0, isWatching: false))
    #expect(throttle.shouldAlert(project: "a", state: .waiting, now: t0, isWatching: false))
    #expect(!throttle.shouldAlert(project: "a", state: .waiting, now: t0.addingTimeInterval(1), isWatching: false))
}

@Test func neverAlertsWhileTheUserIsTypingThere() {
    let throttle = AttentionThrottle()
    #expect(!throttle.shouldAlert(project: "a", state: .waiting, now: t0, isWatching: true))
    #expect(!throttle.shouldAlert(project: "a", state: .waiting, now: t0.addingTimeInterval(60), isWatching: false))
}

@Test func atMostOneAlertPerProjectEveryThirtySeconds() {
    let throttle = AttentionThrottle()
    #expect(throttle.shouldAlert(project: "a", state: .waiting, now: t0, isWatching: false))
    _ = throttle.shouldAlert(project: "a", state: .working, now: t0.addingTimeInterval(5), isWatching: false)
    #expect(!throttle.shouldAlert(project: "a", state: .waiting, now: t0.addingTimeInterval(10), isWatching: false))
    _ = throttle.shouldAlert(project: "a", state: .working, now: t0.addingTimeInterval(20), isWatching: false)
    #expect(throttle.shouldAlert(project: "a", state: .waiting, now: t0.addingTimeInterval(31), isWatching: false))
    // Another project has its own allowance.
    #expect(throttle.shouldAlert(project: "b", state: .needsPermission, now: t0.addingTimeInterval(32), isWatching: false))
}

@Test func permissionAfterWaitingAlertsButWaitingAfterPermissionDoesNot() {
    let throttle = AttentionThrottle()
    #expect(throttle.shouldAlert(project: "a", state: .waiting, now: t0, isWatching: false))
    #expect(throttle.shouldAlert(project: "a", state: .needsPermission, now: t0.addingTimeInterval(40), isWatching: false))
    #expect(!throttle.shouldAlert(project: "a", state: .waiting, now: t0.addingTimeInterval(90), isWatching: false))
}

@Test func aClearedFileIsNotAnAlertAndTheNextWaitingIs() {
    let throttle = AttentionThrottle()
    #expect(throttle.shouldAlert(project: "a", state: .waiting, now: t0, isWatching: false))
    #expect(!throttle.shouldAlert(project: "a", state: nil, now: t0.addingTimeInterval(1), isWatching: false))
    #expect(throttle.shouldAlert(project: "a", state: .waiting, now: t0.addingTimeInterval(100), isWatching: false))
}

// MARK: - Provider chips

private func run(_ cli: WorkerCLI, ago: TimeInterval, took: TimeInterval, text: String = "ok", isError: Bool = false, tail: String? = nil, exit: Int32 = 0) -> Run {
    let started = t0.addingTimeInterval(-ago)
    return Run(
        id: UUID().uuidString,
        spec: WorkerSpec(cli: cli, model: "m", prompt: "p", directory: project, access: .read, label: nil, kind: .explore, effort: nil, project: project),
        state: .finished(exitCode: exit),
        pid: nil,
        started: started,
        ended: started.addingTimeInterval(took),
        output: WorkerOutput(text: text, isError: isError),
        errorTail: tail,
        rating: nil
    )
}

private let utc = TimeZone(identifier: "UTC")!

@Test func nothingIsShownWhenAllIsWell() {
    let usage = SubscriptionUsage(sevenDay: 79, fiveHour: 99, updated: t0)
    #expect(ProviderChips.derive(runs: [run(.opencode, ago: 100, took: 20)], usage: usage, now: t0, timeZone: utc).isEmpty)
    #expect(ProviderChips.derive(runs: [], usage: nil, now: t0, timeZone: utc).isEmpty)
}

@Test func subscriptionChipIsAmberFromEightyAndDangerFromNinetyFive() {
    func chips(_ week: Double) -> [ProviderChip] {
        ProviderChips.derive(runs: [], usage: SubscriptionUsage(sevenDay: week, fiveHour: nil, updated: t0), now: t0, timeZone: utc)
    }
    #expect(chips(80).map(\.level) == [.warm])
    #expect(chips(94.4).first?.text == "claude semana 94%")
    #expect(chips(95).map(\.level) == [.hot])
}

@Test func staleUsageShowsNothing() {
    let usage = SubscriptionUsage(sevenDay: 99, fiveHour: nil, updated: t0.addingTimeInterval(-3 * 86_400))
    #expect(ProviderChips.derive(runs: [], usage: usage, now: t0, timeZone: utc).isEmpty)
}

@Test func quickQuotaFailureGivesAChipWithTheReturnTime() {
    // Failed 10 minutes ago after 4 s: back an hour after the failure.
    let failed = run(.opencode, ago: 600, took: 4, text: "Error: usage limit reached", isError: true, exit: 1)
    let chips = ProviderChips.derive(runs: [failed], usage: nil, now: t0, timeZone: utc)
    let back = failed.ended?.addingTimeInterval(3600) ?? t0
    let formatter = DateFormatter()
    formatter.timeZone = utc
    formatter.dateFormat = "HH:mm"
    #expect(chips == [ProviderChip(
        text: "opencode sem cota · volta ~\(formatter.string(from: back))",
        level: .muted,
        tooltip: "A última tarefa de opencode falhou por limite de uso; a volta é uma estimativa"
    )])
}

@Test func quotaWordsInTheErrorTailCountToo() {
    let failed = run(.gemini, ago: 60, took: 3, text: "", isError: true, tail: "HTTP 429 Too Many Requests", exit: 1)
    #expect(ProviderChips.derive(runs: [failed], usage: nil, now: t0, timeZone: utc).count == 1)
}

@Test func aSlowFailureAnOldOneOrAnOrdinaryErrorIsNoQuotaChip() {
    let slow = run(.opencode, ago: 600, took: 90, text: "quota exceeded", isError: true, exit: 1)
    let old = run(.cursor, ago: 4_000, took: 3, text: "quota exceeded", isError: true, exit: 1)
    let ordinary = run(.gemini, ago: 100, took: 3, text: "tests failed in file 4290", isError: true, exit: 1)
    #expect(ProviderChips.derive(runs: [slow, old, ordinary], usage: nil, now: t0, timeZone: utc).isEmpty)
}

@Test func aLaterSuccessClearsTheQuotaChip() {
    let failed = run(.opencode, ago: 600, took: 4, text: "rate limit", isError: true, exit: 1)
    let worked = run(.opencode, ago: 120, took: 30)
    #expect(ProviderChips.derive(runs: [failed, worked], usage: nil, now: t0, timeZone: utc).isEmpty)
}

@Test func chipsComeSubscriptionFirstThenWorkersInTheirOrder() {
    let usage = SubscriptionUsage(sevenDay: 88, fiveHour: nil, updated: t0)
    let runs = [
        run(.gemini, ago: 300, took: 2, text: "quota", isError: true, exit: 1),
        run(.opencode, ago: 200, took: 2, text: "quota", isError: true, exit: 1),
    ]
    let texts = ProviderChips.derive(runs: runs, usage: usage, now: t0, timeZone: utc).map(\.text)
    #expect(texts.map { $0.split(separator: " ").first.map(String.init) } == ["claude", "opencode", "gemini"])
}

@Test func aStatusLineRedrawnAfterAPermissionPromptMeansWorkResumed() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-att-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let project = "/tmp/project-\(UUID().uuidString)"
    let asked = Date(timeIntervalSince1970: 1_000)
    let record = AttentionRecord(state: .needsPermission, message: "permission", since: asked, path: CockpitProject(path: project).path)
    try #require(AttentionRecord.encode(record)).write(to: Attention.file(for: project, in: directory))

    // Drawn with the prompt itself: still asking.
    Attention.resumed(project: project, now: asked.addingTimeInterval(1), in: directory)
    #expect(Attention.load(for: project, in: directory)?.state == .needsPermission)

    Attention.resumed(project: project, now: asked.addingTimeInterval(5), in: directory)
    #expect(Attention.load(for: project, in: directory)?.state == .working)

    // A maestro that is merely waiting is not touched by its status line.
    let waiting = AttentionRecord(state: .waiting, message: nil, since: asked, path: record.path)
    try #require(AttentionRecord.encode(waiting)).write(to: Attention.file(for: project, in: directory))
    Attention.resumed(project: project, now: asked.addingTimeInterval(60), in: directory)
    #expect(Attention.load(for: project, in: directory)?.state == .waiting)
}
