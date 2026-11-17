import AppKit
import Testing
@testable import VitraApp

@MainActor
@Test func aDragFromOneAnswerIntoTheNextSelectsAcrossThem() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-cross-\(UUID().uuidString)")
    let view = LeituraView(project: CockpitProject(path: folder.path), transcripts: folder)
    window.contentView?.addFilling(view)
    let items: [TranscriptItem] = [
        .answer(Answer(id: "a1", time: nil, markdown: "Primeira resposta.")),
        .user(UserMessage(id: "u1", time: nil, text: "uma pergunta")),
        .answer(Answer(id: "a2", time: nil, markdown: "Segunda resposta aqui.")),
    ]
    view.showForSnapshot(items, attention: nil, since: nil)
    window.contentView?.layoutSubtreeIfNeeded()
    let list = view.list
    list.table.layoutSubtreeIfNeeded()

    func text(row: Int) throws -> ReadingTextView {
        let cell = try #require(list.table.view(atColumn: 0, row: row, makeIfNecessary: true))
        func find(_ view: NSView) -> ReadingTextView? {
            for sub in view.subviews {
                if let text = sub as? ReadingTextView { return text }
                if let text = find(sub) { return text }
            }
            return nil
        }
        return try #require(find(cell))
    }
    let first = try text(row: 0), last = try text(row: 2)
    list.crossSelection.start(in: first, anchor: 0)
    // Into the second answer, after "Segunda".
    let at = last.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 6, length: 1), in: last.textContainer!)
    list.crossSelection.extend(to: last.convert(NSPoint(x: at.maxX, y: at.midY), to: nil))

    #expect(list.crossSelection.selectedText() == "Primeira resposta.\n\numa pergunta\n\nSegunda")
}
