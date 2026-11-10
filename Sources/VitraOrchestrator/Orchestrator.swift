import Foundation

/// Spawns worker agents and keeps track of them.
///
/// All state lives on disk, one directory per run:
///
///     <root>/<id>/run.json    what was asked, when, and the pid
///     <root>/<id>/prompt      the worker's stdin
///     <root>/<id>/stdout      what the CLI printed, in its JSON mode
///     <root>/<id>/stderr
///     <root>/<id>/exit        the exit code, once the worker is done
///     <root>/<id>/cancelled   present when the run was cancelled
///     <root>/<id>/rating.json the orchestrator's verdict on the delivery
///
/// There is no daemon. The process that spawns a worker is `vitra mcp`, which
/// lives only as long as the session that started it, so nothing in memory can
/// be the record of a run: the worker outlives its spawner, and a later
/// process — another `vitra mcp`, the app — reads the same directory and sees
/// the same thing.
public struct Orchestrator: Sendable {
    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".vitra/runs")
    }

    private static let pollInterval: Duration = .milliseconds(100)
    private static let errorTailLength = 2000
    /// How long a cancelled worker is given to stop before it is killed outright.
    private static let terminationGrace: TimeInterval = 2
    private static let idAttempts = 5
    /// What a shell reports for a child killed by the signals `cancel` sends:
    /// 128 plus SIGTERM, and 128 plus SIGKILL.
    private static let cancelExitCodes: Set<Int32> = [128 + SIGTERM, 128 + SIGKILL]

    private let root: URL
    private let executables: Executables
    private let browserConfig: String?

    /// `browserConfig` is the MCP configuration that hands workers Vitra's
    /// browser. Left out, it is the one the app installed — for the real run
    /// store only, so a test's workers are not given the user's browser.
    public init(
        root: URL = Orchestrator.defaultRoot,
        executables: Executables = .discover(),
        browserConfig: String? = nil
    ) {
        self.root = root
        self.executables = executables
        self.browserConfig = browserConfig ?? (root == Orchestrator.defaultRoot ? Self.installedBrowserConfig : nil)
    }

    // MARK: - Spawning

    /// Starts a worker and returns its id without waiting for it.
    @discardableResult
    public func spawn(_ spec: WorkerSpec) throws(OrchestratorError) -> String {
        try spec.validate()
        guard let executable = executables.paths[spec.cli] else { throw .executableNotFound(spec.cli) }

        let (id, directory) = try makeRunDirectory()
        do {
            try Data(spec.prompt.utf8).write(to: directory.appendingPathComponent("prompt"))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw .spawnFailed("\(error.localizedDescription)")
        }

        // The shell is there for two things the worker cannot do for itself:
        // point its three streams at files, and write its exit code down once
        // it is gone. The code is written to a temporary name and moved into
        // place so a reader never sees a half-written file.
        //
        // The prompt reaches the worker on stdin where the CLI reads it there,
        // and otherwise as one last argument. Either way it comes out of a
        // file: it is never spliced into this script, so nothing in it is
        // expanded or run by the shell.
        let run = spec.cli.takesPromptOnStdin
            ? #""$@" <"$VITRA_RUN/prompt""#
            : #""$@" "$VITRA_PROMPT_FLAG$(cat "$VITRA_RUN/prompt")" </dev/null"#
        let script = """
        \(run) >"$VITRA_RUN/stdout" 2>"$VITRA_RUN/stderr"
        echo $? >"$VITRA_RUN/exit.tmp" && mv "$VITRA_RUN/exit.tmp" "$VITRA_RUN/exit"
        """
        let environment = Self.workerEnvironment(from: ProcessInfo.processInfo.environment)
            // VITRA_AGENT is who the worker is to Vitra's browser: the tab it
            // opens there is filed under its run.
            .merging([
                "VITRA_RUN": directory.path, "VITRA_AGENT": id, "VITRA_PROMPT_FLAG": spec.cli.promptFlag ?? "",
            ]) { _, new in new }

        let pid: pid_t
        do {
            pid = try Self.launch(
                ["/bin/sh", "-c", script, "vitra-worker", executable] + spec.arguments(browserConfig: browserConfig),
                environment: environment,
                directory: spec.directory
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        do {
            let record = RunRecord(spec: spec, started: Date(), pid: pid, leaderStarted: Self.processStart(pid))
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("run.json"), options: .atomic)
        } catch {
            // A worker with no record could never be found or cancelled again,
            // and it may be one that edits. It does not get to run.
            kill(-pid, SIGKILL)
            try? FileManager.default.removeItem(at: directory)
            throw .spawnFailed("\(error.localizedDescription)")
        }
        return id
    }

    /// Creates the directory of a new run and returns it with its id.
    ///
    /// Prompts and answers can hold anything the user's project holds, so the
    /// directories are the user's alone. The run's own directory is created
    /// exclusively: an id that is already taken is drawn again rather than
    /// shared, since sharing would hand one run the other's files.
    private func makeRunDirectory() throws(OrchestratorError) -> (id: String, directory: URL) {
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        var failure = "could not create a run directory"
        for _ in 0..<Self.idAttempts {
            let id = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
            let directory = root.appendingPathComponent(id)
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: ownerOnly)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: ownerOnly)
                return (id, directory)
            } catch {
                failure = error.localizedDescription
            }
        }
        throw .spawnFailed(failure)
    }

    /// The environment a worker runs in: the spawner's, minus what would tie
    /// the worker to the spawner's own Claude session.
    ///
    /// The spawner is itself running under a Claude session, which exports
    /// variables naming its API host, its auth refresh and its session. A
    /// `claude` started with those does not log in as the user's CLI; it tries
    /// to be part of the parent's session and fails to authenticate. An
    /// `ANTHROPIC_API_KEY` left in would do something quieter and worse: bill
    /// the key instead of the subscription the worker is meant to run on.
    /// The MCP configuration that serves Vitra's browser, where the app has
    /// written one: the maestro's own, which a worker can share because the
    /// helper serves a worker only what a worker may use.
    static var installedBrowserConfig: String? {
        let path = NSHomeDirectory() + "/.vitra/maestro/mcp.json"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    public static func workerEnvironment(from environment: [String: String]) -> [String: String] {
        environment.filter { name, _ in !name.hasPrefix("CLAUDE") && !name.hasPrefix("ANTHROPIC_") }
    }

    /// Starts `arguments` in its own process group with its streams closed.
    ///
    /// Its own group is what makes cancelling a worker complete: the CLIs start
    /// processes of their own, and a signal to the group reaches all of them,
    /// where a signal to the one pid would leave the rest running.
    /// `Foundation.Process` cannot ask for a group, hence `posix_spawn`.
    private static func launch(
        _ arguments: [String],
        environment: [String: String],
        directory: String
    ) throws(OrchestratorError) -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        // CLOEXEC_DEFAULT closes every descriptor not opened above. Without it
        // the worker would inherit the pipe this process speaks MCP on, and
        // hold the client's end open after this process has gone.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let code = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)
        guard code == 0 else { throw .spawnFailed(String(cString: strerror(code))) }
        return pid
    }

    // MARK: - Reading

    /// Where the run stands right now.
    public func status(_ id: String) throws(OrchestratorError) -> Run {
        guard let record = record(id) else { throw .unknownRun(id) }
        return run(id, record)
    }

    /// Waits until every run has stopped or `timeout` seconds have passed, and
    /// returns them in the order asked. A run still going at the timeout comes
    /// back as running; waiting again picks it up where it is.
    public func wait(ids: [String], timeout: TimeInterval) async throws -> [Run] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let runs = try ids.map { id throws(OrchestratorError) in try status(id) }
            if runs.allSatisfy({ $0.state != .running }) || Date() >= deadline { return runs }
            // ponytail: polls the exit files. A kqueue on each run directory
            // would wake sooner, and would matter with hundreds of workers.
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    /// The most recently started runs, newest first.
    public func recent(limit: Int) -> [Run] {
        // ponytail: decodes every run on disk and nothing ever prunes them.
        // Fine for hundreds; add an index or an expiry when it is thousands.
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids
            .compactMap { id in record(id).map { (id, $0) } }
            .sorted { $0.1.started > $1.1.started }
            .prefix(max(limit, 0))
            .map { run($0.0, $0.1) }
    }

    // MARK: - Rating

    /// Records what the orchestrator made of a delivery: 1 to 5, and why.
    ///
    /// Kept beside the run, so the history of who delivered what, how well and
    /// how fast is the runs themselves and needs no ledger of its own. Rating
    /// again replaces the earlier verdict.
    public func rate(_ id: String, score: Int, note: String?) throws(OrchestratorError) {
        let run = try status(id)
        guard run.state != .running else {
            throw .invalidSpec("agent \(id) is still running: there is nothing to rate yet")
        }
        guard Rating.scores.contains(score) else {
            throw .invalidSpec("score must be a whole number from 1 to 5")
        }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rating = Rating(score: score, note: trimmed?.isEmpty == false ? trimmed : nil, rated: Date())
        do {
            try JSONEncoder().encode(rating).write(to: file(id, "rating.json"), options: .atomic)
        } catch {
            throw .spawnFailed("could not record the rating: \(error.localizedDescription)")
        }
    }

    // MARK: - Cancelling

    /// Stops a running worker and everything it started. A run that has
    /// already stopped is left as it is.
    ///
    /// Blocks for as long as the worker takes to die, up to the grace period:
    /// call it off the cooperative pool.
    public func cancel(_ id: String) throws(OrchestratorError) {
        guard let record = record(id) else { throw .unknownRun(id) }
        guard state(id, record) == .running else { return }

        // The marker goes down first: once the group is signalled the shell
        // dies without writing an exit code, and the marker is what tells that
        // apart from a run that was lost.
        FileManager.default.createFile(atPath: file(id, "cancelled").path, contents: nil)
        kill(-record.pid, SIGTERM)

        let deadline = Date().addingTimeInterval(Self.terminationGrace)
        while Self.isGroupAlive(record), Date() < deadline {
            usleep(20000)
        }
        if Self.isGroupAlive(record) { kill(-record.pid, SIGKILL) }
    }

    // MARK: - On disk

    private func file(_ id: String, _ name: String) -> URL {
        root.appendingPathComponent(id).appendingPathComponent(name)
    }

    /// The record of `id`, or nil when there is no such run.
    ///
    /// Ids reach this from a model. Anything that is not exactly the shape
    /// `spawn` hands out is refused here, before it becomes part of a path.
    ///
    /// The pid is refused here too when it is not one a worker could have. It
    /// is read back from a file and ends up negated in `kill`: 0 would signal
    /// this process's own group, 1 every process the user owns, and a negative
    /// one a single process that was never ours. A record like that is not a
    /// run.
    private func record(_ id: String) -> RunRecord? {
        guard id.range(of: "^[0-9a-f]{8}$", options: .regularExpression) != nil,
              let data = try? Data(contentsOf: file(id, "run.json")),
              let record = try? JSONDecoder().decode(RunRecord.self, from: data),
              record.pid > 1
        else { return nil }
        return record
    }

    private func run(_ id: String, _ record: RunRecord) -> Run {
        let state = state(id, record)
        let ended: Date? = switch state {
        case .finished: modified(file(id, "exit"))
        case .cancelled: modified(file(id, "cancelled"))
        case .running, .lost: nil
        }
        let errorTail = state == .running ? nil : tail(file(id, "stderr"))

        var output: WorkerOutput?
        if case let .finished(exitCode) = state {
            // Decoded leniently: a worker killed mid-character, or one that
            // printed bytes that are not text, still has an answer worth reading.
            let stdout = String(decoding: (try? Data(contentsOf: file(id, "stdout"))) ?? Data(), as: UTF8.self)
            // A CLI that dies before it starts — signed out, say — prints its
            // reason on stderr and nothing at all on stdout. That reason is
            // the answer then, not "printed nothing".
            let isSilent = stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let parsed = isSilent && exitCode != 0 && errorTail != nil
                ? WorkerOutput(text: errorTail ?? "", isError: true)
                : WorkerOutput.parse(stdout, cli: record.spec.cli)
            // Either signal is enough: a CLI can exit zero having reported a
            // failure, and can die non-zero having printed half an answer.
            output = exitCode == 0 ? parsed : parsed.failed(fallbackText: errorTail)
        }

        return Run(
            id: id,
            spec: record.spec,
            state: state,
            pid: record.pid,
            started: record.started,
            ended: ended,
            output: output,
            errorTail: errorTail,
            rating: (try? Data(contentsOf: file(id, "rating.json")))
                .flatMap { try? JSONDecoder().decode(Rating.self, from: $0) }
        )
    }

    private func state(_ id: String, _ record: RunRecord) -> Run.State {
        // An exit code outranks the cancelled marker. A cancelled worker is
        // killed before it can write one, so both being there means the worker
        // finished in the instant before the cancel reached it: its answer is
        // real and must not be thrown away.
        //
        // Unless the exit code is the cancel's own doing. The shell that
        // records the code is signalled along with the worker, but it can
        // outlive the worker by long enough to write down that the worker died
        // of the signal. That is a cancelled run, not a failed one.
        let wasCancelled = FileManager.default.fileExists(atPath: file(id, "cancelled").path)
        if let code = exitCode(id) {
            return wasCancelled && Self.cancelExitCodes.contains(code) ? .cancelled : .finished(exitCode: code)
        }
        if wasCancelled { return .cancelled }
        if Self.isGroupAlive(record) { return .running }
        // The worker can finish between the two checks above; look once more
        // before calling it lost.
        if let code = exitCode(id) { return .finished(exitCode: code) }
        return .lost
    }

    private func exitCode(_ id: String) -> Int32? {
        guard let data = try? Data(contentsOf: file(id, "exit")) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether anything is left of the process group the run's shell leads.
    private static func isGroupAlive(_ record: RunRecord) -> Bool {
        // A worker this process spawned and has not reaped is a zombie, and a
        // zombie still answers signals. Reaping first makes the answer true;
        // for a worker some other process spawned this is a harmless ECHILD.
        var status: Int32 = 0
        waitpid(record.pid, &status, WNOHANG)

        // Something holds the pid, but it started at another time: the number
        // was recycled, and the group it leads now is not the worker's.
        if let recorded = record.leaderStarted,
           let current = processStart(record.pid),
           current != recorded {
            return false
        }
        return kill(-record.pid, 0) == 0
    }

    /// When the kernel says `pid` started, or nil when nothing holds that pid.
    private static func processStart(_ pid: pid_t) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The end of a file, read from the end: a worker can leave megabytes on
    /// stderr and only the last of it says why it died.
    private func tail(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: length - min(length, UInt64(Self.errorTailLength)))
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
