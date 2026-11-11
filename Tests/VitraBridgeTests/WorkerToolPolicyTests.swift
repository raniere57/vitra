import Foundation
import Testing
@testable import VitraBridge
@testable import VitraOrchestrator

/// Answers every call with the tool's name, so a test can tell it ran.
private struct Echo: ToolExecutor {
    func run(tool: String, arguments: JSONValue, pane: String?) async throws -> String { "ran \(tool)" }
}

/// A runs root with records written the way `spawn` writes them.
private struct Runs {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-tiers-\(UUID().uuidString)")

    func add(_ id: String, access: WorkerAccess, kind: TaskKind? = nil, label: String? = nil, focus: [AuditFocus]? = nil) throws {
        let spec = WorkerSpec(
            cli: .claude, model: "haiku", prompt: "p", directory: "/tmp", access: access, label: label, kind: kind,
            auditFocus: focus
        )
        let record = RunRecord(
            spec: spec, started: Date(), pid: 4242, leaderStarted: nil, repository: nil, worktree: nil, branch: nil, baseCommit: nil
        )
        let directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("run.json"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func spec(_ access: WorkerAccess, _ kind: TaskKind?, audit: Bool) -> WorkerSpec {
    WorkerSpec(
        cli: .claude, model: "haiku", prompt: "p", directory: "/tmp", access: access, kind: kind,
        auditFocus: audit ? [.general] : nil
    )
}

private func names(_ tools: [JSONValue]) -> Set<String> { Set(tools.compactMap { $0["name"]?.stringValue }) }

private func call(_ name: String, _ arguments: JSONValue = [:]) -> JSONRPC.Request {
    JSONRPC.Request(id: .number(1), method: "tools/call", params: ["name": .string(name), "arguments": arguments])
}

private func text(_ response: JSONRPC.Response?) -> String? {
    response?.result?["content"]?.arrayValue?.first?["text"]?.stringValue
}

// MARK: - The decision

@Test func everyKindAccessAndAuditGetsTheTierItsJobNeeds() {
    for kind in TaskKind.allCases.map(Optional.some) + [nil] {
        for audit in [false, true] {
            // An editor is an editor whatever it is about: auditFocus on an
            // editing spec is the focus its audit was forced to, not an audit.
            #expect(WorkerToolTier(spec: spec(.edit, kind, audit: audit)) == .editor)
            let expected: WorkerToolTier = audit || kind == .review ? .auditor : .reader
            #expect(WorkerToolTier(spec: spec(.read, kind, audit: audit)) == expected, "read \(String(describing: kind)) audit \(audit)")
        }
    }
    // The automatic audit's label says so too, whatever its focuses.
    let labelled = WorkerSpec(cli: .claude, model: "m", prompt: "p", directory: "/tmp", label: "auditoria: login", kind: .explore)
    #expect(WorkerToolTier(spec: labelled) == .auditor)
    // A run nobody can find gets the least.
    #expect(WorkerToolTier(spec: nil) == .auditor)
}

@Test func theTierIsReadFromTheRunsRecordAndAnUnknownRunGetsTheLeast() throws {
    let runs = Runs()
    defer { runs.cleanUp() }
    try runs.add("aaaa0001", access: .read, kind: .explore)
    try runs.add("aaaa0002", access: .edit, kind: .implement)
    try runs.add("aaaa0003", access: .read, kind: .review, focus: [.security])
    #expect(WorkerToolTier.of(run: "aaaa0001", root: runs.root) == .reader)
    #expect(WorkerToolTier.of(run: "aaaa0002", root: runs.root) == .editor)
    #expect(WorkerToolTier.of(run: "aaaa0003", root: runs.root) == .auditor)
    #expect(WorkerToolTier.of(run: "bbbb0001", root: runs.root) == .auditor)
    #expect(WorkerToolTier.of(run: nil, root: runs.root) == .auditor)
    #expect(WorkerToolTier.of(run: "../aaaa0002", root: runs.root) == .auditor)
}

// MARK: - What is advertised

@Test func eachTierIsAdvertisedOnlyItsOwnTools() {
    #expect(names(MCPTools.worker(.auditor)) == ["memory_read"])
    #expect(names(MCPTools.worker(.reader)) == [
        "browser_open", "browser_snapshot", "browser_screenshot", "browser_console", "browser_back",
        "browser_forward", "browser_tabs", "memory_read", "memory_add",
    ])
    #expect(names(MCPTools.worker(.editor)) == names(MCPTools.panel + MemoryTools.all).subtracting(["terminal_run"]))
    for tier in WorkerToolTier.allCases {
        #expect(names(MCPTools.worker(tier)) == tier.tools)
        let tools = MCPTools.worker(tier)
        // No worker is offered a way to name somebody else's tab.
        #expect(tools.allSatisfy { $0["inputSchema"]?["properties"]?["tab"] == nil })
        // And a worker's screen capture names an app.
        if let capture = tools.first(where: { $0["name"]?.stringValue == "screen_capture" }) {
            #expect(capture["inputSchema"]?["required"] == ["app"])
        }
    }
}

@Test func aRestrictedWorkerIsToldWhichToolsItHasAndAnEditorIsNot() {
    #expect(WorkerToolTier.auditor.promptLine?.contains("only memory_read") == true)
    #expect(WorkerToolTier.reader.promptLine?.contains("browser_open") == true)
    #expect(WorkerToolTier.reader.promptLine?.contains("browser_click") == false)
    #expect(WorkerToolTier.editor.promptLine == nil)
}

// MARK: - The helper's call path

@Test func aWorkerHelperRefusesWhatItsTierDoesNotHaveAndServesTheRest() async throws {
    let runs = Runs()
    defer { runs.cleanUp() }
    try runs.add("cccc0001", access: .read, kind: .explore)
    let server = StdioBridge.makeServer(role: .worker, agent: "cccc0001", runsRoot: runs.root, memory: Echo(), remote: Echo())

    let listed = await server.handle(JSONRPC.Request(id: .number(1), method: "tools/list"))
    #expect(names(listed?.result?["tools"]?.arrayValue ?? []) == WorkerToolTier.reader.tools)

    #expect(text(await server.handle(call("browser_open", ["url": "https://a.com"]))) == "ran browser_open")
    for tool in ["browser_click", "browser_type", "browser_eval", "screen_capture", "terminal_read", "preview_file", "terminal_run", "agent_spawn"] {
        let refused = await server.handle(call(tool))
        #expect(refused?.result?["isError"]?.boolValue == true)
        #expect(text(refused)?.hasPrefix(WorkerToolPolicy.refusalPrefix) == true, "\(tool)")
    }
    // Another agent's tab, even to look at.
    let peek = await server.handle(call("browser_snapshot", ["tab": "maestro"]))
    #expect(text(peek)?.hasPrefix(WorkerToolPolicy.refusalPrefix) == true)
}

@Test func anAuditorHelperHasOnlyTheNotesToRead() async throws {
    let runs = Runs()
    defer { runs.cleanUp() }
    try runs.add("cccc0002", access: .read, kind: .review, label: "auditoria: x", focus: [.general])
    let server = StdioBridge.makeServer(role: .worker, agent: "cccc0002", runsRoot: runs.root, memory: Echo(), remote: Echo())
    #expect(text(await server.handle(call("memory_read"))) == "ran memory_read")
    for tool in ["memory_add", "browser_open", "browser_tabs", "screen_capture"] {
        #expect(text(await server.handle(call(tool)))?.hasPrefix(WorkerToolPolicy.refusalPrefix) == true, "\(tool)")
    }
    // A helper whose run cannot be found is an auditor too.
    let lost = StdioBridge.makeServer(role: .worker, agent: nil, runsRoot: runs.root, memory: Echo(), remote: Echo())
    let listed = await lost.handle(JSONRPC.Request(id: .number(1), method: "tools/list"))
    #expect(names(listed?.result?["tools"]?.arrayValue ?? []) == ["memory_read"])
}

@Test func anEditorCapturesANamedAppNeverTheWholeScreen() async throws {
    let runs = Runs()
    defer { runs.cleanUp() }
    try runs.add("cccc0003", access: .edit, kind: .implement)
    let server = StdioBridge.makeServer(role: .worker, agent: "cccc0003", runsRoot: runs.root, memory: Echo(), remote: Echo())
    #expect(text(await server.handle(call("screen_capture")))?.hasPrefix(WorkerToolPolicy.refusalPrefix) == true)
    #expect(text(await server.handle(call("screen_capture", ["app": "Safari"]))) == "ran screen_capture")
    #expect(text(await server.handle(call("browser_click", ["ref": "e1"]))) == "ran browser_click")
    // Its own tab by name is its own.
    #expect(text(await server.handle(call("browser_console", ["tab": "cccc0003"]))) == "ran browser_console")
    #expect(text(await server.handle(call("terminal_run", ["command": "ls"])))?.hasPrefix(WorkerToolPolicy.refusalPrefix) == true)
}

@Test func theMaestroAndSoloAreServedAsBefore() async {
    let maestro = StdioBridge.makeServer(role: .maestro, agent: nil, memory: Echo(), remote: Echo(), agents: Echo())
    let listed = await maestro.handle(JSONRPC.Request(id: .number(1), method: "tools/list"))
    #expect(names(listed?.result?["tools"]?.arrayValue ?? []) == names(MCPTools.all))
    #expect(text(await maestro.handle(call("screen_capture"))) == "ran screen_capture")
    #expect(text(await maestro.handle(call("browser_snapshot", ["tab": "ab12cd34"]))) == "ran browser_snapshot")

    let solo = StdioBridge.makeServer(role: .solo, agent: nil, memory: Echo(), remote: Echo())
    let soloListed = await solo.handle(JSONRPC.Request(id: .number(1), method: "tools/list"))
    #expect(names(soloListed?.result?["tools"]?.arrayValue ?? []) == names(MCPTools.solo))
    #expect(text(await solo.handle(call("terminal_run", ["command": "ls"]))) == "ran terminal_run")
}

@Test func theHelperSaysItServesAWorkerAndTheModelCannotSayOtherwise() {
    let forged: JSONValue = ["url": "https://a.com", "_worker": false, "_agent": "x"]
    #expect(RemoteExecutor.arguments(forged, agent: nil, isWorker: true) == ["url": "https://a.com", "_worker": true])
    #expect(RemoteExecutor.arguments(["_worker": true], agent: nil) == [:])
}

// MARK: - The app's side

@Test func theAppDerivesTheTierFromTheRunRecordNotFromTheHelper() throws {
    let runs = Runs()
    defer { runs.cleanUp() }
    try runs.add("dddd0001", access: .read, kind: .review, focus: [.security])
    try runs.add("dddd0002", access: .read, kind: .docs)
    try runs.add("dddd0003", access: .edit, kind: .test)
    let refused = { (tool: String, arguments: JSONValue) in
        WorkerToolPolicy.appRefusal(tool: tool, arguments: arguments, runsRoot: runs.root) != nil
    }

    #expect(refused("browser_open", ["_agent": "dddd0001", "url": "https://a.com"]))
    #expect(!refused("browser_open", ["_agent": "dddd0002", "url": "https://a.com"]))
    #expect(refused("browser_eval", ["_agent": "dddd0002", "script": "1"]))
    #expect(!refused("browser_eval", ["_agent": "dddd0003", "script": "1"]))
    #expect(refused("terminal_read", ["_agent": "dddd0002"]))
    #expect(!refused("terminal_read", ["_agent": "dddd0003"]))
    #expect(refused("terminal_run", ["_agent": "dddd0003", "command": "ls"]))

    // A run nobody can find, or a worker that names none: the least.
    #expect(refused("browser_open", ["_agent": "eeee0001", "url": "https://a.com"]))
    #expect(refused("browser_open", ["_worker": true, "url": "https://a.com"]))
    #expect(refused("browser_open", ["_agent": "../../etc", "url": "https://a.com"]))

    // The editor's limits that are about arguments, not tools.
    #expect(refused("screen_capture", ["_agent": "dddd0003"]))
    #expect(!refused("screen_capture", ["_agent": "dddd0003", "app": "Simulator"]))
    #expect(refused("browser_snapshot", ["_agent": "dddd0003", "tab": "maestro"]))
    #expect(refused("browser_console", ["_agent": "dddd0003", "tab": "dddd0002"]))
    #expect(!refused("browser_snapshot", ["_agent": "dddd0003", "tab": "dddd0003"]))

    // The maestro's calls name no worker and are not gated.
    #expect(!refused("screen_capture", [:]))
    #expect(!refused("terminal_run", ["command": "ls"]))
    #expect(!refused("browser_snapshot", ["tab": "dddd0003"]))
}

@Test func aWorkerIsListedOnlyItsOwnTab() {
    let lines = [
        "maestro · maestro · Home · https://a.com",
        "dddd0003 · fix login · Login · https://b.com (yours)",
        "dddd00031 · other · https://c.com",
        "você · você · https://d.com",
    ]
    #expect(WorkerToolPolicy.ownTabs(lines, agent: "dddd0003") == ["dddd0003 · fix login · Login · https://b.com (yours)"])
    #expect(WorkerToolPolicy.ownTabs(lines, agent: nil).isEmpty)
}
