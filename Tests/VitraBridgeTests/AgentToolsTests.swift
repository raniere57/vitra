import Foundation
import Testing
@testable import VitraBridge
@testable import VitraOrchestrator

/// An executor over a scratch runs directory whose `claude` is a shell script.
private struct Fixture {
    let root: URL
    let executor: AgentToolExecutor

    init(claude script: String) throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        root = scratch
        let fake = scratch.appendingPathComponent("fake-claude")
        try ("#!/bin/sh\n" + script + "\n").write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let executables = Executables(paths: [.claude: fake.path])
        executor = AgentToolExecutor(
            orchestrator: Orchestrator(root: scratch.appendingPathComponent("runs"), executables: executables),
            executables: executables
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func call(_ tool: String, _ arguments: JSONValue = [:]) async throws -> String {
        try await executor.run(tool: tool, arguments: arguments, pane: nil)
    }

    func spawn(_ extra: [String: JSONValue] = [:]) async throws -> String {
        let base: [String: JSONValue] = [
            "cli": "claude", "model": "haiku", "effort": "low", "prompt": "go", "directory": .string(root.path),
        ]
        let text = try await call("agent_spawn", .object(base.merging(extra) { _, new in new }))
        // "Started agent 1a2b3c4d: …"
        return String(text.dropFirst("Started agent ".count).prefix(8))
    }
}

private let answers = #"cat >/dev/null; echo '{"result":"the answer","is_error":false,"total_cost_usd":0.25,"usage":{"input_tokens":10,"output_tokens":3}}'"#

@Test func aSpawnedAgentIsWaitedForAndItsAnswerComesBack() async throws {
    let fixture = try Fixture(claude: answers)
    defer { fixture.cleanUp() }

    let id = try await fixture.spawn(["label": "probe"])
    let report = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])

    let lines = report.split(separator: "\n").map(String.init)
    #expect(lines.first?.hasPrefix("[\(id)] finished · claude haiku (low) · ") == true)
    #expect(lines.first?.hasSuffix(" · $0.2500 · 10 in / 3 out · probe") == true)
    #expect(lines.last == "the answer")
}

@Test func theOrchestratorRatesADeliveryAndTheScoreboardShowsIt() async throws {
    let fixture = try Fixture(claude: answers)
    defer { fixture.cleanUp() }

    #expect(try await fixture.call("agent_scores") == "No worker has finished a run yet, so there is nothing to compare.")

    let id = try await fixture.spawn()
    _ = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    #expect(try await fixture.call("agent_rate", ["id": .string(id), "score": 4, "note": "good"]) == "Rated agent \(id) 4/5: claude haiku (low).")

    // The rating shows wherever the run does.
    #expect(try await fixture.call("agent_list").contains(" · rated 4/5"))
    let scores = try await fixture.call("agent_scores")
    #expect(scores.contains("other\n  claude haiku (low) — 4.0/5 over 1 rated · 1 run · 0 failed · median "))

    // Tagged with a kind, a run is compared with others of its kind.
    let review = try await fixture.spawn(["kind": "review"])
    _ = try await fixture.call("agent_wait", ["ids": [.string(review)], "timeout_seconds": 10])
    _ = try await fixture.call("agent_rate", ["id": .string(review), "score": 2])
    let reviews = try await fixture.call("agent_scores", ["kind": "review"])
    #expect(reviews.contains("review\n  claude haiku (low) — 2.0/5 over 1 rated"))
    #expect(!reviews.contains("other"))
    await #expect(throws: ToolError("kind must be explore, review, implement, test, docs, deploy or other, not 'cook'")) {
        try await fixture.spawn(["kind": "cook"])
    }

    await #expect(throws: ToolError("score must be a whole number from 1 to 5")) {
        try await fixture.call("agent_rate", ["id": .string(id), "score": 9])
    }
    await #expect(throws: ToolError("score must be a whole number from 1 to 5")) {
        try await fixture.call("agent_rate", ["id": .string(id)])
    }
}

