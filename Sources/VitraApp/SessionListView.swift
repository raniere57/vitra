import AppKit
import VitraCore

/// The Claude Code sessions on this machine, newest first.
///
/// The same store the CLI reads, so a conversation started in the desktop app
/// is one click from being resumed in whichever pane has the keyboard.
@MainActor
final class SessionListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// A session was chosen. It resumes in the pane that has the keyboard,
    /// which is the whole point: the sidebar drives the terminal you are in.
    var onOpen: ((ClaudeSession) -> Void)?

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "Reading sessions…")
    private var sessions: [ClaudeSession] = []
    /// The visible rows: a project header, then its sessions, and so on.
    private var rows: [Row] = []
    private var filter = ""
    private var hasLoaded = false

    /// A row is either a project's name or one of its sessions. Flattening the
    /// grouping into rows is what lets a plain table draw it, headers and all.
    private enum Row {
        case project(String, count: Int, collapsed: Bool)
        case session(ClaudeSession)
    }

    /// Projects the user has folded away. One busy project can hold twenty
    /// sessions, and without this it buries every other project below it.
    private var collapsed: Set<String> = []

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.rowHeight = 38
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.autoresizingMask = [.width, .height]

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)

        status.font = .systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            status.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Reads the store off the main thread, once per time the list is shown.
    ///
    /// Transcripts run to tens of megabytes and there are hundreds of them, so
    /// this never happens at launch and never on the thread that draws.
    func load(force: Bool = false) {
        guard force || !hasLoaded else { return }
        hasLoaded = true
        status.isHidden = false
        status.stringValue = "Reading sessions…"

        DispatchQueue.global(qos: .userInitiated).async {
            let sessions = ClaudeSessionStore.recent()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sessions = sessions
                self.applyFilter()
                self.status.isHidden = !sessions.isEmpty
                if sessions.isEmpty { self.status.stringValue = "No sessions in ~/.claude/projects" }
            }
        }
    }

    func setFilter(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed != filter else { return }
        filter = trimmed
        applyFilter()
    }

    func apply(_ config: Config) {
        let background = NSColor(hex: config.theme.background.hex) ?? .black
        table.backgroundColor = background.blended(withFraction: 0.04, of: .white) ?? background
    }

    private func applyFilter() {
        let matching = filter.isEmpty ? sessions : sessions.filter { session in
            session.title.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || session.projectName.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        // Projects in the order they were last worked on, and their sessions
        // newest first inside them: the list reads as recent work, not as a
        // directory listing.
        var order: [String] = []
        var grouped: [String: [ClaudeSession]] = [:]
        for session in matching {
            if grouped[session.projectName] == nil { order.append(session.projectName) }
            grouped[session.projectName, default: []].append(session)
        }

        rows = order.flatMap { project -> [Row] in
            let sessions = grouped[project] ?? []
            // A filter that matched inside a folded project opens it: hiding a
            // result behind a fold the search itself caused is a dead end.
            let isCollapsed = filter.isEmpty && collapsed.contains(project)
            let header = Row.project(project, count: sessions.count, collapsed: isCollapsed)
            return isCollapsed ? [header] : [header] + sessions.map(Row.session)
        }
        table.reloadData()
    }

    private func session(atRow row: Int) -> ClaudeSession? {
        guard row >= 0, row < rows.count, case let .session(session) = rows[row] else { return nil }
        return session
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }

        switch rows[row] {
        case let .project(name, _, _):
            if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
            applyFilter()
        case let .session(session):
            onOpen?(session)
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row < rows.count, case .project = rows[row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        session(atRow: row) != nil
    }

    /// Headers stay clickable while staying unselectable: folding a project is
    /// not choosing anything, so nothing should look chosen afterwards.
    func selectionShouldChange(in tableView: NSTableView) -> Bool { true }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        session(atRow: row) == nil ? 24 : 38
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let session = session(atRow: row) else {
            guard case let .project(name, count, isCollapsed) = rows[row] else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("project")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ProjectCell
                ?? ProjectCell(identifier: identifier)
            cell.name.stringValue = "\(isCollapsed ? "▸" : "▾")  \(name)"
            cell.count.stringValue = "\(count)"
            cell.toolTip = isCollapsed ? "Show \(count) sessions" : "Hide"
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SessionCell
            ?? SessionCell(identifier: identifier)

        cell.title.stringValue = session.title
        let when = Self.dateFormatter.localizedString(for: session.modified, relativeTo: Date())
        cell.detail.stringValue = session.worktree.map { "\(when) · \($0)" } ?? when
        cell.toolTip = "\(session.projectPath)\n\(session.id)"
        return cell
    }
}

/// A project's name, standing over the sessions that belong to it.
private final class ProjectCell: NSTableCellView {
    let name = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        name.font = .systemFont(ofSize: 10.5, weight: .semibold)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)
        textField = name

        count.font = .systemFont(ofSize: 10)
        count.textColor = .tertiaryLabelColor
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.translatesAutoresizingMaskIntoConstraints = false
        addSubview(count)

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            name.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -6),
            name.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            count.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// Two lines: what the session is called, and where and when it was.
private final class SessionCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        title.font = .systemFont(ofSize: 11.5)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = title

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}
