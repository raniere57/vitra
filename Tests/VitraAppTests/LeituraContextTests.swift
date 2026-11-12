import Foundation
import Testing
@testable import VitraApp

/// Opening a row tells the list, and the list asks the context at once
/// whether the row is open, to measure it. The context must have finished
/// changing by then: reading the set from inside its own change aborts the app.
@MainActor
@Test func openingARowCanBeReadBackFromInsideTheNotification() {
    let context = LeituraContext()
    var seen: [Bool] = []
    context.rowChanged = { id in
        seen.append(context.isOpen(activity: id) || context.isOpen(call: "c1") || context.showsFull(call: "c1"))
    }
    context.toggleActivity("a1")
    context.toggleCall("c1", in: "a1")
    context.showFullOutput("c1", in: "a1")
    context.toggleActivity("a1")
    #expect(seen == [true, true, true, true])
    #expect(!context.isOpen(activity: "a1"))
}

@Suite("Leitura: prompts waiting in Claude Code's queue")
struct LeituraQueueTests {
    private func line(_ operation: String, _ content: String?) -> Data {
        var entry: [String: Any] = ["type": "queue-operation", "operation": operation, "timestamp": "2026-11-12T00:25:10.612Z"]
        if let content { entry["content"] = content }
        return try! JSONSerialization.data(withJSONObject: entry)
    }

    private func chunk(_ lines: [Data]) -> TranscriptChunk {
        TranscriptChunk(events: lines.flatMap(TranscriptLine.events(from:)))
    }

    @Test func aPromptTypedMidTurnWaitsUntilItIsTaken() {
        let waiting = chunk([line("enqueue", "primeira"), line("enqueue", "segunda")])
        #expect(waiting.queued.map(\.text) == ["primeira", "segunda"])
        #expect(waiting.queued.filter(\.isQueued).count == 2)

        let taken = chunk([line("enqueue", "primeira"), line("enqueue", "segunda"), line("remove", "segunda"), line("dequeue", nil)])
        #expect(taken.queued.isEmpty)
    }

    @Test func aPromptTakenInALaterStretchLeavesTheQueueOfTheOlderOne() {
        let older = chunk([line("enqueue", "espera")])
        let newer = chunk([line("remove", "espera"), line("enqueue", "outra")])
        #expect(older.joined(newer).queued.map(\.text) == ["outra"])
    }

    @Test func aBackgroundTaskNoticeIsNotTheUsersPrompt() {
        #expect(chunk([line("enqueue", "<task-notification><summary>fim</summary></task-notification>")]).queued.isEmpty)
    }
}
