import Foundation

/// One worker, from the moment it was spawned.
public struct Run: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        case finished(exitCode: Int32)
        case cancelled
        /// The process is gone and left no exit code: it was killed from
        /// outside, or the machine went down under it.
        case lost
    }

    public let id: String
    public let spec: WorkerSpec
    public let state: State
    public let pid: Int32?
    public let started: Date
    public let ended: Date?
    /// What the worker reported. Only a finished run has one.
    public let output: WorkerOutput?
    /// The end of what the worker wrote to stderr, when it wrote anything.
    public let errorTail: String?
    /// The repository an editing worker was given a worktree of, when it was.
    ///
    /// A worker that edits gets a tree of its own so two of them cannot
    /// overwrite one another; these four fields are where its work went.
    public var repository: String? = nil
    /// The root of that worktree.
    public var worktree: String? = nil
    /// The branch its changes were committed to, `vitra/<id>`.
    public var branch: String? = nil
    /// The commit the branch was made from.
    public var baseCommit: String? = nil
    /// Why the shell could not commit the worker's work, when it could not.
    ///
    /// Present with an empty string when git refused without saying why. When
    /// it is set the edits are still uncommitted in `worktree`.
    public var commitError: String? = nil
    /// What the orchestrator made of the delivery, once it has said.
    public var rating: Rating? = nil
    /// The lines of the project's `.vitra/worktree` that could not be applied
    /// to the worktree, each with why. Empty when all applied or there was none.
    public var worktreeSkipped: [String] = []
    /// While running: how long stdout and stderr have both gone unwritten.
    public var silentFor: TimeInterval? = nil
    /// Set when the run was cancelled for outlasting its deadline: the minutes
    /// it was given. Such a run is `finished(exitCode: Orchestrator.timeoutExitCode)`
    /// and an error, so it counts as failed everywhere a failure does.
    public var timedOutAfter: Int? = nil
    /// Set when the run did not run because of its provider (quota, signed
    /// out, down). It is still a finished run with an error, but it counts for
    /// nothing against the worker.
    public var providerFailure: ProviderFailure? = nil
    /// Whether Vitra chose the worker, the spawn having left the cli out.
    public var wasPicked: Bool = false
    /// The run this one retried after its provider failed: at most one
    /// failover per original run.
    public var retryOf: String? = nil
    /// The run this one redoes, in the same worktree and branch when it could.
    public var redoOf: String? = nil
    /// Whether the worktree was taken away and the branch kept, for later.
    public var isPaused: Bool = false

    /// Public so the UI snapshot tool can build runs without reading any on disk.
    public init(
        id: String,
        spec: WorkerSpec,
        state: State,
        pid: Int32?,
        started: Date,
        ended: Date?,
        output: WorkerOutput?,
        errorTail: String?,
        repository: String? = nil,
        worktree: String? = nil,
        branch: String? = nil,
        baseCommit: String? = nil,
        commitError: String? = nil,
        rating: Rating? = nil,
        worktreeSkipped: [String] = [],
        silentFor: TimeInterval? = nil,
        timedOutAfter: Int? = nil,
        providerFailure: ProviderFailure? = nil,
        wasPicked: Bool = false,
        retryOf: String? = nil,
        redoOf: String? = nil,
        isPaused: Bool = false
    ) {
        self.id = id
        self.spec = spec
        self.state = state
        self.pid = pid
        self.started = started
        self.ended = ended
        self.output = output
        self.errorTail = errorTail
        self.repository = repository
        self.worktree = worktree
        self.branch = branch
        self.baseCommit = baseCommit
        self.commitError = commitError
        self.rating = rating
        self.worktreeSkipped = worktreeSkipped
        self.silentFor = silentFor
        self.timedOutAfter = timedOutAfter
        self.providerFailure = providerFailure
        self.wasPicked = wasPicked
        self.retryOf = retryOf
        self.redoOf = redoOf
        self.isPaused = isPaused
    }

    /// How long the run took, or has taken so far.
    public var duration: TimeInterval {
        (ended ?? Date()).timeIntervalSince(started)
    }
}

/// What is written down when a run starts. Everything else about a run is
/// derived from the files the worker leaves beside it.
struct RunRecord: Codable {
    let spec: WorkerSpec
    let started: Date
    /// The shell that leads the worker's process group.
    let pid: Int32
    /// When the kernel says that shell started. A pid is recycled; a pid and
    /// its start time together are not, which is what keeps a signal meant for
    /// a worker from landing on whatever holds its number after a reboot.
    let leaderStarted: Double?
    /// The repository, worktree and branch an editing worker was given, and
    /// the commit its branch was made from. Absent for a run that got none:
    /// optional, so a record written before worktrees existed still loads.
    let repository: String?
    let worktree: String?
    let branch: String?
    let baseCommit: String?
    /// When the run is cancelled as hung. Absent in a record written before
    /// deadlines existed: such a run has none.
    var deadline: Date? = nil
    /// Whether Vitra picked the worker; absent when the maestro named it.
    var picked: Bool? = nil
    /// The run this one is the failover of, or the redo of.
    var retryOf: String? = nil
    var redoOf: String? = nil
}
