import AppKit
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

/// Typed text must take the page's colour: an empty text view types in black,
/// which on the dark page reads as nothing being typed at all.
@MainActor
@Test func whatIsTypedInTheComposerIsVisible() {
    let composer = LeituraComposer(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
    for round in 0 ..< 2 {
        composer.text.insertText("oi", replacementRange: composer.text.selectedRange())
        let color = composer.text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == ReadingStyle.text, "round \(round)")
        composer.clear()
    }
}

/// The placeholder lies over the text: a click on it must still reach the
/// text, or the keyboard stays with the terminal underneath.
@MainActor
@Test func aClickOnTheComposersPlaceholderLandsInTheText() {
    let composer = LeituraComposer(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
    composer.layoutSubtreeIfNeeded()
    let onPlaceholder = NSPoint(x: composer.text.enclosingScrollView!.frame.midX, y: composer.text.enclosingScrollView!.frame.midY)
    #expect(composer.hitTest(onPlaceholder)?.isDescendant(of: composer.text.enclosingScrollView!) == true || composer.hitTest(onPlaceholder) === composer.text)
    #expect(composer.hitTest(NSPoint(x: 40, y: 60)) === composer.text)
}

@MainActor
@Test func aQuotedPassageIsAMarkdownBlockQuote() {
    #expect(LeituraView.quoted("  uma linha\n\noutra  ") == "> uma linha\n>\n> outra")
    #expect(LeituraView.quoted("  \n ") == "")
}
