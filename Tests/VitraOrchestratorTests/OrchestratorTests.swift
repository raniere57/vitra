import Foundation
import Testing
@testable import VitraOrchestrator

/// A scratch directory holding a runs root, a project, and fake CLIs.
///
/// The fakes are shell scripts standing in for `claude` and `opencode`: the
/// real ones cost money and a network round trip, and what is under test here
/// is the spawning and bookkeeping around them, not the models.
private struct Sandbox {
    let root: URL
    let project: URL

    init() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-orch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent("project"),
            withIntermediateDirectories: true
        )
        // The physical path, as `pwd` in a worker prints it: the temporary
        // directory sits behind the /var symlink, which Foundation leaves alone.
        let physical = try #require(realpath(scratch.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical))
        project = root.appendingPathComponent("project")
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// An orchestrator whose `claude` is the given shell script.
    func orchestrator(claude script: String) throws -> Orchestrator {
        let path = root.appendingPathComponent("fake-claude")
        try ("#!/bin/sh\n" + script + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return Orchestrator(
            root: root.appendingPathComponent("runs"),
            executables: Executables(paths: [.claude: path.path])
        )
    }

    func spec(prompt: String = "say done", access: WorkerAccess = .read) -> WorkerSpec {
        WorkerSpec(cli: .claude, model: "haiku", prompt: prompt, directory: project.path, access: access, effort: "low")
    }
}

