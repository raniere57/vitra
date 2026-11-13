import AppKit
import VitraPanel

/// ⌘F over Leitura: the cockpit's find bar, matches counted off the main
/// thread over every loaded item, painted by the rows themselves, ⏎ and ⇧⏎
/// stepping from one to the next. Same forgiveness as the terminal's search.
@MainActor
final class LeituraFind {
    let bar = FindBar(placeholder: "buscar na leitura")
    var onClose: (() -> Void)?

    private weak var list: LeituraList?
    /// Every match, in reading order: the row's id and which of its matches.
    private var matches: [(row: String, index: Int)] = []
    private var current: Int?
    private var search: Task<Void, Never>?
    nonisolated private static let typingPause: Duration = .milliseconds(90)

    init(list: LeituraList) {
        self.list = list
        bar.onChange = { [weak self] query in self?.run(query) }
        bar.onStep = { [weak self] _, forward in self?.step(forward: forward) }
        bar.onClose = { [weak self] _ in self?.closed() }
    }

    var isOpen: Bool { bar.superview != nil && !bar.isHidden }

    func open(in container: NSView) {
        bar.reveal(in: container, top: CockpitStyle.Space.md)
        if !bar.query.isEmpty { run(bar.query) }
    }

    func step(forward: Bool) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        current = ((current ?? (forward ? -1 : count)) + (forward ? 1 : -1) + count) % count
        show(reveal: true)
    }

    /// The items changed under an open find: count again.
    func itemsChanged() {
        if isOpen, !bar.query.isEmpty { run(bar.query) }
    }

    private func run(_ query: String) {
        search?.cancel()
        guard let list, !query.isEmpty else {
            matches = []
            current = nil
            show(reveal: false)
            return
        }
        let items = list.rows.compactMap { row -> TranscriptItem? in if case let .item(item) = row { item } else { nil } }
        let firstVisible = list.table.rows(in: list.scroll.contentView.bounds).location
        search = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: Self.typingPause)
            guard !Task.isCancelled, let counts = LeituraSearch.counts(of: query, in: items) else { return }
            let found = zip(items, counts).flatMap { item, count in (0 ..< count).map { (row: item.id, index: $0) } }
            let firstFrom = items.indices.first { $0 >= firstVisible && counts[$0] > 0 }
            let startRow = firstFrom.map { items[$0].id }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.found(found, query: query, startingAt: startRow)
            }
        }
    }

    private func found(_ found: [(row: String, index: Int)], query: String, startingAt row: String?) {
        matches = found
        current = found.isEmpty ? nil : (found.firstIndex { $0.row == row } ?? found.count - 1)
        list?.context.query = query
        show(reveal: true)
    }

    private func show(reveal: Bool) {
        let context = list?.context
        context?.query = bar.query
        context?.currentMatch = current.map { matches[$0] }
        bar.report(count: ConversationFind.counter(current: current, total: matches.count, hasQuery: !bar.query.isEmpty), isEmpty: matches.isEmpty)
        list?.refreshHighlights()
        if reveal, let current { list?.reveal(row: matches[current].row) }
        list?.refreshHighlights()
    }

    private func closed() {
        search?.cancel()
        matches = []
        current = nil
        list?.context.query = ""
        list?.context.currentMatch = nil
        list?.refreshHighlights()
        onClose?()
    }
}
