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
    static let version = 1
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
