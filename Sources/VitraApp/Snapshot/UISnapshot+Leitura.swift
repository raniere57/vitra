import AppKit

/// Leitura's pictures: the whole window reading, at full and minimum size,
/// an opened activity, a wide table, the empty state and a permission wait.
extension UISnapshot {
    static let leituraShots: [Shot] = [
        Shot(name: "leitura", size: NSSize(width: 1440, height: 900), build: { try leitura($0, state: .working, draft: "E o dark mode do relatório, já dá pra ver?") }),
        Shot(name: "leitura-min", size: CockpitWindowController.minSize, build: { try leitura($0, state: .working) }),
        Shot(name: "leitura-permission", size: CockpitWindowController.minSize, build: { try leitura($0, state: .needsPermission) }),
        Shot(name: "leitura-activity", size: NSSize(width: 760, height: 820), build: { context in
            pane(context, items: conversation(context), state: .waiting, scrolledTo: "a2") { list in
                list.context.open(activity: "a2", call: "d4")
            }
        }),
        // The start of the turn: a pasted image, a run of calls opened, the
        // answer's list and table.
        Shot(name: "leitura-start", size: NSSize(width: 760, height: 820), build: { context in
            pane(context, items: conversation(context), state: .waiting, scrolledTo: "u1") { list in
                list.context.open(activity: "a1")
            }
        }),
        Shot(name: "leitura-table", size: NSSize(width: 760, height: 820), build: { context in
            pane(context, items: SnapshotLeitura.tableItems(now: context.fixtures.now), state: .waiting, scrolledTo: nil) { _ in }
        }),
        Shot(name: "leitura-empty", size: NSSize(width: 760, height: 600), build: { context in
            let view = LeituraView(project: CockpitProject(path: context.fixtures.path), transcripts: context.fixtures.project)
            view.showForSnapshot([], attention: nil, since: nil, missing: true)
            return view
        }),
    ]

    static func conversation(_ context: Context) -> [TranscriptItem] {
        let image = SnapshotLeitura.writeScreenshot(into: context.fixtures.project)
        return SnapshotLeitura.items(now: context.fixtures.now, project: context.fixtures.project, image: image)
    }

    /// The window with the maestro's pane in Leitura.
    static func leitura(_ context: Context, state: AttentionState, draft: String? = nil) throws -> NSView {
        let items = conversation(context)
        let since = context.fixtures.now.addingTimeInterval(-72)
        return try cockpit(context) { project in
            freezeClock(project.leitura, at: context.fixtures.now)
            project.isReading = true
            project.applyReading()
            project.leitura.showForSnapshot(items, queued: [UserMessage(id: "q1", time: Date(), text: "> O arquivo abre direto no Numbers e no Excel\n\ne no LibreOffice, abre também?", isQueued: true)], attention: state, since: since)
            project.leitura.list.context.open(activity: "a2")
            if let draft { project.leitura.composer.message = draft }
            if draft != nil {
                project.leitura.composer.addQuote("Fiquei com a entrega do b2179ee2: o cabeçalho sai em português e os valores usam vírgula decimal, como no relatório.")
                project.leitura.composer.layoutSubtreeIfNeeded()
            }
            project.pulseSwitch(state == .needsPermission)
        }
    }

    /// Leitura alone, as wide as a pane, scrolled to `row` if given.
    private static func pane(
        _ context: Context, items: [TranscriptItem], state: AttentionState,
        scrolledTo row: String?, configure: (LeituraList) -> Void
    ) -> NSView? {
        let view = LeituraView(project: CockpitProject(path: context.fixtures.path), transcripts: context.fixtures.project)
        configure(view.list)
        view.showForSnapshot(items, attention: state, since: nil)
        context.window.contentView?.addFilling(view)
        context.window.contentView?.layoutSubtreeIfNeeded()
        if let row { view.list.scroll(toRow: row) }
        return nil
    }

    /// The live row's clock stopped at `now`, so the picture says 1:12.
    private static func freezeClock(_ view: LeituraView, at now: Date) {
        view.list.context.now = { now }
    }
}
