import Foundation

/// The display items made from one contiguous stretch of a transcript.
///
/// A transcript is read in stretches — its tail first, older stretches as the
/// user scrolls up, appended bytes as the maestro writes them — and each is
/// made into a chunk on its own. `joined(_:)` then sews two neighbouring
/// chunks together: a run of tool calls cut in two by the seam becomes one
/// line again, a result whose call was in the older stretch finds it, an
/// image path finds the message it belongs to. So the whole conversation and
/// any way of reading it in pieces come out the same.
struct TranscriptChunk: Equatable, Sendable {
    private(set) var items: [TranscriptItem] = []
    /// Results whose call was not in this stretch: it is in an older one.
    private(set) var orphanResults: [ToolResult] = []
    /// Image paths met before any user message here.
    private(set) var leadingImageSources: [String] = []
    /// A command's answer met before any command here.
    private(set) var leadingCommandOutput: String?
    private(set) var firstTime: Date?
    private(set) var lastTime: Date?

    /// Silence longer than this gets a divider with the time.
    static let pause: TimeInterval = 5 * 60

    private var pendingThought = false
    /// Thoughts before any item here: they close the older stretch's run of
    /// calls, unless a call here takes them first.
    private var leadingThoughts = 0
    /// Where each call of this chunk sits: item index. Results find their
    /// call without a scan.
    private var callIndex: [String: Int] = [:]

    init() {}

    init(events: [TranscriptLine.Event]) {
        for event in events { apply(event) }
    }

    // MARK: - Folding events in

    mutating func apply(_ event: TranscriptLine.Event) {
        switch event {
        case let .userText(id, time, text):
            if case var .user(last) = items.last, last.id == id {
                last.text = last.text.isEmpty ? text : last.text + "\n\n" + text
                items[items.count - 1] = .user(last)
            } else {
                append(.user(UserMessage(id: id, time: time, text: text)), at: time)
            }
        case let .userImage(id, time, image):
            if case var .user(last) = items.last, last.id == id {
                last.images.append(image)
                items[items.count - 1] = .user(last)
            } else {
                append(.user(UserMessage(id: id, time: time, text: "", images: [image])), at: time)
            }
        case let .imageSource(path):
            if !attachSource(path) { leadingImageSources.append(path) }
        case let .command(id, time, text):
            append(.note(Note(id: id, time: time, kind: .command, text: text)), at: time)
        case let .commandOutput(output):
            if !attachOutput(output), leadingCommandOutput == nil { leadingCommandOutput = output }
        case let .shell(id, time, command):
            append(.note(Note(id: id, time: time, kind: .shell, text: "! " + command)), at: time)
        case let .interrupted(id, time):
            append(.note(Note(id: id, time: time, kind: .interrupted, text: "interrompido por você")), at: time)
        case let .task(id, time, summary):
            append(.note(Note(id: id, time: time, kind: .task, text: summary)), at: time)
        case let .assistantText(id, time, text):
            pendingThought = false
            if case var .answer(last) = items.last {
                last.markdown += "\n\n" + text
                items[items.count - 1] = .answer(last)
                touch(time)
            } else {
                append(.answer(Answer(id: id, time: time, markdown: text)), at: time)
            }
        case let .thinking(_, time):
            if case var .activity(last) = items.last {
                last.steps.append(.thought)
                items[items.count - 1] = .activity(last)
            } else {
                if items.isEmpty { leadingThoughts += 1 } else { pendingThought = true }
            }
            touch(time)
        case let .toolUse(id, time, call):
            if case var .activity(last) = items.last {
                last.steps.append(.call(call))
                items[items.count - 1] = .activity(last)
                touch(time)
            } else {
                let steps: [Activity.Step] = (pendingThought ? [.thought] : []) + [.call(call)]
                append(.activity(Activity(id: id, steps: steps)), at: time)
            }
            pendingThought = false
            callIndex[call.id] = items.count - 1
        case let .toolResult(result):
            if !resolve(result) { orphanResults.append(result) }
            touch(result.time)
        case let .compacted(id, time):
            append(.divider(ReadingDivider(id: id, time: time, kind: .compacted)), at: time, allowsPause: false)
        case let .turnDuration(id, time, seconds):
            append(.worked(Worked(id: id, time: time, seconds: seconds)), at: time, allowsPause: false)
        }
    }

