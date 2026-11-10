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
///     <root>/<id>/commit-error why the shell could not commit an editing
///                             worker's work, when it could not
///     <root>/<id>/cancelled   present when the run was cancelled
///     <root>/<id>/rating.json the orchestrator's verdict on the delivery
///     <root>/<id>/audit       the id of the worker auditing this delivery
///     <root>/<id>/tree        an editing worker's own worktree, when it got one
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
    /// How much later than its directory's creation a run's `started` can be:
    /// the worktree is made in between.
    private static let startSkew: TimeInterval = 600
    /// What a shell reports for a child killed by the signals `cancel` sends:
    /// 128 plus SIGTERM, and 128 plus SIGKILL.
    private static let cancelExitCodes: Set<Int32> = [128 + SIGTERM, 128 + SIGKILL]

    private let root: URL
    private let memoryRoot: URL
    private let executables: Executables
    private let browserConfig: String?
    /// The `vitra` binary a worker's own MCP configuration starts.
    private let vitraBinary: String?
    /// What was already read about runs, so a finished run's stdout is parsed
    /// once however often it is listed.
    private let cache = RunCache()

    /// `browserConfig` is the MCP configuration that hands workers Vitra's
    /// browser. Left out, it is the one the app installed — for the real run
    /// store only, so a test's workers are not given the user's browser.
    /// `vitraBinary` is the binary that configuration starts; claude and
    /// opencode workers get their own configuration naming it, and without one
    /// they get no Vitra tools at all rather than the maestro's shared file.
    /// `memoryRoot` is where project notes are read from; tests point it at a
    /// scratch directory for the same reason.
    public init(
        root: URL = Orchestrator.defaultRoot,
        executables: Executables = .discover(),
        browserConfig: String? = nil,
        vitraBinary: String? = nil,
        memoryRoot: URL = ProjectMemory.defaultRoot
    ) {
        let isRealStore = root == Orchestrator.defaultRoot
        self.root = root
        self.memoryRoot = memoryRoot
        self.executables = executables
        self.browserConfig = browserConfig ?? (isRealStore ? Self.installedBrowserConfig : nil)
        self.vitraBinary = vitraBinary ?? (isRealStore ? Self.installedVitraBinary : nil)
    }

    // MARK: - Spawning

    /// Starts a worker and returns its id without waiting for it.
    @discardableResult
    public func spawn(_ spec: WorkerSpec) throws(OrchestratorError) -> String {
        try spec.validate()
        guard let executable = executables.paths[spec.cli] else { throw .executableNotFound(spec.cli) }

        let (id, directory) = try makeRunDirectory()
        do {
            try Data(promptWithNotes(spec).utf8).write(to: directory.appendingPathComponent("prompt"))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw .spawnFailed("\(error.localizedDescription)")
        }

        // The worker's MCP configuration, which names this run. Written before
        // anything is started, so a failure leaves nothing behind but the run
        // directory, which is removed here.
        let served: (config: String?, environment: [String: String])
        do {
            served = try serving(spec, id: id, run: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        // An editing worker is given a tree of its own before it starts, so
        // that two of them in one checkout cannot overwrite each other.
        let worktree: Worktree?
        do {
            worktree = try makeWorktree(id: id, for: spec, run: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        // The shell is there for three things the worker cannot do for itself:
        // point its three streams at files, put whatever it left uncommitted
        // on its branch, and write its exit code down once it is gone. The
        // code is written to a temporary name and moved into place so a
        // reader never sees a half-written file.
        //
        // The prompt reaches the worker on stdin where the CLI reads it there,
        // and otherwise as one last argument. Either way it comes out of a
        // file: it is never spliced into this script, so nothing in it is
        // expanded or run by the shell.
        //
        // The commit message is a label from a model, so it reaches git the
        // same way, through the environment, never as part of this text. The
        // worker's own exit code is taken before the commit and written after
        // it: whether its work could be committed is not its answer.
        let run = spec.cli.takesPromptOnStdin
            ? #""$@" <"$VITRA_RUN/prompt""#
            : #""$@" "$VITRA_PROMPT_FLAG$(cat "$VITRA_RUN/prompt")" </dev/null"#
        let script = """
        \(run) >"$VITRA_RUN/stdout" 2>"$VITRA_RUN/stderr"
        vitra_exit=$?
        if [ -n "$VITRA_WORKTREE" ]; then
            vitra_commit_error="$VITRA_RUN/commit-error"
            rm -f "$vitra_commit_error"
            # What the setup linked or copied in is the project's, not the
            # worker's work. `git add` refuses an exclude pathspec that reaches
            # into an ignored folder such as vendor/, so everything is added
            # and those paths are unstaged again by literal pathspec.
            set --
            while IFS= read -r vitra_path; do
                set -- "$@" ":(literal)$vitra_path"
            done <"$VITRA_RUN/worktree-excludes"
            if ! git -C "$VITRA_WORKTREE" add -A >/dev/null 2>"$vitra_commit_error"; then
                : # git's reason is in the file; the worker's edits stay where they are
            elif [ $# -gt 0 ] && ! git -C "$VITRA_WORKTREE" reset -q -- "$@" >/dev/null 2>"$vitra_commit_error"; then
                : # git's reason is in the file, as above
            elif git -C "$VITRA_WORKTREE" diff --cached --quiet >/dev/null 2>&1; then
                rm -f "$vitra_commit_error"
            elif ! GIT_AUTHOR_NAME='Vitra worker' GIT_AUTHOR_EMAIL='worker@vitra.local' \\
                GIT_COMMITTER_NAME='Vitra worker' GIT_COMMITTER_EMAIL='worker@vitra.local' \\
                git -C "$VITRA_WORKTREE" commit -q -m "$VITRA_COMMIT_MESSAGE" >/dev/null 2>"$vitra_commit_error"; then
                : # a refusing hook leaves the file, even when it printed nothing
            else
                rm -f "$vitra_commit_error"
            fi
        fi
        echo "$vitra_exit" >"$VITRA_RUN/exit.tmp" && mv "$VITRA_RUN/exit.tmp" "$VITRA_RUN/exit"
        """
        var variables = [
            "VITRA_RUN": directory.path, "VITRA_AGENT": id, "VITRA_PROMPT_FLAG": spec.cli.promptFlag ?? "",
        ]
        if let worktree {
            variables["VITRA_WORKTREE"] = worktree.tree
            // Read by the shell after the worker: one path per line, never
            // spliced into the script.
            let label = spec.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            variables["VITRA_COMMIT_MESSAGE"] = "vitra \(id): " + (label.isEmpty ? spec.worker : label)
        }
        let environment = Self.workerEnvironment(from: ProcessInfo.processInfo.environment)
            // VITRA_AGENT is who the worker is to Vitra's browser: the tab it
            // opens there is filed under its run.
            .merging(variables) { _, new in new }
            .merging(served.environment) { _, new in new }

        let pid: pid_t
        do {
            pid = try Self.launch(
                ["/bin/sh", "-c", script, "vitra-worker", executable] + spec.arguments(browserConfig: served.config),
                environment: environment,
                directory: worktree?.directory.path ?? spec.directory
            )
        } catch {
            // The tree sits inside the run directory: take the worktree away
            // first, or its files are gone and git can no longer remove it.
            if let worktree { discard(worktree) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        do {
            let record = RunRecord(
                spec: spec,
                started: Date(),
                pid: pid,
                leaderStarted: Self.processStart(pid),
                repository: worktree?.top,
                worktree: worktree?.tree,
                branch: worktree?.branch,
                baseCommit: worktree?.base
            )
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("run.json"), options: .atomic)
        } catch {
            // A worker with no record could never be found or cancelled again,
            // and it may be one that edits. It does not get to run.
            kill(-pid, SIGKILL)
            if let worktree { discard(worktree) }
            try? FileManager.default.removeItem(at: directory)
            throw .spawnFailed("\(error.localizedDescription)")
        }
        return id
    }

    /// The worktree an editing worker was given, and the branch its work goes
    /// to.
    private struct Worktree {
        /// The top level of the repository it was made from.
        let top: String
        /// The worktree's own root, which is also what git commits from.
        let tree: String
        let branch: String
        let base: String
        /// Where the worker runs: the tree, or the same subfolder of the
        /// repository it was sent to.
        let directory: URL
    }

    /// Gives an editing worker a branch and a worktree of its own.
    ///
    /// Two editing workers in one checkout overwrite each other's files, so
    /// each gets its own tree on its own branch, made from the repository's
    /// current HEAD. A read worker writes nothing, and a directory outside a
    /// repository has no worktree to be given: both run where they were sent,
    /// as they always have.
    private func makeWorktree(
        id: String,
        for spec: WorkerSpec,
        run: URL
    ) throws(OrchestratorError) -> Worktree? {
        guard spec.access == .edit else { return nil }
        let topLevel = (Git.output(["rev-parse", "--show-toplevel"], in: spec.directory) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topLevel.isEmpty else { return nil }

        // Where the directory sits inside the repository, so the worker is
        // sent to the same place in its worktree. git answers this itself,
        // which keeps symlinks out of a comparison of two paths.
        let prefix = (Git.output(["rev-parse", "--show-prefix"], in: spec.directory) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The base is read before the branch exists: the branch is made from
        // it, and the report measures the worker's work against it.
        let head = Git.run(["rev-parse", "HEAD"], in: topLevel)
        guard head.succeeded else {
            throw .spawnFailed(head.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let base = head.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let tree = run.appendingPathComponent("tree")
        let branch = "vitra/\(id)"
        let added = Git.run(["worktree", "add", "-b", branch, tree.path, "HEAD"], in: topLevel)
        guard added.succeeded else {
            throw .spawnFailed(added.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // What the project keeps out of git but the worker needs. Whatever
        // could not be applied is written beside the run for the report.
        // The list is read from the new tree, where it is committed as of the
        // base. The sources come from the main working tree, not from `topLevel`:
        // when the directory is itself a worktree, its ignored folders are
        // symlinks into the main checkout, which the setup would refuse as
        // outside the repository.
        let setup = WorktreeSetup.apply(
            listIn: tree,
            sourcesIn: URL(fileURLWithPath: mainWorkingTree(from: topLevel)),
            to: tree
        )
        if !setup.skipped.isEmpty {
            try? Data((setup.skipped.joined(separator: "\n") + "\n").utf8)
                .write(to: run.appendingPathComponent("worktree-setup"))
        }
        // What the setup put there is kept out of the worker's commits; the
        // file is always written, so the shell can read it.
        try? Data(setup.applied.map { $0 + "\n" }.joined().utf8)
            .write(to: run.appendingPathComponent("worktree-excludes"))

        let directory = prefix.isEmpty ? tree : tree.appendingPathComponent(prefix)
        // A directory that exists only on disk is not in the repository, so
        // the checkout has no counterpart: make it, rather than sending the
        // worker to a path that is not there.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Worktree(top: topLevel, tree: tree.path, branch: branch, base: base, directory: directory)
    }

    /// The top of the main working tree: the first `worktree` entry git lists,
    /// which is the main checkout in a normal repository and in a submodule
    /// alike. Falls back to `topLevel` when git cannot say.
    private func mainWorkingTree(from topLevel: String) -> String {
        let listing = Git.output(["worktree", "list", "--porcelain"], in: topLevel) ?? ""
        let first = listing
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("worktree ") }
            .map { $0.dropFirst("worktree ".count).trimmingCharacters(in: .whitespaces) }
        guard let first, !first.isEmpty else { return topLevel }
        return String(first)
    }

    /// Takes away a worktree and the branch a failed spawn made.
    ///
    /// A spawn can still fail after `git worktree add -b` — the worker may not
    /// start, the record may not be written — and then nothing will ever use
    /// the branch. `git worktree prune` forgets the directory but leaves the
    /// branch in the repository for ever, so both are removed here, by name.
    private func discard(_ worktree: Worktree) {
        _ = Git.run(["worktree", "remove", "--force", worktree.tree], in: worktree.top)
        _ = Git.run(["branch", "-D", worktree.branch], in: worktree.top)
    }

    /// The prompt the worker is given: the project's notes first, when there
    /// are any, so the worker reads what earlier agents learned before the task.
    ///
    /// Only the file the worker reads carries the notes. The record keeps the
    /// prompt as it was asked, so the history stays the request, not the notes
    /// as they stood that day.
    private func promptWithNotes(_ spec: WorkerSpec) -> String {
        guard let project = spec.project else { return spec.prompt }
        let notes = ProjectMemory(root: memoryRoot).read(project: project)
        guard !notes.isEmpty else { return spec.prompt }
        return """
        Notes on this project left by earlier agents. Read them first, and add one with memory_add when you learn something the next agent should know:
        \(notes)

        ---

        \(spec.prompt)
        """
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

    /// The `vitra` binary the installed configuration starts, so a worker's own
    /// configuration starts the same one.
    static var installedVitraBinary: String? {
        guard let path = installedBrowserConfig,
              let data = FileManager.default.contents(atPath: path),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = config["mcpServers"] as? [String: Any],
              let vitra = servers["vitra"] as? [String: Any],
              let command = vitra["command"] as? String, !command.isEmpty
        else { return nil }
        return command
    }

    /// The MCP configuration a worker is started with, and the environment
    /// that goes with it. Claude and opencode take one per run, so each gets
    /// its own naming this worker. The other CLIs read only their global
    /// configuration, and keep the shared one as before.
    private func serving(
        _ spec: WorkerSpec,
        id: String,
        run: URL
    ) throws(OrchestratorError) -> (config: String?, environment: [String: String]) {
        guard let browserConfig else { return (nil, [:]) }
        guard spec.cli == .claude || spec.cli == .opencode else { return (browserConfig, [:]) }
        guard let vitraBinary else { return (nil, [:]) }
        return try Self.writeRunConfig(for: spec, id: id, run: run, binary: vitraBinary)
    }

    /// Writes this run's configuration for a claude or opencode worker into its
    /// run directory, and returns what the worker is started with.
    static func writeRunConfig(
        for spec: WorkerSpec,
        id: String,
        run: URL,
        binary: String
    ) throws(OrchestratorError) -> (config: String?, environment: [String: String]) {
        let identity = VitraMCPConfig.workerEnvironment(id: id, run: run, project: spec.project)
        let isClaude = spec.cli == .claude
        let file = run.appendingPathComponent(isClaude ? "mcp.json" : "opencode.json")
        let text = isClaude
            ? VitraMCPConfig.claudeConfig(binary: binary, environment: identity)
            : VitraMCPConfig.opencodeConfig(binary: binary, environment: identity)
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            throw .spawnFailed("\(error.localizedDescription)")
        }
        // opencode finds its configuration through the environment, not a flag.
        return (file.path, isClaude ? [:] : ["OPENCODE_CONFIG": file.path])
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
    ///
    /// The answer comes back whole. Pass `fullText: false` to get it cut at
    /// `RunSummary.textLimit` characters, which is what `recent` does, and
    /// costs no read of stdout once the run has been seen finished.
    public func status(_ id: String, fullText: Bool = true) throws(OrchestratorError) -> Run {
        guard let record = record(id) else { throw .unknownRun(id) }
        return run(id, record, fullText: fullText)
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

    /// Where a run keeps its files, or nil when there is no such run.
    ///
    /// The caller that starts an audit writes the auditor's id beside the run
    /// it belongs to, so a later `agent_wait` finds it instead of starting a
    /// second audit.
    public func directory(of id: String) -> URL? {
        guard record(id) != nil else { return nil }
        return root.appendingPathComponent(id)
    }

    /// The most recently started runs, newest first.
    ///
    /// A finished run's answer is cut at `RunSummary.textLimit` characters
    /// here; `status` has it whole.
    ///
    /// Only the newest are opened. The run directories are ordered by when
    /// they were made, which is a moment before `started`: two spawns racing
    /// can swap places, so everything made within `startSkew` of the last one
    /// kept is opened as well, and the result is ordered by `started`.
    public func recent(limit: Int) -> [Run] {
        let wanted = max(limit, 0)
        guard wanted > 0 else { return [] }
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        // No date sorts as the newest: it is opened rather than skipped.
        let newestFirst = urls
            .map { ($0.lastPathComponent, (try? $0.resourceValues(forKeys: Set(keys)))?.creationDate ?? .distantFuture) }
            .sorted { $0.1 > $1.1 }

        var found: [(id: String, record: RunRecord)] = []
        var cutoff = Date.distantPast
        for (id, created) in newestFirst {
            if created < cutoff { break }
            guard let record = record(id) else { continue }
            found.append((id, record))
            if found.count == wanted { cutoff = created.addingTimeInterval(-Self.startSkew) }
        }
        return found
            .sorted { $0.record.started > $1.record.started }
            .prefix(wanted)
            .map { run($0.id, $0.record, fullText: false) }
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
              let modified = modified(file(id, "run.json"))
        else { return nil }
        // run.json is written once, but whoever replaces it is believed: the
        // copy in memory is good only while the file's date is the one it was
        // read at.
        if let known = cache.record(id, modified: modified) { return known }
        let record = (try? Data(contentsOf: file(id, "run.json")))
            .flatMap { try? JSONDecoder().decode(RunRecord.self, from: $0) }
            .flatMap { $0.pid > 1 ? $0 : nil }
        cache.store(record: record, id, modified: modified)
        return record
    }

    private func run(_ id: String, _ record: RunRecord, fullText: Bool) -> Run {
        // A run seen finished does not change again: its exit code is written
        // once, so what it said is read from the summary, not from stdout.
        let summary = cache.summary(id) ?? loadSummary(id)
        let state = state(id, record, knownExit: summary?.exitCode)
        let ended: Date?
        let errorTail: String?
        let output: WorkerOutput?
        let commitError: String?
        let worktreeSkipped: [String]

        if case let .finished(exitCode) = state {
            let settled = summary ?? makeSummary(id, record, exitCode: exitCode)
            ended = settled.ended
            errorTail = settled.errorTail
            commitError = settled.commitError
            worktreeSkipped = settled.worktreeSkipped
            output = fullText && settled.isTextCut
                ? parsedOutput(id, record, exitCode: exitCode, errorTail: settled.errorTail)
                : settled.output
        } else {
            ended = state == .cancelled ? modified(file(id, "cancelled")) : nil
            errorTail = state == .running ? nil : tail(file(id, "stderr"))
            output = nil
            commitError = self.commitError(id)
            worktreeSkipped = self.worktreeSkipped(id)
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
            repository: record.repository,
            worktree: record.worktree,
            branch: record.branch,
            baseCommit: record.baseCommit,
            commitError: commitError,
            rating: rating(id),
            worktreeSkipped: worktreeSkipped
        )
    }

    /// What the worker reported, from everything it printed.
    private func parsedOutput(_ id: String, _ record: RunRecord, exitCode: Int32, errorTail: String?) -> WorkerOutput {
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
        return exitCode == 0 ? parsed : parsed.failed(fallbackText: errorTail)
    }

    /// Reads a finished run once and writes down what came of it.
    ///
    /// The shell writes the exit code after stdout, stderr and the commit
    /// error are final, so once there is a code none of them moves again.
    private func makeSummary(_ id: String, _ record: RunRecord, exitCode: Int32) -> RunSummary {
        let errorTail = tail(file(id, "stderr"))
        let summary = RunSummary(
            exitCode: exitCode,
            ended: modified(file(id, "exit")),
            errorTail: errorTail,
            commitError: commitError(id),
            worktreeSkipped: worktreeSkipped(id),
            output: parsedOutput(id, record, exitCode: exitCode, errorTail: errorTail)
        )
        // A failed write only means the next look parses again.
        if let data = try? JSONEncoder().encode(summary) {
            try? data.write(to: file(id, "summary.json"), options: .atomic)
        }
        cache.store(summary: summary, id)
        return summary
    }

    private func loadSummary(_ id: String) -> RunSummary? {
        guard let data = try? Data(contentsOf: file(id, "summary.json")),
              let summary = try? JSONDecoder().decode(RunSummary.self, from: data),
              summary.version == RunSummary.version
        else { return nil }
        cache.store(summary: summary, id)
        return summary
    }

    private func rating(_ id: String) -> Rating? {
        let url = file(id, "rating.json")
        let modified = modified(url)
        if let known = cache.rating(id, modified: modified) { return known }
        let rating = modified.flatMap { _ in try? Data(contentsOf: url) }
            .flatMap { try? JSONDecoder().decode(Rating.self, from: $0) }
        cache.store(rating: rating, id, modified: modified)
        return rating
    }

    /// The lines of `.vitra/worktree` that could not be applied to the run's
    /// worktree, each with why. Empty when there were none.
    private func worktreeSkipped(_ id: String) -> [String] {
        guard let text = try? String(contentsOf: file(id, "worktree-setup"), encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Why the shell could not commit the worker's work, when it could not.
    ///
    /// The file is written by the wrapper only when git refused, and may be
    /// empty if git said nothing; its presence is the failure, not its text.
    /// Nil means the work was committed, or the run had no worktree at all.
    private func commitError(_ id: String) -> String? {
        guard let data = try? Data(contentsOf: file(id, "commit-error")) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `knownExit` is the exit code of a run already seen finished; the code
    /// is written once, so the file need not be read again.
    private func state(_ id: String, _ record: RunRecord, knownExit: Int32? = nil) -> Run.State {
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
        if let code = knownExit ?? exitCode(id) {
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

/// Runs git for the orchestrator and for the report it hands back.
public enum Git {
    /// Runs `git` with `arguments` in `directory`, and answers whether it
    /// succeeded along with everything it printed.
    ///
    /// Both streams come back together: git says why a command failed on
    /// stderr, and that reason is what a caller has to show. The directory is
    /// where the command stands rather than one of its arguments, so a caller
    /// names only the command and the revisions it works on.
    public static func run(_ arguments: [String], in directory: String) -> (succeeded: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        // A read-only command such as the diff in a report must not take the
        // index lock out from under the user's own git in the same repository.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else {
            return (false, "git is not installed or could not be run")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    /// What git printed, or nil when it failed.
    public static func output(_ arguments: [String], in directory: String) -> String? {
        let result = run(arguments, in: directory)
        return result.succeeded ? result.output : nil
    }
}
