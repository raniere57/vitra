import Darwin
import Foundation

/// The runs that have settled, kept in one file beside them: `<root>/.index`.
///
/// The cockpit reads the last 2,000 runs to rank the workers, and reading
/// each one's `run.json` and `summary.json` is 4,000 files: over a second
/// cold, and a third of one warm just to look at them again. A settled run —
/// finished, or cancelled and gone — does not change except for its rating
/// and its paused marker, so everything `recent` reports about it is written
/// here once, as a line of JSON, and read back in one go.
///
/// The disk stays the truth. Each line carries the run directory's
/// modification time as it was read, and a run is believed from here only
/// while its directory still has that time: rating a run, pausing it,
/// compacting it all add, rename or remove a file in it, which moves the
/// directory's time, and the run is read whole again and its line appended
/// anew. So the index is never rebuilt on purpose: a missing or stale line is
/// a run read the slow way once, and a line for a run that is gone is never
/// looked up.
///
/// Lines are only appended, under a `flock` on `<root>/.index.lock`, the same
/// discipline as the repository lock; readers take no lock and keep what they
/// read by offset, so another process's appends are picked up on the next
/// look. When superseded lines pile up the file is rewritten whole, under the
/// lock, and renamed into place.
final class RunIndex: @unchecked Sendable {
    /// One settled run, as `recent` reports it.
    struct Entry: Codable {
        let id: String
        /// The run directory's modification time when this was read.
        let stamp: Stamp
        let record: RunRecord
        /// The exit code; nil for a cancelled run.
        let exitCode: Int32?
        let ended: Date?
        let output: WorkerOutput?
        let errorTail: String?
        let commitError: String?
        let worktreeSkipped: [String]
        let timedOutAfter: Int?
        let providerFailure: ProviderFailure?
        let rating: Rating?
        let isPaused: Bool

        /// The entry for `run`, or nil when it has not settled.
        init?(_ run: Run, record: RunRecord, stamp: Stamp) {
            switch run.state {
            case let .finished(code): exitCode = code
            case .cancelled: exitCode = nil
            case .running, .lost: return nil
            }
            id = run.id
            self.stamp = stamp
            self.record = record
            ended = run.ended
            output = run.output
            errorTail = run.errorTail
            commitError = run.commitError
            worktreeSkipped = run.worktreeSkipped
            timedOutAfter = run.timedOutAfter
            providerFailure = run.providerFailure
            rating = run.rating
            isPaused = run.isPaused
        }

        /// The run as `Orchestrator.run(_:_:fullText: false)` builds it.
        var run: Run {
            Run(
                id: id, spec: record.spec, state: exitCode.map { .finished(exitCode: $0) } ?? .cancelled,
                pid: record.pid, started: record.started, ended: ended, output: output, errorTail: errorTail,
                repository: record.repository, worktree: record.worktree, branch: record.branch,
                baseCommit: record.baseCommit, commitError: commitError, rating: rating,
                worktreeSkipped: worktreeSkipped, silentFor: nil, timedOutAfter: timedOutAfter,
                providerFailure: providerFailure, wasPicked: record.picked == true, pick: record.pick,
                retryOf: record.retryOf, redoOf: record.redoOf, isPaused: isPaused
            )
        }
    }

    /// A modification time to the nanosecond, as `stat` gives it: a date
    /// would round, and a change within the same microsecond would be missed.
    struct Stamp: Codable, Equatable, Hashable {
        let seconds: Int
        let nanoseconds: Int

        /// The time of `path`, or nil when there is nothing there.
        init?(of path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
        }

        init(seconds: Int, nanoseconds: Int) {
            self.seconds = seconds
            self.nanoseconds = nanoseconds
        }
    }

    /// Rewrite once this many lines are superseded beyond the live ones.
    private static let slack = 256

    let file: URL
    private let lockFile: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var started: [String: Date] = [:]
    /// How far into the file has been read, up to the last whole line.
    private var offset: UInt64 = 0
    /// The file read, so a rewrite (a new inode) is read again from the start.
    private var inode: UInt64?
    private var lines = 0

    init(root: URL) {
        file = root.appendingPathComponent(".index")
        lockFile = root.appendingPathComponent(".index.lock")
    }

    /// The entries as last read, after picking up what was appended.
    func entries(syncing: Bool = true) -> [String: Entry] {
        lock.withLock {
            if syncing { syncLocked() }
            return entries
        }
    }

    /// The entries, and each one's start on its own: ordering two thousand
    /// runs by start is then a lookup of a date, not a copy of a run.
    func snapshot() -> (entries: [String: Entry], started: [String: Date]) {
        lock.withLock {
            syncLocked()
            return (entries, started)
        }
    }

    /// Appends `fresh` and keeps them; rewrites the file when it has grown
    /// well past what it holds. `live` are the runs that still exist, for
    /// the rewrite to keep.
    func append(_ fresh: [Entry], live: @autoclosure () -> Set<String>) {
        guard !fresh.isEmpty else { return }
        let encoder = JSONEncoder()
        var data = Data()
        for entry in fresh {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        withFileLock {
            lock.withLock {
                syncLocked()
                guard let handle = (try? FileHandle(forWritingTo: file)) ?? create() else { return }
                defer { try? handle.close() }
                // Every writer holds the file lock, so the end is still the end.
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                syncLocked()
                if lines > entries.count + Self.slack { rewriteLocked(keeping: live()) }
            }
        }
    }

    /// Writes the file anew with only the latest line of each run in `live`.
    func rewrite(keeping live: Set<String>) {
        withFileLock {
            lock.withLock {
                syncLocked()
                rewriteLocked(keeping: live)
            }
        }
    }

    // MARK: - Under the locks

    private func create() -> FileHandle? {
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        return try? FileHandle(forWritingTo: file)
    }

    /// Reads whatever was appended since the last look; reads the whole file
    /// again when it was replaced or cut short.
    private func syncLocked() {
        var info = stat()
        guard stat(file.path, &info) == 0 else {
            (entries, started, offset, inode, lines) = ([:], [:], 0, nil, 0)
            return
        }
        let size = UInt64(info.st_size)
        if inode != info.st_ino || size < offset {
            (entries, started, offset, lines) = ([:], [:], 0, 0)
            inode = info.st_ino
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let last = data.lastIndex(of: 0x0A) else { return }
        let decoder = JSONDecoder()
        // A line cut short or not ours is skipped: that run is read the slow way.
        for line in data[data.startIndex...last].split(separator: 0x0A) {
            lines += 1
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)) else { continue }
            entries[entry.id] = entry
            started[entry.id] = entry.record.started
        }
        offset += UInt64(last - data.startIndex + 1)
    }

    private func rewriteLocked(keeping live: Set<String>) {
        let encoder = JSONEncoder()
        let kept = entries.values.filter { live.contains($0.id) }.sorted { $0.id < $1.id }
        var data = Data()
        for entry in kept {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".index.tmp")
        guard (try? data.write(to: temporary)) != nil, rename(temporary.path, file.path) == 0 else { return }
        (entries, started, offset, inode, lines) = ([:], [:], 0, nil, 0)
        syncLocked()
    }

    /// Runs `body` holding the index's file lock. Without the lock file — a
    /// root that cannot be written — the body is skipped: an index is a
    /// cache, and a process that cannot write it reads the slow way.
    private func withFileLock(_ body: () -> Void) {
        let descriptor = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else { return }
        body()
    }
}
