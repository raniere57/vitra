import Foundation

/// What Leitura shows, one entry per row: the maestro's conversation as it is
/// read, not as it was logged.
///
/// Claude Code logs every block of a reply as an entry of its own, and every
/// tool result as a "user" turn. Read like that it is the soup the terminal
/// prints. These items are the conversation regrouped: what the user said,
/// what the maestro answered, and — folded into one line — everything it did
/// in between.
///
/// Plain values, `Sendable`: they are made off the main thread from the
/// transcript and handed to the view whole.
enum TranscriptItem: Equatable, Sendable, Identifiable {
    case user(UserMessage)
    case answer(Answer)
    case activity(Activity)
    case divider(ReadingDivider)
    case note(Note)
    /// "trabalhou 4m 0s", under the turn it closes.
    case worked(Worked)

    var id: String {
        switch self {
        case let .user(message): message.id
        case let .answer(answer): answer.id
        case let .activity(activity): activity.id
        case let .divider(divider): divider.id
        case let .note(note): note.id
        case let .worked(worked): worked.id
        }
    }

    /// When the entry that began it was written; nil when the log had no time.
    var time: Date? {
        switch self {
        case let .user(message): message.time
        case let .answer(answer): answer.time
        case let .activity(activity): activity.started
        case let .divider(divider): divider.time
        case let .note(note): note.time
        case let .worked(worked): worked.time
        }
    }
}

/// What the user typed, with the images they pasted.
struct UserMessage: Equatable, Sendable {
    let id: String
    var time: Date?
    var text: String
    var images: [ImageRef] = []
}

/// A pasted image: the file Claude Code saved it to when the log says so,
/// else the bytes the log carries.
struct ImageRef: Equatable, Sendable {
    var path: String?
    var base64: String?
    var mediaType: String?
}

/// A piece of the maestro's reply in its own words, as Markdown. Consecutive
/// text blocks of one reply are one answer.
struct Answer: Equatable, Sendable {
    let id: String
    var time: Date?
    var markdown: String
}

/// The run of tool calls between two pieces of text, folded into one line.
struct Activity: Equatable, Sendable {
    let id: String
    var steps: [Step]

    enum Step: Equatable, Sendable {
        case call(ToolCall)
        /// Where the maestro thought before acting: only a faint marker.
        case thought
    }

    var calls: [ToolCall] {
        steps.compactMap { if case let .call(call) = $0 { call } else { nil } }
    }

    var started: Date? { calls.compactMap(\.started).min() }

    /// From the first call's start to the last result, when both are known.
    var duration: TimeInterval? {
        guard let start = started, let end = calls.compactMap(\.finished).max(), end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    var failures: Int { calls.filter(\.isError).count }
    var running: ToolCall? { calls.last { $0.status == .running } }

    /// The tool that did most of the work, for the row's icon.
    var dominantIcon: String {
        var counts: [String: Int] = [:]
        for call in calls { counts[call.icon, default: 0] += 1 }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? ToolSummary.genericIcon
    }

    /// Gives `result` to the call it answers; false when none here asked.
    mutating func resolve(_ result: ToolResult) -> Bool {
        for index in steps.indices.reversed() {
            guard case var .call(call) = steps[index], call.id == result.toolUseID else { continue }
            call.apply(result)
            steps[index] = .call(call)
            return true
        }
        return false
    }
}

/// One tool call: what it was, said in a line, and how it went.
struct ToolCall: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case running
        case ok
        /// The first line of what went wrong.
        case error(String)
    }

    let id: String
    let name: String
    var summary: String
    /// An SF Symbol name.
    var icon: String
    /// The input as it is shown when the call is opened.
    var input: String
    /// A file the call is about, opened in the preview on a click.
    var filePath: String?
    /// The worker a delegation started or a rating named, when known.
    var workerID: String?
    var added: Int?
    var removed: Int?
    var started: Date?
    var finished: Date?
    var status: Status = .running
    var output: String = ""
    /// The output was longer than is kept.
    var isOutputClipped = false

    var isError: Bool { if case .error = status { true } else { false } }

    var duration: TimeInterval? {
        guard let started, let finished, finished >= started else { return nil }
        return finished.timeIntervalSince(started)
    }

    mutating func apply(_ result: ToolResult) {
        finished = result.time
        output = result.text
        isOutputClipped = result.isClipped
        status = result.isError ? .error(Self.firstLine(of: result.text)) : .ok
        if workerID == nil, name.hasSuffix("agent_spawn") { workerID = ToolSummary.workerID(inResult: result.text) }
    }

    static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map { String($0.trimmingCharacters(in: .whitespaces).prefix(160)) } ?? "erro"
    }
}

/// A tool's answer, as the log gives it in the next "user" entry.
struct ToolResult: Equatable, Sendable {
    let toolUseID: String
    var time: Date?
    var isError: Bool
    var text: String
    var isClipped: Bool
}

/// A quiet break in the reading: time passed, or the conversation was compacted.
struct ReadingDivider: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case time
        case compacted
    }

    let id: String
    var time: Date?
    var kind: Kind
}

/// A one-line aside: a slash command and what it said, a shell command typed
/// with `!`, an interruption, a background task finishing.
struct Note: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case command
        case shell
        case interrupted
        case task
    }

    let id: String
    var time: Date?
    var kind: Kind
    var text: String
    /// The command's answer, joined to it with an arrow once it arrives.
    var output: String?

    var line: String {
        guard let output, !output.isEmpty else { return text }
        return text + " → " + output
    }
}

struct Worked: Equatable, Sendable {
    let id: String
    var time: Date?
    var seconds: TimeInterval
}

/// Durations the way Claude Code prints them: "12s", "4m 12s", "1h 3m".
enum ReadingDuration {
    static func text(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 0))s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// "1:12", "12:05", "1:02:03": the live row's clock.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