private let answersDone = #"""
cat > got-prompt.txt
pwd > got-pwd.txt
echo "$@" > got-args.txt
echo '{"result":"done","is_error":false,"total_cost_usd":0.5,"usage":{"input_tokens":5,"output_tokens":2},"session_id":"s1"}'
"""#

@Test func aWorkerRunsInItsDirectoryWithThePromptOnStdin() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: answersDone)

    let id = try orchestrator.spawn(sandbox.spec(prompt: "--not-a-flag\nsecond line"))
    let run = try #require(try await orchestrator.wait(ids: [id], timeout: 10).first)

    #expect(run.state == .finished(exitCode: 0))
    #expect(run.output?.text == "done")
    #expect(run.output?.costUSD == 0.5)
    let read = { (name: String) in
        try String(contentsOf: sandbox.project.appendingPathComponent(name), encoding: .utf8)
    }
    #expect(try read("got-prompt.txt") == "--not-a-flag\nsecond line")
    #expect(try read("got-pwd.txt") == sandbox.project.path + "\n")
    #expect(try read("got-args.txt") == "-p --model haiku --output-format json --effort low\n")
}

@Test func aCLIThatTakesItsPromptAsAnArgumentGetsItWholeAfterTheOptions() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let fake = sandbox.root.appendingPathComponent("fake-cursor")
    // Writes each argument on a line of its own, and what stdin holds.
    try #"""
    #!/bin/sh
    for argument in "$@"; do printf '[%s]\n' "$argument"; done > got-args.txt
    cat > got-stdin.txt
    echo '{"type":"result","is_error":false,"result":"done","session_id":"c"}'
    """#.write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let orchestrator = Orchestrator(
        root: sandbox.root.appendingPathComponent("runs"),
        executables: Executables(paths: [.cursor: fake.path])
    )

    let prompt = "--force this: it's \"quoted\", $HOME and `backticks`\nsecond line"
    let id = try orchestrator.spawn(
        WorkerSpec(cli: .cursor, model: "grok-4.7-low", prompt: prompt, directory: sandbox.project.path)
    )
    let run = try #require(try await orchestrator.wait(ids: [id], timeout: 10).first)

    #expect(run.output?.text == "done")
    let read = { (name: String) in
        try String(contentsOf: sandbox.project.appendingPathComponent(name), encoding: .utf8)
    }
    // One argument, exactly as written, after the `--`: nothing in it was
    // expanded by the shell or taken for a flag.
    #expect(try read("got-args.txt") == "[-p]\n[--model]\n[grok-4.7-low]\n[--output-format]\n[json]\n[--mode]\n[ask]\n[--trust]\n[--]\n[\(prompt)]\n")
    #expect(try read("got-stdin.txt").isEmpty)
}

@Test func aDeliveryCanBeRatedAndTheRatingStaysWithTheRun() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: answersDone)

    let id = try orchestrator.spawn(sandbox.spec())
    _ = try await orchestrator.wait(ids: [id], timeout: 10)
    #expect(try orchestrator.status(id).rating == nil)

    try orchestrator.rate(id, score: 4, note: "  right, but left a TODO behind\n")
    let rating = try #require(try orchestrator.status(id).rating)
    #expect(rating.score == 4)
    #expect(rating.note == "right, but left a TODO behind")
    #expect(orchestrator.recent(limit: 5).first?.rating?.score == 4)

    // A second look replaces the first: the last verdict is the one that counts.
    try orchestrator.rate(id, score: 2, note: nil)
    #expect(try orchestrator.status(id).rating?.score == 2)
    #expect(try orchestrator.status(id).rating?.note == nil)
}

@Test func onlyARealDeliveryCanBeRatedAndOnlyFromOneToFive() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: "cat >/dev/null; sleep 30")

    let id = try orchestrator.spawn(sandbox.spec())
    // Nothing has been delivered yet.
    #expect(throws: OrchestratorError.self) { try orchestrator.rate(id, score: 5, note: nil) }
    try orchestrator.cancel(id)

    for score in [0, 6, -1] {
        #expect(throws: OrchestratorError.self) { try orchestrator.rate(id, score: score, note: nil) }
    }
    #expect(throws: OrchestratorError.unknownRun("../../etc")) { try orchestrator.rate("../../etc", score: 3, note: nil) }
    #expect(try orchestrator.status(id).rating == nil)
}

@Test func aWorkerThatExitsNonZeroIsFinishedAndAnError() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: "cat >/dev/null; echo boom >&2; exit 3")

    let id = try orchestrator.spawn(sandbox.spec())
    let run = try #require(try await orchestrator.wait(ids: [id], timeout: 10).first)

    #expect(run.state == .finished(exitCode: 3))
    #expect(run.output?.isError == true)
    #expect(run.errorTail == "boom")
    // It printed nothing on stdout, so what it said on stderr is its answer.
    #expect(run.output?.text == "boom")
}

@Test func aZeroExitDoesNotHideAnErrorTheCLIReported() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(
        claude: #"cat >/dev/null; echo '{"result":"rate limited","is_error":true}'"#
    )

    let id = try orchestrator.spawn(sandbox.spec())
    let run = try #require(try await orchestrator.wait(ids: [id], timeout: 10).first)

    #expect(run.output?.isError == true)
    #expect(run.output?.text == "rate limited")
}

@Test func waitingGivesUpAtTheTimeoutAndReportsTheWorkerStillRunning() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: "cat >/dev/null; sleep 30")

    let id = try orchestrator.spawn(sandbox.spec())
    let started = Date()
    let run = try #require(try await orchestrator.wait(ids: [id], timeout: 0.5).first)

    #expect(run.state == .running)
    #expect(run.output == nil)
    #expect(Date().timeIntervalSince(started) < 5)
    try orchestrator.cancel(id)
}

/// Whether a process with this pid exists.
private func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

/// Whether `pid` goes away within a few seconds.
///
/// Not asked once: a killed process lingers as a zombie until its parent
/// collects it, and for a worker's orphaned children that parent is launchd,
/// on its own schedule. A zombie runs nothing, but it still has a pid.
private func isGone(_ pid: Int32) async throws -> Bool {
    for _ in 0..<200 {
        if !isAlive(pid) { return true }
        try await Task.sleep(for: .milliseconds(25))
    }
    return false
}

/// Reads a pid a fake worker wrote into the project, once it has.
private func pid(in file: URL) async throws -> Int32 {
    for _ in 0..<200 {
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw OrchestratorError.spawnFailed("the fake worker never wrote \(file.lastPathComponent)")
}

/// A worker that starts a process of its own, as the real CLIs do, and says
/// which pids the two of them have.
private let startsAChild = #"""
cat >/dev/null
echo $$ > worker.pid.tmp && mv worker.pid.tmp worker.pid
sleep 30 &
echo $! > child.pid.tmp && mv child.pid.tmp child.pid
wait
"""#

@Test func aCancelledWorkerStopsAlongWithEverythingItStarted() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: startsAChild)

    let id = try orchestrator.spawn(sandbox.spec())
    let worker = try await pid(in: sandbox.project.appendingPathComponent("worker.pid"))
    let child = try await pid(in: sandbox.project.appendingPathComponent("child.pid"))
    #expect(isAlive(worker) && isAlive(child))

    try orchestrator.cancel(id)

    #expect(try orchestrator.status(id).state == .cancelled)
    // Killing only the shell would leave both of these running: they are what
    // a signal to the whole group, and nothing less, takes down.
    #expect(try await isGone(worker))
    #expect(try await isGone(child))
}

@Test func aWorkerKilledFromOutsideIsLostNotRunningForEver() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: startsAChild)

    let id = try orchestrator.spawn(sandbox.spec())
    _ = try await pid(in: sandbox.project.appendingPathComponent("child.pid"))
    let leader = try #require(try orchestrator.status(id).pid)
    kill(-leader, SIGKILL)

    let run = try #require(try await orchestrator.wait(ids: [id], timeout: 5).first)
    #expect(run.state == .lost)
    #expect(run.output == nil)
}

@Test func aFinishedRunKeepsItsAnswerEvenIfACancelLandedJustAfter() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: answersDone)

    let id = try orchestrator.spawn(sandbox.spec())
    _ = try await orchestrator.wait(ids: [id], timeout: 10)
    // What a cancel that lost the race with the worker's exit leaves behind.
    let marker = sandbox.root.appendingPathComponent("runs/\(id)/cancelled")
    #expect(FileManager.default.createFile(atPath: marker.path, contents: nil))

    let run = try orchestrator.status(id)
    #expect(run.state == .finished(exitCode: 0))
    #expect(run.output?.text == "done")
}

@Test func aWorkerRecordedAsKilledByTheCancelIsCancelledNotFailed() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    // What is left when the recording shell outlives the worker it was
    // cancelled with: the marker, and an exit code saying "died of SIGTERM".
    let orchestrator = try sandbox.orchestrator(claude: "cat >/dev/null; exit 143")

    let id = try orchestrator.spawn(sandbox.spec())
    _ = try await orchestrator.wait(ids: [id], timeout: 10)
    #expect(try orchestrator.status(id).state == .finished(exitCode: 143))

    let marker = sandbox.root.appendingPathComponent("runs/\(id)/cancelled")
    #expect(FileManager.default.createFile(atPath: marker.path, contents: nil))
    let run = try orchestrator.status(id)
    #expect(run.state == .cancelled)
    #expect(run.output == nil)
}

@Test func aRecordWhosePidCouldNotBeAWorkersIsNotARun() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: "cat >/dev/null; sleep 30")

    let id = try orchestrator.spawn(sandbox.spec())
    let real = try #require(try orchestrator.status(id).pid)
    defer { kill(-real, SIGKILL) }

    // The pid ends up negated in kill(): 0 is this process's own group, 1 is
    // every process the user owns, and a negative one is some single process.
    // None of them may ever be signalled on the word of a file.
    let record = sandbox.root.appendingPathComponent("runs/\(id)/run.json")
    let original = try String(contentsOf: record, encoding: .utf8)
    for pid in [0, 1, -1, -real] {
        let tampered = original.replacingOccurrences(of: "\"pid\":\(real)", with: "\"pid\":\(pid)")
        #expect(tampered != original)
        try tampered.write(to: record, atomically: true, encoding: .utf8)

        #expect(throws: OrchestratorError.unknownRun(id)) { try orchestrator.status(id) }
        #expect(throws: OrchestratorError.unknownRun(id)) { try orchestrator.cancel(id) }
        #expect(orchestrator.recent(limit: 10).isEmpty)
    }
    #expect(isAlive(real))
}

@Test func aPidThatNowBelongsToSomethingElseIsNeverSignalled() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: "cat >/dev/null; sleep 30")

    // Two live workers; the record of the first is pointed at the second's
    // pid, which is what a recycled pid looks like: a real process group, but
    // one that started at another time than the record says.
    let first = try orchestrator.spawn(sandbox.spec())
    try await Task.sleep(for: .milliseconds(50))
    let second = try orchestrator.spawn(sandbox.spec())
    let firstPid = try #require(try orchestrator.status(first).pid)
    let secondPid = try #require(try orchestrator.status(second).pid)
    defer { kill(-firstPid, SIGKILL) }

    let record = sandbox.root.appendingPathComponent("runs/\(first)/run.json")
    let original = try String(contentsOf: record, encoding: .utf8)
    try original
        .replacingOccurrences(of: "\"pid\":\(firstPid)", with: "\"pid\":\(secondPid)")
        .write(to: record, atomically: true, encoding: .utf8)

    #expect(try orchestrator.status(first).state == .lost)
    try orchestrator.cancel(first)
    #expect(isAlive(secondPid))
    #expect(try orchestrator.status(second).state == .running)
    try orchestrator.cancel(second)
}

@Test func whatARunLeavesOnDiskIsTheUsersAlone() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: answersDone)

    let id = try orchestrator.spawn(sandbox.spec())
    _ = try await orchestrator.wait(ids: [id], timeout: 10)

    for path in ["runs", "runs/\(id)"] {
        let attributes = try FileManager.default.attributesOfItem(atPath: sandbox.root.appendingPathComponent(path).path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
    }
}

@Test func outputThatIsNotValidTextIsStillRead() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    // A worker cut off in the middle of a multi-byte character.
    let orchestrator = try sandbox.orchestrator(claude: #"cat >/dev/null; printf 'half \303'; printf 'why \303' >&2; exit 1"#)

    let id = try orchestrator.spawn(sandbox.spec())
    let run = try #require(try await orchestrator.wait(ids: [id], timeout: 10).first)

    #expect(run.output?.text.hasPrefix("half") == true)
    #expect(run.errorTail?.hasPrefix("why") == true)
}

@Test func cancellingAFinishedWorkerLeavesItsResultAlone() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: answersDone)

    let id = try orchestrator.spawn(sandbox.spec())
    _ = try await orchestrator.wait(ids: [id], timeout: 10)
    try orchestrator.cancel(id)

    #expect(try orchestrator.status(id).state == .finished(exitCode: 0))
}

@Test func severalWorkersRunAtOnceAndComeBackInTheOrderAsked() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    // Each worker announces itself and then refuses to answer until all three
    // have. Run one after another, the first would wait for ever: that they
    // finish at all is the proof they overlapped, with no clock involved.
    let orchestrator = try sandbox.orchestrator(claude: #"""
    prompt=$(cat)
    touch "here-$prompt"
    until [ -e here-one ] && [ -e here-two ] && [ -e here-three ]; do sleep 0.05; done
    echo "{\"result\":\"$prompt\",\"is_error\":false}"
    """#)

    let ids = try ["one", "two", "three"].map { try orchestrator.spawn(sandbox.spec(prompt: $0)) }
    let runs = try await orchestrator.wait(ids: ids, timeout: 20)
    for run in runs where run.state == .running { try orchestrator.cancel(run.id) }

    #expect(runs.map(\.id) == ids)
    #expect(runs.map { $0.output?.text } == ["one", "two", "three"])
}

@Test func recentListsTheNewestRunFirst() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: answersDone)

    let first = try orchestrator.spawn(sandbox.spec(prompt: "first"))
    try await Task.sleep(for: .milliseconds(20))
    let second = try orchestrator.spawn(sandbox.spec(prompt: "second"))
    _ = try await orchestrator.wait(ids: [first, second], timeout: 10)

    #expect(orchestrator.recent(limit: 10).map(\.id) == [second, first])
    #expect(orchestrator.recent(limit: 1).map(\.id) == [second])
}

@Test func anIdThatIsNotOneOfOursNeverTouchesTheFilesystem() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = try sandbox.orchestrator(claude: answersDone)

    // Ids arrive from a model. One that walks out of the runs directory must be
    // refused as malformed, not looked up.
    for id in ["../../etc", "", "abc", "ABCDEFGH", "abcdefg/", "0123456789"] {
        #expect(throws: OrchestratorError.unknownRun(id)) { try orchestrator.status(id) }
        #expect(throws: OrchestratorError.unknownRun(id)) { try orchestrator.cancel(id) }
    }
    #expect(throws: OrchestratorError.unknownRun("0123abcd")) { try orchestrator.status("0123abcd") }
}

@Test func aCLIThatIsNotInstalledIsReportedByName() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let orchestrator = Orchestrator(root: sandbox.root.appendingPathComponent("runs"), executables: Executables(paths: [:]))

    #expect(throws: OrchestratorError.executableNotFound(.claude)) { try orchestrator.spawn(sandbox.spec()) }
}

@Test func theOpenCodeBundledWithItsAppIsPreferredOverTheOneOnThePath() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let bin = sandbox.root.appendingPathComponent("bin")
    let app = sandbox.root.appendingPathComponent("OpenCode.app/Contents/Resources")
    for directory in [bin, app] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let executable = { (url: URL) in
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    try executable(bin.appendingPathComponent("claude"))
    try executable(bin.appendingPathComponent("opencode"))

    let onPathOnly = Executables.discover(searchPath: bin.path, openCodeApp: app.path + "/opencode-cli")
    #expect(onPathOnly.paths == [
        .claude: bin.path + "/claude",
        .opencode: bin.path + "/opencode",
    ])

    // The other two are found by the names they install under.
    try executable(bin.appendingPathComponent("agy"))
    try executable(bin.appendingPathComponent("cursor-agent"))
    let all = Executables.discover(searchPath: bin.path, openCodeApp: app.path + "/opencode-cli")
    #expect(all.paths[.gemini] == bin.path + "/agy")
    #expect(all.paths[.cursor] == bin.path + "/cursor-agent")

    // The app migrates the shared database to its own schema; a CLI older than
    // the app then refuses to open it. The one inside the app always matches.
    try executable(app.appendingPathComponent("opencode-cli"))
    let withApp = Executables.discover(searchPath: bin.path, openCodeApp: app.path + "/opencode-cli")
    #expect(withApp.paths[.opencode] == app.path + "/opencode-cli")
}
