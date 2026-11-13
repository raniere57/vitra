import AppKit

extension UISnapshot {
    /// The maestro header at the narrowest window with the update pill, as
    /// it is for a maestro that survived a reinstall, and once armed.
    static func update(_ context: Context, _ phase: MaestroUpdateState.Phase) throws -> NSView {
        try cockpit(context) { project in project.showUpdate(phase) }
    }

    /// The Fila under the header: open with three prompts, the second being
    /// edited, or collapsed to its pill.
    static func fila(_ context: Context, expanded: Bool) throws -> NSView {
        let queue = filaQueue(now: context.fixtures.now)
        return try cockpit(context) { project in
            project.showQueue(queue, expanded: expanded, editing: expanded ? queue.items[1].id : nil)
        }
    }

    private static func filaQueue(now: Date) -> PromptQueue {
        var queue = PromptQueue()
        let texts = [
            "Rode a suíte inteira e me diga o que quebrou",
            "Depois revise o diff do GitPanel com calma.\nFoque nos nomes e nos comentários; não mexa no layout.",
            "Se tudo passar, abra o PR com um resumo curto",
        ]
        for (index, text) in texts.enumerated() {
            queue.add(text, now: now.addingTimeInterval(TimeInterval(index)), id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)") ?? UUID())
        }
        return queue
    }
}
