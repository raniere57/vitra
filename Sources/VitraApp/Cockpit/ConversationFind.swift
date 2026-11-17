import AppKit
import VitraCore
import VitraPanel

/// A match painted over the terminal: its cells, and whether it is the one
/// the find has stepped to.
struct FindHighlight: Equatable {
    let span: ConversationSearch.Span
    let isCurrent: Bool
}

/// ⌘F in the maestro's conversation: the find bar over the terminal, the
/// search run off the main thread as the query is typed, and the steps from
/// match to match.
///
/// The emulator's scrollback is addressed by screen row: a match is scrolled
/// to by moving the viewport the rows between it and the top, and painted
/// only while it is in the viewport.
@MainActor
final class ConversationFind {
    let bar = FindBar(placeholder: "buscar na conversa")
    /// The bar was put away; the keyboard goes back to the maestro.
    var onClose: (() -> Void)?

    private weak var terminal: TerminalView?
    private var matches: [ConversationSearch.Match] = []
    private var current: Int?
    private var search: Task<Void, Never>?
    /// Where the viewport was when the bar opened, to go back to if the user
    /// leaves without stepping to a match.
    private var openedAt: ScrollPosition?
    private var hasStepped = false

    /// How long typing must pause before a search starts: each keystroke
    /// would otherwise read the whole scrollback again.
    nonisolated private static let typingPause: Duration = .milliseconds(90)

    init() {
        bar.onChange = { [weak self] query in self?.run(query) }
        bar.onStep = { [weak self] _, forward in self?.step(forward: forward) }
        bar.onClose = { [weak self] _ in self?.closed() }
    }

    var isOpen: Bool { bar.superview != nil && !bar.isHidden }

    /// Shows the bar over `terminal`, inside `container`, and takes the keyboard.
    func open(over terminal: TerminalView, in container: NSView) {
        if !isOpen || self.terminal !== terminal {
            self.terminal = terminal
            openedAt = terminal.scrollPosition
            hasStepped = false
        }
        bar.reveal(in: container, top: CockpitStyle.Space.md)
        if !bar.query.isEmpty { run(bar.query) }
    }

    /// ⌘G and ⌘⇧G, and Enter in the bar.
    func step(forward: Bool) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        current = ((current ?? (forward ? -1 : count)) + (forward ? 1 : -1) + count) % count
        hasStepped = true
        reveal()
        show()
    }

    // MARK: - Searching

    private func run(_ query: String) {
        search?.cancel()
        guard let terminal, !query.isEmpty else {
            matches = []
            current = nil
            show()
            return
        }
        let session = terminal.session
        let columns = Int(session.size.columns)
        let top = terminal.scrollPosition.offset
        // Detached: reading and matching tens of thousands of rows is not work
        // for the main thread. The next keystroke cancels it.
        search = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: Self.typingPause)
            guard !Task.isCancelled else { return }
            let rows = ConversationSearch.rows(fromScreenText: session.screenText(), columns: columns)
            guard let found = ConversationSearch.matches(of: query, in: rows), !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.found(found, viewportTop: top)
            }
        }
    }

    /// New results: the current match is the first one from the top of the
    /// viewport down, so typing does not jump away from what is being read.
    private func found(_ found: [ConversationSearch.Match], viewportTop: Int) {
        matches = found
        current = found.isEmpty ? nil : (found.firstIndex { $0.row >= viewportTop } ?? found.count - 1)
        reveal()
        show()
    }

    private func reveal() {
        guard let current, matches.indices.contains(current) else { return }
        terminal?.reveal(screenRow: matches[current].row)
    }

    private func show() {
        bar.report(count: Self.counter(current: current, total: matches.count, hasQuery: !bar.query.isEmpty), isEmpty: matches.isEmpty)
        terminal?.findHighlights = matches.enumerated().flatMap { index, match in
            match.spans.map { FindHighlight(span: $0, isCurrent: index == current) }
        }
    }

    /// "3 de 17", "nenhuma" when nothing matched, nothing before a query.
    static func counter(current: Int?, total: Int, hasQuery: Bool) -> String? {
        guard hasQuery else { return nil }
        guard total > 0 else { return "nenhuma" }
        return "\((current ?? 0) + 1) de \(total)"
    }

    private func closed() {
        search?.cancel()
        terminal?.findHighlights = []
        // Nothing chosen: back to where the reading was.
        if !hasStepped, let openedAt { terminal?.restoreScroll(to: openedAt) }
        openedAt = nil
        onClose?()
    }
}
