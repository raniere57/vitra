import Foundation
import Testing
@testable import VitraBridge
@testable import VitraOrchestrator

/// An executor over a scratch runs directory whose `claude` is a shell script.
private struct Fixture {
    let root: URL
    let orchestrator: Orchestrator
    let executor: AgentToolExecutor

    init(claude script: String, opencode: String? = nil) throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        root = scratch
        let fake = scratch.appendingPathComponent("fake-claude")
        try ("#!/bin/sh\n" + script + "\n").write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var paths: [WorkerCLI: String] = [.claude: fake.path]
        if let opencode {
            let fakeOpenCode = scratch.appendingPathComponent("fake-opencode")
            try ("#!/bin/sh\n" + opencode + "\n").write(to: fakeOpenCode, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenCode.path)
            paths[.opencode] = fakeOpenCode.path
        }
        let executables = Executables(paths: paths)
        orchestrator = Orchestrator(root: scratch.appendingPathComponent("runs"), executables: executables)
        executor = AgentToolExecutor(orchestrator: orchestrator, executables: executables)
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

@Test func aWorktreeSetupLineThatWasSkippedIsInTheReportAndNothingElseIs() {
    let spec = WorkerSpec(cli: .claude, model: "haiku", prompt: "x", directory: "/tmp", access: .edit, label: nil, effort: "low")
    var run = Run(
        id: "aaaaaaaa", spec: spec, state: .finished(exitCode: 0), pid: nil,
        started: Date(), ended: nil, output: nil, errorTail: nil
    )
    #expect(!AgentReport.full(run).contains("worktree setup"))

    run.worktreeSkipped = ["link vendor/absent: missing in the checkout", "copy a: already in the worktree"]
    #expect(AgentReport.full(run).contains(
        "worktree setup skipped: link vendor/absent: missing in the checkout; copy a: already in the worktree"
    ))
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

/// Runs git in `directory`, with an identity fixed so a machine with none
/// configured can still commit, and returns what it printed.
@discardableResult
private func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_AUTHOR_NAME"] = "Vitra test"
    environment["GIT_AUTHOR_EMAIL"] = "test@vitra.local"
    environment["GIT_COMMITTER_NAME"] = "Vitra test"
    environment["GIT_COMMITTER_EMAIL"] = "test@vitra.local"
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw ToolError("git \(arguments.joined(separator: " ")): \(output)")
    }
    return output
}

