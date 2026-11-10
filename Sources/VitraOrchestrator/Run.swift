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
        worktreeSkipped: [String] = []
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
}