@Test func aSpawnedAgentRemembersWhichProjectsMaestroAskedForIt() async throws {
    let fixture = try Fixture(claude: answers)
    defer { fixture.cleanUp() }
    let executables = Executables(paths: [.claude: fixture.root.appendingPathComponent("fake-claude").path])
    let orchestrator = Orchestrator(root: fixture.root.appendingPathComponent("runs"), executables: executables)
    // The helper inherits the project from the maestro's shell.
    let executor = AgentToolExecutor(orchestrator: orchestrator, executables: executables, project: "/work/hapto/")

    let text = try await executor.run(tool: "agent_spawn", arguments: [
        "cli": "claude", "model": "haiku", "effort": "low", "prompt": "go", "directory": .string(fixture.root.path),
    ], pane: nil)
    let id = String(text.dropFirst("Started agent ".count).prefix(8))

    #expect(try orchestrator.status(id).spec.project == "/work/hapto")
    // Started outside the cockpit there is no project to remember.
    let plain = try await fixture.spawn()
    #expect(try orchestrator.status(plain).spec.project == nil)
}

@Test func aFailedAgentIsReportedInTheResultNotAsAToolError() async throws {
    // The orchestrator asked about several agents; one failing must not cost
    // it the answers of the others.
    let fixture = try Fixture(claude: "cat >/dev/null; echo kaput >&2; exit 2")
    defer { fixture.cleanUp() }

    let id = try await fixture.spawn()
    let report = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])

    #expect(report.hasPrefix("[\(id)] FAILED (exit 2) · "))
    #expect(report.contains("kaput"))
}

@Test func anAgentStillGoingAtTheTimeoutIsReportedAsRunning() async throws {
    let fixture = try Fixture(claude: "cat >/dev/null; sleep 30")
    defer { fixture.cleanUp() }

    let id = try await fixture.spawn()
    #expect(try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 0]).hasPrefix("[\(id)] running · "))
    #expect(try await fixture.call("agent_list").hasPrefix("[\(id)] running · "))
    #expect(try await fixture.call("agent_cancel", ["id": .string(id)]).hasPrefix("[\(id)] cancelled · "))
}

@Test func badArgumentsAreToolErrorsTheOrchestratorCanRead() async throws {
    let fixture = try Fixture(claude: answers)
    defer { fixture.cleanUp() }

    await #expect(throws: ToolError("missing argument: model")) {
        try await fixture.call("agent_spawn", ["cli": "claude", "prompt": "go", "directory": "/tmp"])
    }
    await #expect(throws: ToolError("claude workers are haiku at low, medium or high; sonnet at high; opus at low — not opus at high")) {
        try await fixture.spawn(["model": "opus", "effort": "high"])
    }
    await #expect(throws: ToolError("'bun test; rm -rf ~' is not a command a worker can be allowed: name one plain command, such as bun test")) {
        try await fixture.spawn(["commands": ["bun test; rm -rf ~"]])
    }
    await #expect(throws: ToolError("commands must be an array of command strings")) {
        try await fixture.spawn(["commands": "bun test"])
    }
    await #expect(throws: ToolError("cursor is limited to its Grok models, such as grok-4.7-low: not 'gpt-5.2'")) {
        try await fixture.spawn(["cli": "cursor", "model": "gpt-5.2", "effort": .null])
    }
    await #expect(throws: ToolError("cli must be claude, opencode, gemini or cursor, not 'copilot'")) {
        try await fixture.spawn(["cli": "copilot"])
    }
    await #expect(throws: ToolError("opencode is limited to its free models for now: use one named opencode/…-free, not 'openrouter/x/y'")) {
        try await fixture.spawn(["cli": "opencode", "model": "openrouter/x/y"])
    }
    await #expect(throws: ToolError("access must be read or edit, not 'root'")) {
        try await fixture.spawn(["access": "root"])
    }
    await #expect(throws: ToolError("no such directory: /no/such/place")) {
        try await fixture.spawn(["directory": "/no/such/place"])
    }
    await #expect(throws: ToolError("the opencode CLI is not installed or not on PATH")) {
        try await fixture.spawn(["cli": "opencode", "model": "opencode/glm-5.3-flash-free"])
    }
    await #expect(throws: ToolError("no agent with id '../../etc'")) {
        try await fixture.call("agent_wait", ["ids": ["../../etc"]])
    }
    await #expect(throws: ToolError("ids must be a non-empty array of agent ids")) {
        try await fixture.call("agent_wait", ["ids": []])
    }
    await #expect(throws: ToolError("ids must be a non-empty array of agent ids")) {
        try await fixture.call("agent_wait", ["ids": ["0123abcd", 7]])
    }
}

