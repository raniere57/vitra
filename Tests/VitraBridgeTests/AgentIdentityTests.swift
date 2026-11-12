import Darwin
import Foundation
import Testing
@testable import VitraBridge

/// A KERN_PROCARGS2 buffer as the kernel lays it out: argc, exec path, padding
/// NULs, argv, then the environment, each string NUL-terminated.
private func procargs2(argv: [String], exec: String = "/usr/bin/vitra", padding: Int = 3, env: [String]) -> Data {
    var data = withUnsafeBytes(of: Int32(argv.count).littleEndian) { Data($0) }
    data.append(contentsOf: Array(exec.utf8) + [0])
    data.append(contentsOf: [UInt8](repeating: 0, count: padding))
    for string in argv + env {
        data.append(contentsOf: Array(string.utf8) + [0])
    }
    return data
}

@Test func theEnvironmentIsParsedPastArgvAndPadding() {
    let data = procargs2(
        argv: ["vitra", "mcp", "VITRA_AGENT=notThis"],
        env: ["PATH=/usr/bin:/bin", "VITRA_AGENT=abcd1234", "EQUALS=a=b", "EMPTY="]
    )

    let env = AgentIdentity.environment(procargs2: data)

    #expect(env?["VITRA_AGENT"] == "abcd1234")
    #expect(env?["PATH"] == "/usr/bin:/bin")
    #expect(env?["EQUALS"] == "a=b")
    #expect(env?["EMPTY"] == "")
    #expect(env?["VITRA_AGENT"] != "notThis")
}

@Test func anEmptyArgvStringInTheMiddleDoesNotShiftTheEnvironment() {
    let data = procargs2(argv: ["vitra", "", "run"], env: ["VITRA_PROJECT=/work/app"])

    #expect(AgentIdentity.environment(procargs2: data)?["VITRA_PROJECT"] == "/work/app")
}

@Test func aTruncatedBufferIsRefused() {
    var data = procargs2(argv: ["vitra", "mcp"], env: ["A=1"])
    data.removeLast(data.count - 6)  // argc says two argv strings; the buffer ends inside the first

    #expect(AgentIdentity.environment(procargs2: data) == nil)
}

@Test func ownEnvironmentWinsOverAncestors() {
    let identity = AgentIdentity.resolve(
        own: ["VITRA_AGENT": "own00001", "VITRA_PROJECT": "/own", "VITRA_PANE": "p-own"],
        nearestAncestor: { ["VITRA_AGENT": "anc00002", "VITRA_PROJECT": "/anc", "VITRA_PANE": "p-anc"] },
        runProject: { _ in "/from/run.json" }
    )

    #expect(identity == AgentIdentity(agent: "own00001", project: "/own", pane: "p-own"))
}

@Test func ancestorSuppliesWhatOwnEnvironmentLacks() {
    let identity = AgentIdentity.resolve(
        own: [:],
        nearestAncestor: { ["VITRA_AGENT": "anc00002", "VITRA_PROJECT": "/anc", "VITRA_PANE": "p-anc"] },
        runProject: { _ in "/from/run.json" }
    )

    #expect(identity == AgentIdentity(agent: "anc00002", project: "/anc", pane: "p-anc"))
}

@Test func runRecordSuppliesTheProjectWhenNoAgentNamesOne() {
    let identity = AgentIdentity.resolve(
        own: [:],
        nearestAncestor: { ["VITRA_RUN": "/home/.vitra/runs/feedbeef"] },
        runProject: { run in run == "/home/.vitra/runs/feedbeef" ? "/work/app" : nil }
    )

    #expect(identity == AgentIdentity(agent: "feedbeef", project: "/work/app", pane: nil))
}

@Test func theProjectFromTheEnvironmentBeatsTheRunRecord() {
    let identity = AgentIdentity.resolve(
        own: ["VITRA_PROJECT": "/own"],
        nearestAncestor: { ["VITRA_RUN": "/home/.vitra/runs/feedbeef"] },
        runProject: { _ in "/from/run.json" }
    )

    #expect(identity.project == "/own")
    #expect(identity.agent == "feedbeef")
}

