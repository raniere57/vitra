import Darwin
import Foundation

/// Keeps the runs root from growing for ever.
///
/// Every run leaves its stdout, stderr and prompt behind, and a busy month
/// leaves thousands. What a report of an old run needs is in `summary.json`,
/// `run.json` and `rating.json`, so:
///
/// - a run older than `compactAfter` is **compacted**: stdout, stderr and
///   prompt are removed, the rest stays. `status` then answers from the
///   summary, the answer cut where the summary cut it.
/// - a run older than `archiveAfter` that is outside the newest
///   `keptInHistory` is **archived**: its directory moves to
///   `<runs-archive>/<yyyy-mm>/<id>` and leaves the live root. The Scoreboard
///   and the picker rank on the newest 2,000 runs by count — there is no time
///   window — so a run outside them counts for nothing today, and moving it
///   changes no ranking.
///
/// A run is never touched while it is running, paused, has a worktree on disk
/// or a branch nobody merged or discarded, has its audit running, or started
/// within `compactAfter`. Each step is a removal or one `rename`, so a sweep
/// killed at any point leaves every run either as it was, compacted (in part
/// or whole: any part of it reads the same), or moved; the next sweep
/// finishes the job.
extension Orchestrator {
    /// What a sweep did, or would do on a dry run.
    public struct Sweep: Equatable, Sendable {
        public var isDryRun: Bool
        public var compacted: [String] = []
        public var archived: [String] = []
        /// What compaction frees on disk.
        public var freedBytes: Int64 = 0
        /// What archiving moves out of the live root; it is not freed.
        public var archivedBytes: Int64 = 0
        /// Set when another sweep held the lock and this one did nothing.
        public var wasBusy = false

        /// The report for the maestro.
        public func text(archive: URL) -> String {
            if wasBusy { return "another cleanup is running: nothing done" }
            let verbs = isDryRun ? ("would compact", "would archive") : ("compacted", "archived")
            return "\(isDryRun ? "dry run — " : "")\(verbs.0) \(compacted.count) run(s), freeing \(Self.megabytes(freedBytes)); "
                + "\(verbs.1) \(archived.count) run(s) (\(Self.megabytes(archivedBytes))) to \(archive.path)"
        }

        static func megabytes(_ bytes: Int64) -> String {
            String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
    }

    public static let compactAfter: TimeInterval = 30 * 86400
    public static let archiveAfter: TimeInterval = 180 * 86400
    /// The newest runs by start, which are never archived: the window the
    /// Scoreboard and the picker read (`recent(limit: 2000)`).
    public static let keptInHistory = 2000
    /// How often `sweepIfDue` sweeps.
    public static let sweepInterval: TimeInterval = 86400
    /// What compaction removes: what `summary.json` already says.
    static let compactable = ["stdout", "stderr", "prompt"]

    /// Where archived runs go: `runs-archive` beside the runs root.
    public var archiveRoot: URL {
        root.deletingLastPathComponent().appendingPathComponent("runs-archive", isDirectory: true)
    }

    /// Compacts and archives what is old enough, or says what it would.
    public func sweep(dryRun: Bool, now: Date = Date()) -> Sweep {
        sweep(dryRun: dryRun, now: now, maxSteps: .max)
    }

    /// Sweeps when the last sweep was more than a day ago, and notes it.
    /// Returns nil when it was not due. Blocks on git and the disk: call it
    /// off the main thread.
    @discardableResult
    public func sweepIfDue(now: Date = Date()) -> Sweep? {
        let marker = root.appendingPathComponent(".last-sweep")
        if let last = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date,
           now.timeIntervalSince(last) < Self.sweepInterval {
            return nil
        }
        let result = sweep(dryRun: false, now: now)
        if !result.wasBusy {
            try? Data(ISO8601DateFormatter().string(from: now).utf8).write(to: marker, options: .atomic)
        }
        return result
    }

