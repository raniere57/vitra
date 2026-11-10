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