@Test func withNothingSetNothingIsResolved() {
    let identity = AgentIdentity.resolve(own: [:], nearestAncestor: { nil }, runProject: { _ in "/never" })

    #expect(identity == AgentIdentity(agent: nil, project: nil, pane: nil))
}

@Test func runRecordProjectIsReadFromSpec() {
    let record = Data(#"{"spec":{"project":"/work/app"},"pid":42}"#.utf8)
    let empty = Data(#"{"spec":{"project":""}}"#.utf8)

    #expect(AgentIdentity.projectFromRunRecord(record) == "/work/app")
    #expect(AgentIdentity.projectFromRunRecord(empty) == nil)
    #expect(AgentIdentity.projectFromRunRecord(Data("not json".utf8)) == nil)
}

// MARK: - Which tool set the helper serves

@Test func onlyTheMaestroRoleGetsTheMaestrosTools() {
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_ROLE": "maestro"]) == .maestro)
}

@Test func aWorkerEnvironmentGetsTheWorkerSetEvenWithTheMaestroRole() {
    // A worker's helper inherits the maestro's role from its spawner; the run
    // it names is what decides.
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_ROLE": "maestro", "VITRA_AGENT": "abcd1234"]) == .worker)
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_ROLE": "maestro", "VITRA_RUN": "/x/runs/abcd1234"]) == .worker)
}

@Test func thePaneAloneMakesTheMaestroEvenWithAnOldConfigWithoutTheRole() {
    // A maestro started from a config written before VITRA_ROLE existed, or
    // relaunched by hand in the project's shell, still has the pane.
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_PANE": "pane-1"]) == .maestro)
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_ROLE": "", "VITRA_PANE": "pane-1"]) == .maestro)
}

@Test func thePaneDoesNotMakeAWorkerAMaestro() {
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_PANE": "pane-1", "VITRA_AGENT": "abcd1234"]) == .worker)
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_PANE": "pane-1", "VITRA_RUN": "/x/runs/abcd1234"]) == .worker)
}

@Test func theSoloRoleWinsOverThePaneAndLosesToAWorker() {
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_ROLE": "solo", "VITRA_PANE": "pane-1"]) == .solo)
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_ROLE": "solo"]) == .solo)
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_ROLE": "solo", "VITRA_AGENT": "abcd1234"]) == .worker)
}

@Test func soloIsServedThePanelAndNotesWithoutAgents() {
    let names = MCPTools.solo.compactMap { $0["name"]?.stringValue }
    #expect(!names.contains { $0.hasPrefix("agent_") })
    for name in ["browser_open", "terminal_read", "terminal_run", "screen_capture", "preview_file", "memory_read", "memory_add"] {
        #expect(names.contains(name))
    }
    #expect(MCPTools.all.contains { $0["name"]?.stringValue == "agent_spawn" })
}

@Test func anUnknownCallerGetsTheWorkerSet() {
    #expect(AgentIdentity.ServedRole.decide(own: [:]) == .worker)
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_ROLE": "something"]) == .worker)
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_ROLE": ""]) == .worker)
    #expect(AgentIdentity.ServedRole.decide(own: ["VITRA_PANE": ""]) == .worker)
}

// MARK: - Identity by working directory

/// A runs root holding one run whose `run.json` names a project.
private func fakeRuns() throws -> (root: URL, run: URL) {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-runs-\(UUID().uuidString)")
    let root = scratch.appendingPathComponent("runs")
    let run = root.appendingPathComponent("abcd1234")
    try FileManager.default.createDirectory(at: run.appendingPathComponent("tree"), withIntermediateDirectories: true)
    try Data(#"{"spec":{"project":"/work/app"}}"#.utf8).write(to: run.appendingPathComponent("run.json"))
    return (root, run)
}

@Test func workingDirectoryInsideARunNamesTheRun() throws {
    let (root, run) = try fakeRuns()
    let identity = AgentIdentity.resolve(
        own: [:],
        cwd: run.appendingPathComponent("tree").path,
        runsRoot: root,
        nearestAncestor: { nil },
        runProject: { AgentIdentity.projectFromRunRecord(at: URL(fileURLWithPath: $0).appendingPathComponent("run.json")) }
    )

    #expect(identity == AgentIdentity(agent: "abcd1234", project: "/work/app", pane: nil))
}

@Test func workingDirectoryOutsideTheRunsDoesNotNameARun() throws {
    let (root, run) = try fakeRuns()
    let outside = [run.deletingLastPathComponent().deletingLastPathComponent().path, root.path, "/work/app"]
    for cwd in outside {
        let identity = AgentIdentity.resolve(
            own: [:],
            cwd: cwd,
            runsRoot: root,
            nearestAncestor: { nil },
            runProject: { _ in "/never" }
        )
        #expect(identity.agent == nil, "cwd \(cwd)")
    }
}

@Test func theEnvironmentBeatsTheWorkingDirectory() throws {
    let (root, run) = try fakeRuns()
    let identity = AgentIdentity.resolve(
        own: ["VITRA_AGENT": "own00001"],
        cwd: run.path,
        runsRoot: root,
        nearestAncestor: { nil },
        runProject: { _ in "/never" }
    )

    #expect(identity.agent == "own00001")
}

@Test func theWorkingDirectoryBeatsTheAncestor() throws {
    let (root, run) = try fakeRuns()
    let identity = AgentIdentity.resolve(
        own: [:],
        cwd: run.path,
        runsRoot: root,
        nearestAncestor: { ["VITRA_AGENT": "anc00002"] },
        runProject: { _ in nil }
    )

    #expect(identity.agent == "abcd1234")
}

/// Live: a shell started with `VITRA_AGENT=abcd1234` runs `env -i sleep`, so
/// the sleep (the grandchild) has an empty environment. Its identity has to be
/// found by walking up to the shell. The test does the walk from the
/// grandchild's pid rather than running code inside it; the walk is the same.
@Test(.disabled("KERN_PROCARGS2 returned no environment for Apple-signed children (/bin/sh, /bin/sleep) on macOS 26; see the report on the branch")) func aProcessWithAnEmptyEnvironmentFindsTheAgentAboveIt() throws {
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    shell.arguments = [
        "VITRA_AGENT=abcd1234", "/bin/sh", "-c",
        "env -i /bin/sleep 30 & echo $!; wait",
    ]
    let output = Pipe()
    shell.standardOutput = output
    try shell.run()
    defer {
        shell.terminate()
        shell.waitUntilExit()
    }

    let line = try #require(String(data: output.fileHandleForReading.availableData, encoding: .utf8))
    let grandchild = try #require(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { kill(grandchild, SIGKILL) }

    #expect(AgentIdentity.environment(ofProcess: grandchild) == [:])
    let identity = AgentIdentity.resolve(own: [:], startingAt: grandchild)
    #expect(identity.agent == "abcd1234")
}

@Test func aHelperStartedWithACleanEnvironmentTakesItsRoleFromTheCLIAboveIt() {
    typealias Role = AgentIdentity.ServedRole
    // Cursor starts the helper with nothing of ours: the agent's own environment says.
    #expect(Role.decide(own: [:]) { ["VITRA_ROLE": "maestro", "VITRA_PANE": "/p"] } == .maestro)
    #expect(Role.decide(own: [:]) { ["VITRA_ROLE": "solo", "VITRA_PANE": "/p"] } == .solo)
    // A worker above is a worker, whatever role it also carries.
    #expect(Role.decide(own: [:]) { ["VITRA_ROLE": "maestro", "VITRA_RUN": "/x/runs/abcd1234"] } == .worker)
    // A pane alone above is not a maestro: any CLI run in the project's shell has it.
    #expect(Role.decide(own: [:]) { ["VITRA_PANE": "/p"] } == .worker)
    #expect(Role.decide(own: [:]) { nil } == .worker)
    // What the helper's own environment says is never overruled from above.
    #expect(Role.decide(own: ["VITRA_AGENT": "abcd1234"]) { ["VITRA_ROLE": "maestro"] } == .worker)
}
