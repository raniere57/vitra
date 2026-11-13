import Foundation

/// What a finished run settles for good, written beside it as `summary.json`.
///
/// A run that has an exit code never changes again except for its rating, but
/// finding out what it said takes reading and parsing everything it printed,
/// which can be megabytes. That is done once; every later look reads this.
///
/// The answer's text is kept only up to `textLimit`: a list of runs shows a
/// line of it, a row opened in the cockpit a few thousand characters. Whoever
/// needs it whole asks `Orchestrator.status`, which goes back to stdout when
/// `isTextCut` says there was more.
struct RunSummary: Codable, Equatable, Sendable {
    /// 2: an empty answer and a timeout are failures, so a summary written
    /// before that says "finished" for runs that are no longer.
    /// 3: a run that did not run because of its provider says so.
    static let version = 3
    static let textLimit = 4000

    var version = RunSummary.version
    let exitCode: Int32
    /// When the exit code was written.
    let ended: Date?
    let errorTail: String?
    let commitError: String?
    let worktreeSkipped: [String]

    let text: String
    /// Whether `text` is the start of a longer answer.
    let isTextCut: Bool
    let isError: Bool
    let costUSD: Double
    let inputTokens: Int
    let outputTokens: Int
    let sessionID: String?
    let providerFailure: ProviderFailure?

    init(
        exitCode: Int32,
        ended: Date?,
        errorTail: String?,
        commitError: String?,
        worktreeSkipped: [String],
        output: WorkerOutput
    ) {
        self.exitCode = exitCode
        self.ended = ended
        self.errorTail = errorTail
        self.commitError = commitError
        self.worktreeSkipped = worktreeSkipped
        let characters = output.text
        isTextCut = characters.count > Self.textLimit
        text = isTextCut ? String(characters.prefix(Self.textLimit)) : characters
        isError = output.isError
        costUSD = output.costUSD
        inputTokens = output.inputTokens
        outputTokens = output.outputTokens
        sessionID = output.sessionID
        // A timeout is the run's own doing, and a delivery is no failure.
        let didNotDeliver = output.isError || exitCode != 0
        providerFailure = didNotDeliver && exitCode != Orchestrator.timeoutExitCode
            ? ProviderFailure.detect(text: output.text, errorTail: errorTail)
            : nil
    }

    var output: WorkerOutput {
        WorkerOutput(
            text: text,
            isError: isError,
            costUSD: costUSD,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            sessionID: sessionID
        )
    }
}

/// What this process has already read about runs, shared by every copy of the
/// `Orchestrator` struct that holds it.
///
/// The disk stays the truth: each entry is checked against the file's
/// modification time before it is believed, so another process rewriting a
/// run or rating it is seen on the next look.
final class RunCache: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: (modified: Date, record: RunRecord?)] = [:]
    private var summaries: [String: RunSummary] = [:]
    private var ratings: [String: (modified: Date?, rating: Rating?)] = [:]
    /// The run ids in the root, as of the root's modification time: a run
    /// added or taken away moves it.
    private var listing: (stamp: RunIndex.Stamp, ids: [String])?
    /// The settled runs, shared with every process through `<root>/.index`.
    let index: RunIndex
    private let root: URL

    init(root: URL) {
        self.root = root
        index = RunIndex(root: root)
    }

    /// One cache per runs root in a process, however many `Orchestrator`s
    /// are made for it: the cockpit makes one per look in places, and each
    /// would otherwise read the history cold.
    static func shared(for root: URL) -> RunCache {
        let key = root.standardizedFileURL.path
        return sharedLock.withLock {
            if let cache = shared[key] { return cache }
            let cache = RunCache(root: root)
            shared[key] = cache
            return cache
        }
    }

    /// Drops what this process knows of `root`, so the next look reads it
    /// as a new process would: for tests and the benchmark.
    static func forget(_ root: URL) {
        _ = sharedLock.withLock { shared.removeValue(forKey: root.standardizedFileURL.path) }
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var shared: [String: RunCache] = [:]

    /// The runs newest first by start, sorted again only when the root's
    /// listing changed. A run's start never changes, but a run directory is
    /// made before its record is written: an id whose `started` gave nil is
    /// asked again on every call until it answers.
    func newestFirst(started: (String) -> Date?) -> [(id: String, started: Date)] {
        guard let stamp = RunIndex.Stamp(of: root.path) else { return [] }
        var known = lock.withLock { ordering?.stamp == stamp ? ordering : nil }
        if known == nil {
            var dated: [(id: String, started: Date)] = []
            var missing: [String] = []
            for id in runIDs() {
                if let date = started(id) { dated.append((id, date)) } else { missing.append(id) }
            }
            known = (stamp, dated.sorted { $0.started > $1.started }, missing)
        } else if let current = known, !current.missing.isEmpty {
            let found = current.missing.compactMap { id in started(id).map { (id: id, started: $0) } }
            if !found.isEmpty {
                let missing = current.missing.filter { id in !found.contains { $0.id == id } }
                known = (stamp, (current.dated + found).sorted { $0.started > $1.started }, missing)
            }
        }
        guard let known else { return [] }
        lock.withLock { ordering = known }
        return known.dated
    }

    private var ordering: (stamp: RunIndex.Stamp, dated: [(id: String, started: Date)], missing: [String])?

    /// The ids of the runs in the root, listed again only when it changed.
    func runIDs() -> [String] {
        guard let stamp = RunIndex.Stamp(of: root.path) else { return [] }
        if let listing = lock.withLock({ listing }), listing.stamp == stamp { return listing.ids }
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(Orchestrator.isRunID)
        lock.withLock { listing = (stamp, ids) }
        return ids
    }

    func record(_ id: String, modified: Date) -> RunRecord?? {
        lock.withLock {
            guard let known = records[id], known.modified == modified else { return nil }
            return .some(known.record)
        }
    }

    func store(record: RunRecord?, _ id: String, modified: Date) {
        lock.withLock { records[id] = (modified, record) }
    }

    func summary(_ id: String) -> RunSummary? { lock.withLock { summaries[id] } }

    func store(summary: RunSummary, _ id: String) { lock.withLock { summaries[id] = summary } }

    func rating(_ id: String, modified: Date?) -> Rating?? {
        lock.withLock {
            guard let known = ratings[id], known.modified == modified else { return nil }
            return .some(known.rating)
        }
    }

    func store(rating: Rating?, _ id: String, modified: Date?) {
        lock.withLock { ratings[id] = (modified, rating) }
    }
}
