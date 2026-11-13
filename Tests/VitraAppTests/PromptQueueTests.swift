import Foundation
import Testing
@testable import VitraApp

/// The Fila: the list itself, its file, and when its head goes out.
struct PromptQueueTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func queue(_ texts: [String]) -> PromptQueue {
        var queue = PromptQueue()
        texts.forEach { queue.add($0, now: now) }
        return queue
    }

    @Test func addKeepsOrderAndRefusesBlank() {
        var queue = queue(["a", "b"])
        #expect(queue.add("  \n ", now: now) == nil)
        #expect(queue.add("c\n\n", now: now)?.text == "c")
        #expect(queue.items.map(\.text) == ["a", "b", "c"])
    }

    @Test func multiLinePromptsKeepTheirInnerLines() {
        let queue = queue(["primeira\nsegunda"])
        #expect(queue.first?.text == "primeira\nsegunda")
    }

    @Test func editRewritesAndEmptyRemoves() throws {
        var queue = queue(["a", "b"])
        let id = try #require(queue.first?.id)
        queue.edit(id, text: "a2")
        #expect(queue.items.map(\.text) == ["a2", "b"])
        queue.edit(id, text: "   ")
        #expect(queue.items.map(\.text) == ["b"])
        queue.edit(UUID(), text: "ninguém")
        #expect(queue.count == 1)
    }

    @Test func removeTakesOnlyThatOne() {
        var queue = queue(["a", "b", "c"])
        queue.remove(queue.items[1].id)
        #expect(queue.items.map(\.text) == ["a", "c"])
    }

    @Test func moveToEitherEndAndClamp() {
        var queue = queue(["a", "b", "c"])
        queue.move(queue.items[2].id, to: 0)
        #expect(queue.items.map(\.text) == ["c", "a", "b"])
        queue.move(queue.items[0].id, to: 99)
        #expect(queue.items.map(\.text) == ["a", "b", "c"])
        queue.move(queue.items[1].id, to: -3)
        #expect(queue.items.map(\.text) == ["b", "a", "c"])
    }

    @Test func popNextTakesTheHead() {
        var queue = queue(["a", "b"])
        #expect(queue.popNext()?.text == "a")
        #expect(queue.popNext()?.text == "b")
        #expect(queue.popNext() == nil)
    }

    @Test func persistsAndReadsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-fila-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var saved = queue(["a", "b\nc"])
        saved.isPaused = true
        try PromptQueueStore.save(saved, for: "/tmp/proj", in: dir)
        #expect(PromptQueueStore.load(for: "/tmp/proj", in: dir) == saved)
        #expect(PromptQueueStore.load(for: "/tmp/other", in: dir) == PromptQueue())
    }

    @Test func corruptFileIsMovedAsideNotLost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-fila-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = PromptQueueStore.file(for: "/tmp/proj", in: dir)
        try Data("{ not json".utf8).write(to: file)
        #expect(PromptQueueStore.load(for: "/tmp/proj", in: dir) == PromptQueue())
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

/// When the head of the queue goes to the maestro.
struct QueueDispatchTests {
    private typealias D = QueueDispatch

    @Test func sendsWhenATurnEnds() {
        #expect(D.decide(.transition(from: .working, to: .waiting), isPaused: false, isEmpty: false, typedInput: "") == .send)
    }

    @Test(arguments: [
        (AttentionState?.none, AttentionState?.some(.waiting)),
        (.waiting, .waiting),
        (.needsPermission, .waiting),
        (.working, .needsPermission),
        (.waiting, .working),
        (.working, nil),
    ])
    func otherTransitionsAreNoMoment(from: AttentionState?, to: AttentionState?) {
        #expect(D.decide(.transition(from: from, to: to), isPaused: false, isEmpty: false, typedInput: "") == .none)
    }

    @Test func pausedOrEmptySendsNothing() {
        let end = D.Moment.transition(from: .working, to: .waiting)
        #expect(D.decide(end, isPaused: true, isEmpty: false, typedInput: "") == .none)
        #expect(D.decide(end, isPaused: false, isEmpty: true, typedInput: "") == .none)
    }

    @Test func userTypingOrUnreadableInputHolds() {
        let end = D.Moment.transition(from: .working, to: .waiting)
        #expect(D.decide(end, isPaused: false, isEmpty: false, typedInput: "meio escrito") == .holdForInput)
        #expect(D.decide(end, isPaused: false, isEmpty: false, typedInput: nil) == .holdForInput)
        #expect(D.decide(end, isPaused: false, isEmpty: false, typedInput: "   ") == .send)
    }

    @Test func retryAndResumeSendOnlyWhileWaiting() {
        #expect(D.decide(.retry(state: .waiting), isPaused: false, isEmpty: false, typedInput: "") == .send)
        #expect(D.decide(.retry(state: .working), isPaused: false, isEmpty: false, typedInput: "") == .none)
        #expect(D.decide(.retry(state: .needsPermission), isPaused: false, isEmpty: false, typedInput: "") == .none)
        #expect(D.decide(.resumed(state: .waiting), isPaused: false, isEmpty: false, typedInput: "") == .send)
        #expect(D.decide(.resumed(state: nil), isPaused: false, isEmpty: false, typedInput: "") == .none)
    }
}
