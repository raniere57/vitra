import Foundation

/// Why `RepositoryLock` could not be taken. The description is what the agent
/// is shown.
public enum RepositoryLockError: Error, Equatable, Sendable, CustomStringConvertible {
    case busy(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case let .busy(repository):
            return "another agent_merge or audit start is in progress in \(repository): try again in a moment"
        case let .unavailable(reason):
            return "could not lock the repository: \(reason)"
        }
    }
}

/// One advisory lock per repository, for what must not interleave across
/// helper processes: the merge (its MERGE_HEAD check, the merge, the abort,
/// the removal of the worktree and branch) and the start of an audit in a
/// worktree the merge would remove.
///
/// The lock is a flock on `<git common dir>/vitra.lock`, so every worktree of
/// one repository shares it. flock belongs to the open file description, so
/// it also serializes two callers inside one process.
///
/// Hold it only across git work and file writes, never while waiting on a
/// worker. Whoever cannot get it within `timeout` gets `busy`, rather than
/// waiting on a merge that may be stuck behind a hook: the caller can ask again.
public enum RepositoryLock {
    public static let defaultTimeout: TimeInterval = 60
    private static let retryInterval: useconds_t = 25_000

    public static func withLock<T>(
        _ repository: String,
        timeout: TimeInterval = defaultTimeout,
        _ body: () throws -> T
    ) throws -> T {
        guard let path = lockPath(repository) else {
            throw RepositoryLockError.unavailable("git could not say where \(repository) keeps its data")
        }
        // CLOEXEC: a git started under the lock must not keep it past its own end.
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RepositoryLockError.unavailable(String(cString: strerror(errno))) }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        let limit = Date().addingTimeInterval(timeout)
        // ponytail: polls a non-blocking flock; a blocking one cannot give up
        // at a deadline. Lock holds are git-sized, so a poll this fine is plenty.
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw RepositoryLockError.unavailable(String(cString: strerror(errno)))
            }
            guard Date() < limit else { throw RepositoryLockError.busy(repository) }
            usleep(retryInterval)
        }
        return try body()
    }

    /// The lock file of `repository`, in the git directory its worktrees share.
    static func lockPath(_ repository: String) -> String? {
        guard let common = Git.output(["rev-parse", "--git-common-dir"], in: repository)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty
        else { return nil }
        let directory = common.hasPrefix("/") ? common : repository + "/" + common
        return directory + "/vitra.lock"
    }
}
