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
    /// What the orchestrator made of the delivery, once it has said.
    public var rating: Rating? = nil

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
}
