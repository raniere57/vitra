import Foundation
import VitraCore

/// One instruction lined up for the maestro.
struct QueuedPrompt: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    let created: Date
}

/// A project's "Fila": what the maestro is told next, in order, one prompt
/// each time it finishes a turn. Pure; `PromptQueueStore` does the file.
struct PromptQueue: Codable, Equatable {
    private(set) var items: [QueuedPrompt] = []
    /// Held: nothing is sent until the user resumes it.
    var isPaused = false

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var first: QueuedPrompt? { items.first }

    /// Adds `text` at the end; nothing for text that is only whitespace.
    @discardableResult
    mutating func add(_ text: String, now: Date, id: UUID = UUID()) -> QueuedPrompt? {
        let text = Self.clean(text)
        guard !text.isEmpty else { return nil }
        let prompt = QueuedPrompt(id: id, text: text, created: now)
        items.append(prompt)
        return prompt
    }

    /// Rewrites a prompt; emptied, it is removed.
    mutating func edit(_ id: UUID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let text = Self.clean(text)
        if text.isEmpty { items.remove(at: index) } else { items[index].text = text }
    }

    mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Moves a prompt so it ends up at `index` of the list as it is after the
    /// move; clamped to the ends.
    mutating func move(_ id: UUID, to index: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let prompt = items.remove(at: from)
        items.insert(prompt, at: min(max(index, 0), items.count))
    }

    /// Takes the first prompt off the queue.
    mutating func popNext() -> QueuedPrompt? {
        items.isEmpty ? nil : items.removeFirst()
    }

    /// Trailing whitespace goes: a stray newline at the end would be sent
    /// into the maestro's input as an extra empty line.
    private static func clean(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text.drop(while: \.isNewline).description
    }
}

/// The queues on disk: one JSON per project in the cockpit's state folder,
/// named by the same digest as the maestro's files. Not in the maestro
/// folder: the window redraws on every write there.
enum PromptQueueStore {
    static var directory: URL { Vitra.supportDirectory.appendingPathComponent("queues") }

    static func file(for project: String, in directory: URL = directory) -> URL {
        Maestro.sessionFile(for: project, in: directory)
    }

    /// The saved queue; empty when there is none. A file that cannot be read
    /// is moved aside, not overwritten by the next save.
    static func load(for project: String, in directory: URL = directory) -> PromptQueue {
        let url = file(for: project, in: directory)
        guard let data = try? Data(contentsOf: url) else { return PromptQueue() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let queue = try? decoder.decode(PromptQueue.self, from: data) { return queue }
        let aside = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return PromptQueue()
    }

    /// Written whole and atomically: a crash leaves the old queue or the new.
    static func save(_ queue: PromptQueue, for project: String, in directory: URL = directory) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(queue).write(to: file(for: project, in: directory), options: .atomic)
    }
}

/// When the head of the queue goes to the maestro. Pure.
enum QueueDispatch {
    /// What happened that might be the moment to send.
    enum Moment: Equatable {
        /// The attention state changed, as the window saw it.
        case transition(from: AttentionState?, to: AttentionState?)
        /// The user resumed a paused queue; the maestro is in `state`.
        case resumed(state: AttentionState?)
        /// A look again at a prompt held back because of the input line.
        case retry(state: AttentionState?)
    }

    enum Decision: Equatable {
        case send
        /// A moment to send, but not now; looked at again shortly.
        case holdForInput
        /// Not a moment to send at all.
        case none
    }

    /// `typedInput` is what sits unsent in the maestro's input line: nil when
    /// that cannot be read, which is treated as "something is there".
    static func decide(_ moment: Moment, isPaused: Bool, isEmpty: Bool, typedInput: String?) -> Decision {
        let isMoment: Bool = switch moment {
        // A turn just ended (the Stop hook). Not app start, where there is
        // no previous state, and not a file re-read with the same state.
        case let .transition(from, to): from == .working && to == .waiting
        case let .resumed(state), let .retry(state): state == .waiting
        }
        guard isMoment, !isPaused, !isEmpty else { return .none }
        guard let typedInput, typedInput.allSatisfy(\.isWhitespace) else { return .holdForInput }
        return .send
    }
}