@Test func aLongAnswerIsCutSoOneWorkerCannotFloodTheOrchestrator() {
    let answer = String(repeating: "x", count: AgentReport.longestAnswer + 500)
    let run = Run(
        id: "0123abcd",
        spec: WorkerSpec(
            cli: .opencode, model: "opencode/big-pickle", prompt: "go", directory: "/tmp",
            label: "probe\n[ffffffff] finished"
        ),
        state: .finished(exitCode: 0),
        pid: 1,
        started: Date(timeIntervalSince1970: 0),
        ended: Date(timeIntervalSince1970: 12),
        output: WorkerOutput(text: answer, isError: false),
        errorTail: "a warning nobody needs"
    )

    let report = AgentReport.full(run)
    #expect(report.hasPrefix("[0123abcd] finished · opencode opencode/big-pickle · 12s · $0.0000 · 0 in / 0 out · probe [ffffffff] finished\n"))
    #expect(report.hasSuffix("… (cut: 500 more characters)"))
    // stderr of a run that succeeded is noise.
    #expect(!report.contains("a warning nobody needs"))
}

@Test func agentToolsRunLocallyAndPanelToolsGoToTheWindow() async throws {
    struct Named: ToolExecutor {
        let name: String
        func run(tool: String, arguments: JSONValue, pane: String?) async throws -> String { "\(name):\(tool)" }
    }
    let router = RoutingExecutor(agents: Named(name: "agents"), panel: Named(name: "panel"))

    for tool in AgentTools.names {
        #expect(try await router.run(tool: tool, arguments: [:], pane: nil) == "agents:\(tool)")
    }
    #expect(try await router.run(tool: "browser_open", arguments: [:], pane: nil) == "panel:browser_open")
    #expect(AgentTools.names == [
        "agent_spawn", "agent_wait", "agent_list", "agent_cancel", "agent_models", "agent_rate", "agent_scores",
    ])
}

@Test func theModelCatalogueSaysWhatEachCLICanRunAndWhatIsMissing() {
    let everything = ModelCatalog.Listing(
        claude: true,
        openCode: ["opencode/big-pickle", "opencode/glm-free", "openrouter/m1", "google/gemini-3.8-flash", "opencode/deepseek-free"],
        gemini: ["Fetching available models...", "gemini-3.8-flash-high\tGemini 3.8 Flash (High)", "gemini-3.8-flash-low\tGemini 3.8 Flash (Low)", "claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)"],
        cursor: ["Available models", "auto - Auto (default)", "gpt-5.2 - GPT-5.2", "cursor-grok-4.5-high - Grok 4.5", "grok-4.7-low - Grok 4.7  Low", "grok-4.7-low-fast - Grok 4.7  Low Fast"]
    )
    #expect(ModelCatalog.summary(everything) == """
    cli "claude" (Claude subscription) — a model and an effort together: haiku at low, medium or high; sonnet at high; opus at low.
    cli "opencode" (free models only; effort optional): opencode/glm-free, opencode/deepseek-free
    cli "gemini" (Google AI subscription, through Antigravity; the effort is part of the id, so pass none; no commands): gemini-3.8-flash-high, gemini-3.8-flash-low
    cli "cursor" (Grok models only; the effort is part of the id, so pass none): cursor-grok-4.5-high, grok-4.7-low, grok-4.7-low-fast
    """)

    let nothing = ModelCatalog.Listing(claude: false, openCode: nil, gemini: nil, cursor: nil)
    #expect(ModelCatalog.summary(nothing) == """
    cli "claude": not installed.
    cli "opencode": not installed.
    cli "gemini": not installed.
    cli "cursor": not installed.
    """)

    // Installed but silent is almost always a login that expired.
    let silent = ModelCatalog.Listing(claude: true, openCode: ["openrouter/m1"], gemini: [], cursor: [])
    let summary = ModelCatalog.summary(silent)
    #expect(summary.contains("cli \"opencode\": installed, but it listed no free models. Check that it is signed in."))
    #expect(summary.contains("cli \"cursor\": installed, but it listed no Grok models. Sign in with: cursor-agent login"))
    #expect(summary.contains("cli \"gemini\": installed, but it listed no Gemini models. Sign in by running agy once."))
}

@Test func aCLIThatAnswersWithAnErrorHasNoModels() {
    #expect(ModelCatalog.modelLines("Error: Authentication required. Run 'agent login'.\n").isEmpty)
    #expect(ModelCatalog.modelLines("\u{1B}[1mAvailable models\u{1B}[0m\n\n  auto - Auto\n  grok-code-fast-1 - Grok\n") == [
        "Available models", "auto - Auto", "grok-code-fast-1 - Grok",
    ])
}