    private mutating func append(_ item: TranscriptItem, at time: Date?, allowsPause: Bool = true) {
        if allowsPause, let time, let lastTime, time.timeIntervalSince(lastTime) > Self.pause {
            items.append(.divider(ReadingDivider(id: "pause-" + item.id, time: time, kind: .time)))
        }
        items.append(item)
        // A thought is the run of calls' that follows it, or nobody's.
        pendingThought = false
        touch(time)
    }

    private mutating func touch(_ time: Date?) {
        guard let time else { return }
        if firstTime == nil { firstTime = time }
        if lastTime.map({ time > $0 }) ?? true { lastTime = time }
    }

    @discardableResult
    private mutating func resolve(_ result: ToolResult) -> Bool {
        let candidates = callIndex[result.toolUseID].map { [$0] } ?? Array(items.indices.reversed())
        for index in candidates where items.indices.contains(index) {
            guard case var .activity(activity) = items[index], activity.resolve(result) else { continue }
            items[index] = .activity(activity)
            return true
        }
        return false
    }

    /// Gives a saved image's path to the latest image still without one.
    private mutating func attachSource(_ path: String) -> Bool {
        for index in items.indices.reversed() {
            guard case var .user(message) = items[index] else { continue }
            guard let slot = message.images.firstIndex(where: { $0.path == nil }) else { return true }
            message.images[slot].path = path
            items[index] = .user(message)
            return true
        }
        return false
    }

    private mutating func attachOutput(_ output: String) -> Bool {
        for index in items.indices.reversed() {
            guard case var .note(note) = items[index], note.kind == .command else { continue }
            if note.output == nil { note.output = output }
            items[index] = .note(note)
            return true
        }
        return false
    }

    // MARK: - Sewing chunks together

    /// This chunk followed by `newer`, the stretch that comes right after it.
    func joined(_ newer: TranscriptChunk) -> TranscriptChunk {
        var result = self
        result.callIndex = [:]
        for orphan in newer.orphanResults where !result.resolve(orphan) {
            result.orphanResults.append(orphan)
        }
        for source in newer.leadingImageSources where !result.attachSource(source) {
            result.leadingImageSources.append(source)
        }
        if let output = newer.leadingCommandOutput, !result.attachOutput(output), result.leadingCommandOutput == nil {
            result.leadingCommandOutput = output
        }
        // Thoughts that open the newer stretch: in the older one's run of
        // calls if it ends with one, else pending for the next run.
        var pending = result.pendingThought
        if result.items.isEmpty {
            result.leadingThoughts += newer.leadingThoughts
        } else if case var .activity(last)? = result.items.last {
            last.steps += Array(repeating: .thought, count: newer.leadingThoughts)
            result.items[result.items.count - 1] = .activity(last)
        } else if newer.leadingThoughts > 0 {
            pending = true
        }
        var incoming = newer.items[...]
        if pending, case var .activity(first)? = incoming.first, first.steps.first != .thought {
            first.steps.insert(.thought, at: 0)
            incoming = [.activity(first)] + incoming.dropFirst()
        }
        if let last = result.items.last, let first = incoming.first, let merged = Self.merge(last, first) {
            result.items[result.items.count - 1] = merged
            incoming = incoming.dropFirst()
        } else if let first = incoming.first, let lastTime = result.lastTime, let time = first.time,
                  time.timeIntervalSince(lastTime) > Self.pause, !Self.isDivider(first) {
            result.items.append(.divider(ReadingDivider(id: "pause-" + first.id, time: time, kind: .time)))
        }
        result.items += incoming
        result.firstTime = result.firstTime ?? newer.firstTime
        if let time = newer.lastTime, result.lastTime.map({ time > $0 }) ?? true { result.lastTime = time }
        result.pendingThought = newer.items.isEmpty ? pending && !result.items.isEmpty : newer.pendingThought
        return result
    }

    /// Two items that were one before the seam cut them.
    private static func merge(_ older: TranscriptItem, _ newer: TranscriptItem) -> TranscriptItem? {
        switch (older, newer) {
        case let (.activity(first), .activity(second)):
            return .activity(Activity(id: first.id, steps: first.steps + second.steps))
        case let (.answer(first), .answer(second)):
            return .answer(Answer(id: first.id, time: first.time, markdown: first.markdown + "\n\n" + second.markdown))
        default:
            return nil
        }
    }

    private static func isDivider(_ item: TranscriptItem) -> Bool {
        if case .divider = item { true } else { false }
    }

    /// Only the newest `count` items, for a window kept bounded.
    func suffix(_ count: Int) -> [TranscriptItem] { Array(items.suffix(count)) }
}