/// Makes a repository at `directory` holding one commit, and returns that
/// commit along with the branch it is on.
private func makeRepository(at directory: URL) throws -> (head: String, trunk: String) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try git(["init", "-q"], in: directory)
    try "initial\n".write(to: directory.appendingPathComponent("README"), atomically: true, encoding: .utf8)
    try git(["add", "-A"], in: directory)
    try git(["commit", "-q", "-m", "initial"], in: directory)
    let head = try git(["rev-parse", "HEAD"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    let trunk = try git(["symbolic-ref", "--short", "HEAD"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    return (head, trunk)
}

@Test func theReportOfAWorkedBranchSaysWhereItsWorkIsAndHowToMergeIt() throws {
    // A real repository, in paths a shell would break on if they went in raw:
    // the report has to quote them, and the shortstat has to be computed
    // against a branch that really holds a commit.
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vitra report \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let repository = scratch.appendingPathComponent("my repo")
    let worktree = scratch.appendingPathComponent("work trees/0123abcd")
    let (base, trunk) = try makeRepository(at: repository)

    // The worker's branch: one commit on top of the base.
    try git(["checkout", "-q", "-b", "vitra/0123abcd"], in: repository)
    try "changed\n".write(to: repository.appendingPathComponent("from-worker.txt"), atomically: true, encoding: .utf8)
    try git(["add", "-A"], in: repository)
    try git(["commit", "-q", "-m", "worker work"], in: repository)
    try git(["checkout", "-q", trunk], in: repository)
    try git(["worktree", "add", "-q", worktree.path, "vitra/0123abcd"], in: repository)

    let run = Run(
        id: "0123abcd",
        spec: WorkerSpec(cli: .claude, model: "haiku", prompt: "go", directory: repository.path, access: .edit),
        state: .finished(exitCode: 0),
        pid: 1,
        started: Date(timeIntervalSince1970: 0),
        ended: Date(timeIntervalSince1970: 12),
        output: WorkerOutput(text: "done", isError: false),
        errorTail: nil,
        repository: repository.path,
        worktree: worktree.path,
        branch: "vitra/0123abcd",
        baseCommit: base
    )

    let report = AgentReport.full(run)
    let lines = report.split(separator: "\n").map(String.init)
    #expect(lines.contains(
        "changes on branch vitra/0123abcd (base \(base.prefix(7))): 1 file changed, 1 insertion(+)"
    ))

    // The report hands the merge to the tool: neither path becomes part of a
    // command line the orchestrator is told to paste into a shell.
    let mergeLine = try #require(lines.first { $0.hasPrefix("merge: ") })
    #expect(mergeLine == "merge: agent_merge 0123abcd")
    #expect(!report.contains("git -C"))
}

/// A worker that writes a file and commits nothing: the shell around it is
/// what is supposed to put the work on the branch.
private let leavesAFile = #"""
cat >/dev/null
printf 'changed\n' > from-worker.txt
echo '{"result":"done","is_error":false}'
"""#

@Test func aCommitARefusingHookRejectsIsReportedAsFailedWithTheEditsLeftInTheWorktree() async throws {
    let fixture = try Fixture(claude: leavesAFile)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)
    // A hook that refuses the shell's commit, saying why.
    let hook = repository.appendingPathComponent(".git/hooks/pre-commit")
    try "#!/bin/sh\necho 'no commits today' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

    let id = try await fixture.spawn(["access": "edit", "directory": .string(repository.path)])
    let report = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])

    // The worker exited zero, and that is still its answer: the commit is the
    // shell's business, not the worker's.
    #expect(report.hasPrefix("[\(id)] finished · "))
    // But the report may not pass the branch off as empty while the edits sit
    // uncommitted in the worktree.
    #expect(report.contains("commit failed: no commits today"))
    #expect(!report.contains("no changes"))
    let tree = fixture.root.appendingPathComponent("runs/\(id)/tree")
    #expect(report.contains("the edits are still uncommitted in \(tree.path)"))
    #expect(FileManager.default.fileExists(atPath: tree.appendingPathComponent("from-worker.txt").path))
    #expect(try !git(["status", "--porcelain"], in: tree).isEmpty)
}

/// An auditor: a read-only worker whose answer is a verdict.
private let audits = #"cat >/dev/null; echo '{"type":"text","part":{"text":"ship"}}'"#

/// The audits started so far, which are the runs tagged for review.
private func reviewRuns(in orchestrator: Orchestrator) -> [Run] {
    orchestrator.recent(limit: 100).filter { $0.spec.kind == .review }
}

@Test func aFinishedEditingDeliveryStartsExactlyOneAudit() async throws {
    let fixture = try Fixture(claude: leavesAFile, opencode: audits)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)

    let id = try await fixture.spawn([
        "access": "edit", "directory": .string(repository.path), "label": "add logout",
    ])
    let report = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    let gate = try #require(report.split(separator: "\n").map(String.init).last)
    #expect(gate.hasPrefix("gate: audit "))
    #expect(gate.contains(
        " by opencode opencode/glm-5.3-flash-free started — agent_wait on it and read its verdict before reviewing yourself."
    ))

    let auditFile = fixture.root.appendingPathComponent("runs/\(id)/audit")
    let auditID = try String(contentsOf: auditFile, encoding: .utf8)
    #expect(auditID.count == 8)
    let started = reviewRuns(in: fixture.orchestrator)
    #expect(started.count == 1)
    #expect(started.first?.id == auditID)
    #expect(started.first?.spec.access == .read)
    #expect(started.first?.spec.label == "auditoria: add logout")
    // The auditor reads the implementer's own worktree, where its commit is.
    #expect(started.first?.spec.directory == fixture.root.appendingPathComponent("runs/\(id)/tree").path)

    // Waiting again reports the audit that exists; it does not start another.
    let again = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 0])
    let againGate = try #require(again.split(separator: "\n").map(String.init).last)
    #expect(againGate.hasPrefix("gate: audit \(auditID) by opencode opencode/glm-5.3-flash-free "))
    #expect(reviewRuns(in: fixture.orchestrator).count == 1)
}

@Test func twoWaitsAtOnceStartExactlyOneAudit() async throws {
    let fixture = try Fixture(claude: leavesAFile, opencode: audits)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)

    let id = try await fixture.spawn(["access": "edit", "directory": .string(repository.path)])
    // Both waits see the same finished delivery at the same time. Only the one
    // that takes the audit claim may spawn an auditor: the other finds it.
    async let first = fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    async let second = fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    let reports = try await [first, second]

    #expect(reports.count == 2)
    #expect(reviewRuns(in: fixture.orchestrator).count == 1)
    let auditID = try String(
        contentsOf: fixture.root.appendingPathComponent("runs/\(id)/audit"), encoding: .utf8
    )
    #expect(auditID.count == 8)
    #expect(reviewRuns(in: fixture.orchestrator).first?.id == auditID)
}

/// An auditor that keeps reading: enough to see the report while it holds the
/// worktree.
private let keepsReading = #"cat >/dev/null; sleep 30"#

@Test func theReportDoesNotOfferToRemoveTheWorktreeWhileTheAuditReadsIt() async throws {
    let fixture = try Fixture(claude: leavesAFile, opencode: keepsReading)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)

    let id = try await fixture.spawn(["access": "edit", "directory": .string(repository.path)])
    let started = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    let auditID = try String(
        contentsOf: fixture.root.appendingPathComponent("runs/\(id)/audit"), encoding: .utf8
    )
    #expect(started.contains("merge after the audit: \(auditID) is reading this worktree"))
    #expect(!started.contains("worktree remove"))

    let again = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 0])
    #expect(again.contains("merge after the audit: \(auditID) is reading this worktree"))
    #expect(!again.contains("worktree remove"))

    // Once the auditor has stopped, the merge line is back.
    _ = try await fixture.call("agent_cancel", ["id": .string(auditID)])
    let stopped = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 0])
    #expect(stopped.contains("merge: agent_merge \(id)"))
    #expect(!stopped.contains("merge after the audit:"))
}

@Test func aDiffThatCannotBeReadStartsNoAuditor() async throws {
    let fixture = try Fixture(claude: leavesAFile, opencode: audits)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)
    // A diff program that does not exist makes `git diff` fail, while the
    // branch and its commit are still readable.
    try git(["config", "diff.external", "/no/such/vitra-diff"], in: repository)

    let id = try await fixture.spawn(["access": "edit", "directory": .string(repository.path)])
    let report = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])

    #expect(report.contains("gate: no audit — could not read the diff: "))
    #expect(report.contains("external diff died") || report.contains("No such file"))
    #expect(reviewRuns(in: fixture.orchestrator).isEmpty)
    #expect(!FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("runs/\(id)/audit").path
    ))
    // With no auditor reading it, the worktree is the orchestrator's to merge
    // and remove.
    #expect(report.contains("merge: agent_merge \(id)"))
}

@Test func aDeliveryWithNoCommitsStartsNoAudit() async throws {
    // The worker ran and exited clean, but its branch is the base it started
    // from: there is no change for anyone to read.
    let fixture = try Fixture(claude: answers, opencode: audits)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)

    let id = try await fixture.spawn(["access": "edit", "directory": .string(repository.path)])
    let report = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])

    #expect(report.contains("no changes"))
    #expect(!report.contains("gate:"))
    #expect(reviewRuns(in: fixture.orchestrator).isEmpty)
    #expect(!FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("runs/\(id)/audit").path
    ))
}

@Test func aRunSpawnedWithAuditFalseIsNotAudited() async throws {
    let fixture = try Fixture(claude: leavesAFile, opencode: audits)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)

    let id = try await fixture.spawn([
        "access": "edit", "directory": .string(repository.path), "audit": false,
    ])
    let report = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])

    #expect(report.contains("changes on branch"))
    #expect(!report.contains("gate:"))
    #expect(reviewRuns(in: fixture.orchestrator).isEmpty)
}

@Test func aDeliveryWithNoAuditorAvailableIsSaidInTheReportNotAsAFailure() async throws {
    // Only the implementer's own CLI is installed, and it may not audit itself.
    let fixture = try Fixture(claude: leavesAFile)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)

    let id = try await fixture.spawn(["access": "edit", "directory": .string(repository.path)])
    let report = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])

    #expect(report.hasPrefix("[\(id)] finished · "))
    #expect(report.hasSuffix(
        "gate: no auditor from another provider is available — review this delivery yourself."
    ))
}

/// A worker that rewrites a file the trunk goes on to change too: a conflict.
private let rewritesReadme = #"""
cat >/dev/null
printf 'worker\n' > README
echo '{"result":"done","is_error":false}'
"""#

@Test func agentMergePutsTheBranchOnTheCheckoutAndCleansUp() async throws {
    let fixture = try Fixture(claude: leavesAFile)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    let (base, trunk) = try makeRepository(at: repository)

    let id = try await fixture.spawn([
        "access": "edit", "directory": .string(repository.path), "audit": false,
    ])
    _ = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    let tree = fixture.root.appendingPathComponent("runs/\(id)/tree")
    #expect(FileManager.default.fileExists(atPath: tree.path))

    let result = try await fixture.call("agent_merge", ["id": .string(id)])
    // The merge is reported with the commit it left and what it changed.
    // (git answers with the repository's real path, which /var symlinks hide.)
    let top = try git(["rev-parse", "--show-toplevel"], in: repository)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(result.contains("Merged vitra/\(id) into the checkout at \(top): "))
    #expect(result.contains("1 file changed, 1 insertion(+)"))
    #expect(result.contains("Removed worktree \(tree.path)."))
    #expect(result.contains("Deleted branch vitra/\(id)."))

    // The work is on the trunk the repository had checked out, and the
    // worktree and branch are gone.
    #expect(try String(contentsOf: repository.appendingPathComponent("from-worker.txt"), encoding: .utf8) == "changed\n")
    #expect(try git(["rev-parse", "--verify", "HEAD"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines) != base)
    #expect(try git(["symbolic-ref", "--short", "HEAD"], in: repository)
        .trimmingCharacters(in: .whitespacesAndNewlines) == trunk)
    #expect(try git(["branch", "--list", "vitra/\(id)"], in: repository)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: tree.path))
}

@Test func aConflictingMergeIsAbortedAndLeavesTheWorkInPlace() async throws {
    let fixture = try Fixture(claude: rewritesReadme)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)
    let id = try await fixture.spawn([
        "access": "edit", "directory": .string(repository.path), "audit": false,
    ])
    _ = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    let tree = fixture.root.appendingPathComponent("runs/\(id)/tree")
    // The trunk moves after the worker's branch was made: both change README.
    try "trunk\n".write(to: repository.appendingPathComponent("README"), atomically: true, encoding: .utf8)
    try git(["add", "-A"], in: repository)
    try git(["commit", "-q", "-m", "trunk work"], in: repository)

    do {
        _ = try await fixture.call("agent_merge", ["id": .string(id)])
        Issue.record("the merge should have conflicted")
    } catch let error as ToolError {
        #expect(error.message.contains("merge of vitra/\(id) conflicts: README"))
        #expect(error.message.contains("still there"))
    }

    // Aborted, not half-merged: the checkout holds the trunk's README, and
    // the worktree and branch are still there for the work to go back.
    #expect(try String(contentsOf: repository.appendingPathComponent("README"), encoding: .utf8) == "trunk\n")
    #expect(try git(["status", "--porcelain"], in: repository).isEmpty)
    #expect(FileManager.default.fileExists(atPath: tree.path))
    #expect(try !git(["branch", "--list", "vitra/\(id)"], in: repository)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test func agentMergeDiscardDropsTheBranchWithoutMergingIt() async throws {
    let fixture = try Fixture(claude: leavesAFile)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)
    let id = try await fixture.spawn([
        "access": "edit", "directory": .string(repository.path), "audit": false,
    ])
    _ = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    let tree = fixture.root.appendingPathComponent("runs/\(id)/tree")

    let result = try await fixture.call("agent_merge", ["id": .string(id), "discard": true])
    #expect(result.hasPrefix("Discarded agent \(id): vitra/\(id) was not merged."))
    #expect(result.contains("Removed worktree \(tree.path)."))
    #expect(result.contains("Deleted branch vitra/\(id)."))
    #expect(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("from-worker.txt").path))
    #expect(try git(["branch", "--list", "vitra/\(id)"], in: repository)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: tree.path))
}

@Test func agentMergeRefusesAnAgentThatIsStillRunning() async throws {
    let fixture = try Fixture(claude: "cat >/dev/null; sleep 30")
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)
    let id = try await fixture.spawn([
        "access": "edit", "directory": .string(repository.path), "audit": false,
    ])

    do {
        _ = try await fixture.call("agent_merge", ["id": .string(id)])
        Issue.record("a running agent should not be merged")
    } catch let error as ToolError {
        #expect(error.message.contains("agent \(id) is still running"))
    }
    _ = try await fixture.call("agent_cancel", ["id": .string(id)])
}

@Test func agentMergeRefusesWhileItsAuditIsStillReadingTheWorktree() async throws {
    let fixture = try Fixture(claude: leavesAFile, opencode: keepsReading)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)
    let id = try await fixture.spawn(["access": "edit", "directory": .string(repository.path)])
    _ = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    let auditID = try String(
        contentsOf: fixture.root.appendingPathComponent("runs/\(id)/audit"), encoding: .utf8
    )
    let tree = fixture.root.appendingPathComponent("runs/\(id)/tree")

    do {
        _ = try await fixture.call("agent_merge", ["id": .string(id)])
        Issue.record("a worktree being audited should not be merged")
    } catch let error as ToolError {
        #expect(error.message == "the audit \(auditID) is still reading this worktree; agent_wait on it first")
    }
    #expect(FileManager.default.fileExists(atPath: tree.path))

    // A claim another wait has just taken has no auditor id to name yet, and
    // is refused just the same.
    _ = try await fixture.call("agent_cancel", ["id": .string(auditID)])
    try "pending".write(
        to: fixture.root.appendingPathComponent("runs/\(id)/audit"), atomically: true, encoding: .utf8
    )
    do {
        _ = try await fixture.call("agent_merge", ["id": .string(id)])
        Issue.record("a pending audit should not be merged")
    } catch let error as ToolError {
        #expect(error.message == "an audit is still reading this worktree; agent_wait on it first")
    }
}

@Test func agentMergeRefusesACheckoutWithUncommittedTrackedChanges() async throws {
    let fixture = try Fixture(claude: leavesAFile)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)
    let id = try await fixture.spawn([
        "access": "edit", "directory": .string(repository.path), "audit": false,
    ])
    _ = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    let tree = fixture.root.appendingPathComponent("runs/\(id)/tree")
    // The user's own uncommitted work in the checkout is not to be stashed
    // or merged over: the merge waits for it to be committed.
    try "dirty\n".write(to: repository.appendingPathComponent("README"), atomically: true, encoding: .utf8)

    do {
        _ = try await fixture.call("agent_merge", ["id": .string(id)])
        Issue.record("a dirty checkout should not be merged into")
    } catch let error as ToolError {
        #expect(error.message.contains("has uncommitted changes to tracked files"))
    }
    #expect(try String(contentsOf: repository.appendingPathComponent("README"), encoding: .utf8) == "dirty\n")
    #expect(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("from-worker.txt").path))
    #expect(FileManager.default.fileExists(atPath: tree.path))
    #expect(try !git(["branch", "--list", "vitra/\(id)"], in: repository)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test func agentMergeRefusesADeliveryWhoseCommitFailed() async throws {
    let fixture = try Fixture(claude: leavesAFile)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)
    // A hook that refuses the shell's commit: the worker's edits stay in the
    // worktree, uncommitted.
    let hook = repository.appendingPathComponent(".git/hooks/pre-commit")
    try "#!/bin/sh\necho 'no commits today' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

    let id = try await fixture.spawn([
        "access": "edit", "directory": .string(repository.path), "audit": false,
    ])
    let report = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    #expect(report.contains("commit failed: no commits today"))
    let tree = fixture.root.appendingPathComponent("runs/\(id)/tree")

    do {
        _ = try await fixture.call("agent_merge", ["id": .string(id)])
        Issue.record("a delivery whose commit failed should not be merged")
    } catch let error as ToolError {
        #expect(error.message.contains("the edits are still uncommitted in \(tree.path)"))
    }

    // Removing the worktree with --force would have deleted the edits: the
    // work, the worktree and the branch are all still there, and nothing was
    // merged.
    #expect(FileManager.default.fileExists(atPath: tree.appendingPathComponent("from-worker.txt").path))
    #expect(FileManager.default.fileExists(atPath: tree.path))
    #expect(try !git(["branch", "--list", "vitra/\(id)"], in: repository)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("from-worker.txt").path))
}

@Test func agentMergeRefusesAWorktreeWithUncommittedEdits() async throws {
    let fixture = try Fixture(claude: leavesAFile)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)
    let id = try await fixture.spawn([
        "access": "edit", "directory": .string(repository.path), "audit": false,
    ])
    _ = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    let tree = fixture.root.appendingPathComponent("runs/\(id)/tree")
    // An edit made after the shell's commit: still uncommitted when the merge
    // would remove the worktree with --force.
    try "late\n".write(to: tree.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)

    do {
        _ = try await fixture.call("agent_merge", ["id": .string(id)])
        Issue.record("a worktree with uncommitted edits should not be merged")
    } catch let error as ToolError {
        #expect(error.message.contains("edits still uncommitted in \(tree.path)"))
    }

    #expect(FileManager.default.fileExists(atPath: tree.appendingPathComponent("late.txt").path))
    #expect(FileManager.default.fileExists(atPath: tree.path))
    #expect(try !git(["branch", "--list", "vitra/\(id)"], in: repository)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("from-worker.txt").path))
}

@Test func agentMergeRefusesACheckoutThatIsAlreadyMerging() async throws {
    let fixture = try Fixture(claude: rewritesReadme)
    defer { fixture.cleanUp() }
    let repository = fixture.root.appendingPathComponent("repo")
    try makeRepository(at: repository)
    let id = try await fixture.spawn([
        "access": "edit", "directory": .string(repository.path), "audit": false,
    ])
    _ = try await fixture.call("agent_wait", ["ids": [.string(id)], "timeout_seconds": 10])
    let tree = fixture.root.appendingPathComponent("runs/\(id)/tree")

    // The user's own merge is under way and conflicts, so it is left open.
    try "trunk\n".write(to: repository.appendingPathComponent("README"), atomically: true, encoding: .utf8)
    try git(["add", "-A"], in: repository)
    try git(["commit", "-q", "-m", "trunk work"], in: repository)
    _ = try? git(["merge", "vitra/\(id)"], in: repository)
    #expect(try !git(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repository)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

    do {
        _ = try await fixture.call("agent_merge", ["id": .string(id)])
        Issue.record("a checkout already in a merge should not be merged into")
    } catch let error as ToolError {
        #expect(error.message.contains("already in the middle of a merge"))
    }

    // The other merge is left exactly as it was: neither finished nor aborted
    // by this call, and the worker's worktree and branch are still there.
    #expect(try !git(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repository)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(try git(["status", "--porcelain"], in: repository).contains("UU README"))
    #expect(FileManager.default.fileExists(atPath: tree.path))
    #expect(try !git(["branch", "--list", "vitra/\(id)"], in: repository)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        "agent_spawn", "agent_wait", "agent_list", "agent_cancel", "agent_merge", "agent_models", "agent_rate", "agent_scores",
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

@Test func aRealCursorListingKeepsEveryGrokBeyondTheFirstLines() {
    var lines = ["Available models", "", "auto - Auto (default)"]
    lines += (1...120).map { "model-\($0) - Model \($0)" }
    lines += ["cursor-grok-4.5-low - Grok 4.5 Low", "cursor-grok-4.6-low-fast - Grok 4.6 Low Fast\u{200B}", "grok-4.7-low-fast - Grok 4.7  Low Fast\u{200B}"]
    let parsed = ModelCatalog.modelLines(lines.joined(separator: "\n"))
    #expect(parsed.count == lines.count - 1)
    let summary = ModelCatalog.summary(ModelCatalog.Listing(claude: false, openCode: nil, gemini: nil, cursor: parsed))
    #expect(summary.contains("cursor-grok-4.5-low, cursor-grok-4.6-low-fast, grok-4.7-low-fast"))
    #expect(ModelCatalog.isGrok("cursor-grok-4.6-low-fast"))
}