    /// `maxSteps` stops the sweep after that many removals or moves, as a
    /// kill would: tests use it to prove each point in between is consistent.
    /// `keep` is `keptInHistory`, smaller in tests.
    func sweep(dryRun: Bool, now: Date, maxSteps: Int, keep: Int = Orchestrator.keptInHistory) -> Sweep {
        var result = Sweep(isDryRun: dryRun)
        let plan = plan(now: now, keep: keep)
        result.compacted = plan.compact.map(\.id)
        result.archived = plan.archive.map(\.id)
        result.freedBytes = plan.compact.reduce(0) { $0 + $1.bytes }
        result.archivedBytes = plan.archive.reduce(0) { $0 + $1.bytes }
        guard !dryRun else { return result }

        let done = withSweepLock { () -> Bool in
            var steps = 0
            for item in plan.compact {
                guard steps < maxSteps else { return true }
                for name in Self.compactable { try? FileManager.default.removeItem(at: file(item.id, name)) }
                steps += 1
            }
            for item in plan.archive {
                guard steps < maxSteps else { return true }
                archive(item.id, started: item.started)
                steps += 1
            }
            cache.index.rewrite(keeping: Set(cache.runIDs()))
            return true
        }
        if done == nil { return Sweep(isDryRun: false, wasBusy: true) }
        return result
    }

    // MARK: - Deciding

    private struct Planned {
        let id: String
        let started: Date
        let bytes: Int64
    }

    /// What a sweep at `now` compacts and archives, oldest first.
    private func plan(now: Date, keep: Int) -> (compact: [Planned], archive: [Planned]) {
        let runs = cache.runIDs().compactMap { id in record(id).map { (id: id, record: $0) } }
            .sorted { $0.record.started < $1.record.started }
        let kept = Set(runs.suffix(keep).map(\.id))
        var compact: [Planned] = []
        var archive: [Planned] = []
        for (id, record) in runs {
            let age = now.timeIntervalSince(record.started)
            guard age >= Self.compactAfter, !isInUse(id, record) else { continue }
            let removable = compactableBytes(id, record)
            if removable > 0 { compact.append(Planned(id: id, started: record.started, bytes: removable)) }
            if age >= Self.archiveAfter, !kept.contains(id) {
                let size = directorySize(root.appendingPathComponent(id)) - removable
                archive.append(Planned(id: id, started: record.started, bytes: size))
            }
        }
        return (compact, archive)
    }

    /// Whether anything still needs the run as it is: it runs, is paused,
    /// has its worktree or a live branch, or is being audited.
    private func isInUse(_ id: String, _ record: RunRecord) -> Bool {
        let exists = { FileManager.default.fileExists(atPath: $0) }
        if state(id, record) == .running { return true }
        if exists(file(id, "paused").path) { return true }
        if let tree = record.worktree, exists(tree) { return true }
        if let auditor = (try? String(contentsOf: file(id, "audit"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let auditRecord = self.record(auditor), state(auditor, auditRecord) == .running {
            return true
        }
        // A branch that was merged or discarded is closed; one that was not
        // is the user's work until they say, while git still has it.
        if let branch = record.branch, let repository = record.repository, !exists(file(id, "closed").path),
           exists(repository),
           Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repository).succeeded {
            return true
        }
        return false
    }

    /// What compacting the run would free; zero when it may not be compacted:
    /// only a finished run whose summary says everything is.
    private func compactableBytes(_ id: String, _ record: RunRecord) -> Int64 {
        guard case .finished = state(id, record), loadSummary(id) != nil else { return 0 }
        return Self.compactable.reduce(0) { $0 + fileSize(file(id, $1)) }
    }

    // MARK: - Doing

    /// Moves the run under `<archive>/<yyyy-mm>/`. One rename: the run is in
    /// one place or the other, never both, never half.
    private func archive(_ id: String, started: Date) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: started)
        let month = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        let folder = archiveRoot.appendingPathComponent(month, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        _ = rename(root.appendingPathComponent(id).path, destination.path)
    }

    /// Runs `body` holding the sweep lock, or returns nil when another sweep
    /// holds it: two sweeps at once would plan the same moves.
    private func withSweepLock<T>(_ body: () -> T) -> T? {
        let descriptor = open(root.appendingPathComponent(".sweep.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        return body()
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func directorySize(_ url: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let next = files?.nextObject() as? URL {
            total += Int64((try? next.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
