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
    private let footer = NSStackView()
    private let archivedLabel = NSTextField(labelWithString: "")
    private let archivedButton = NSButton()
    private var sessions: [ClaudeSession] = []
    /// The visible rows: a project header, then its sessions, and so on.
    private var rows: [Row] = []
    private var filter = ""
    /// The session running in the pane that has the keyboard, if it is one of
    /// these. Marked rather than selected: selection is what the user clicked
    /// last, which is a different question.
    private var current: String?
    private var hasLoaded = false
    private var archivedHidden = 0
    private var showsArchived = false

    /// A row is either a project's name or one of its sessions. Flattening the
    /// grouping into rows is what lets a plain table draw it, headers and all.
    private enum Row {
        case project(String, count: Int, collapsed: Bool)
        case session(ClaudeSession)
    }

    /// Projects the user has opened. Everything starts folded: one busy project
    /// holds twenty sessions, and open by default that is all the sidebar shows.
    private var expanded: Set<String> = []

    /// Colours for the project dots, taken in order and kept per project so a
    /// project keeps its colour for as long as the list is open.
    private static let dotColors: [NSColor] = [
        NSColor(srgbRed: 0.55, green: 0.76, blue: 0.40, alpha: 1),
        NSColor(srgbRed: 0.84, green: 0.65, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.35, green: 0.65, blue: 0.88, alpha: 1),
        NSColor(srgbRed: 0.75, green: 0.49, blue: 0.91, alpha: 1),
        NSColor(srgbRed: 0.31, green: 0.72, blue: 0.69, alpha: 1),
        NSColor(srgbRed: 0.88, green: 0.33, blue: 0.38, alpha: 1),
    ]
    private var dotColor: [String: NSColor] = [:]

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
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
        ])

        status.font = .systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)

        // The line that owns up to what is missing: sessions put away in the
        // app are hidden here, and hiding them silently is how a list starts
        // lying about what it is.
        archivedLabel.font = .systemFont(ofSize: 10.5)
        archivedLabel.textColor = .tertiaryLabelColor
        archivedButton.font = .systemFont(ofSize: 10.5)
        archivedButton.isBordered = false
        archivedButton.bezelStyle = .inline
        archivedButton.contentTintColor = .controlAccentColor
        archivedButton.target = self
        archivedButton.action = #selector(toggleArchived)

        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 8)
        footer.addArrangedSubview(archivedLabel)
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(archivedButton)
        footer.isHidden = true
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)

        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            status.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])
    }

    @objc private func toggleArchived() {
        showsArchived.toggle()
        load(force: true)
    }

    private func syncArchivedFooter() {
        let hidden = showsArchived ? 0 : archivedHidden
        footer.isHidden = hidden == 0 && !showsArchived
        archivedLabel.stringValue = showsArchived
            ? "Showing archived sessions"
            : "\(hidden) archived hidden"
        archivedButton.title = showsArchived ? "hide" : "show"
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

        let includeArchived = showsArchived
        DispatchQueue.global(qos: .userInitiated).async {
            let listing = ClaudeSessionStore.recent(includeArchived: includeArchived)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sessions = listing.sessions
                self.archivedHidden = includeArchived ? 0 : listing.archivedHidden
                self.applyFilter()
                self.status.isHidden = !listing.sessions.isEmpty
                if listing.sessions.isEmpty {
                    self.status.stringValue = "No sessions in ~/.claude/projects"
                }
                self.syncArchivedFooter()
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
            let isCollapsed = filter.isEmpty && !expanded.contains(project)
            let header = Row.project(project, count: sessions.count, collapsed: isCollapsed)
            return isCollapsed ? [header] : [header] + sessions.map(Row.session)
        }
        table.reloadData()
    }

    /// The colour that marks a project, handed out in order and then kept.
    private func color(for project: String) -> NSColor {
        if let existing = dotColor[project] { return existing }
        let color = Self.dotColors[dotColor.count % Self.dotColors.count]
        dotColor[project] = color
        return color
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
            if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
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
        session(atRow: row) == nil ? 26 : 40
    }

    /// A hairline above every session that follows another one.
    ///
    /// Not above the first of a group — the header is already a boundary — and
    /// never below the last, so a group reads as one block of rows.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SeparatorRowView()
        view.drawsSeparator = row > 0 && session(atRow: row) != nil && session(atRow: row - 1) != nil
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let session = session(atRow: row) else {
            guard case let .project(name, count, isCollapsed) = rows[row] else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("project")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ProjectCell
                ?? ProjectCell(identifier: identifier)
            cell.name.stringValue = "\(isCollapsed ? "▸" : "▾")  \(name)"
            cell.count.stringValue = "\(count)"
            cell.dot.color = color(for: name)
            cell.toolTip = isCollapsed ? "Show \(count) sessions" : "Hide"
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SessionCell
            ?? SessionCell(identifier: identifier)

        cell.title.stringValue = session.title
        cell.detail.stringValue = SessionDate.label(for: session.modified)
        cell.worktree.stringValue = session.worktree ?? ""
        cell.worktree.isHidden = session.worktree == nil
        cell.toolTip = "\(session.projectPath)\n\(session.id)"
        cell.isCurrent = session.id == current
        return cell
    }
}

extension SessionListView {
    /// Marks the session the focused pane is running. Nil unmarks.
    func setCurrent(_ id: String?) {
        guard id != current else { return }
        current = id
        table.reloadData()
    }
}

/// A project's name, standing over the sessions that belong to it.
private final class ProjectCell: NSTableCellView {
    let name = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    let dot = DotView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

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
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.centerYAnchor.constraint(equalTo: name.centerYAnchor),

            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -6),
            name.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            count.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// The project's colour, as a dot beside its name.
final class DotView: NSView {
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Two lines: what the session is called, then when it was and, if it ran in
/// one, which worktree — as a whole label rather than a truncated path.
private final class SessionCell: NSTableCellView {
    /// The session this pane is in: an accent rail down the leading edge, and a
    /// title that carries its weight. Loud enough to find at a glance, quiet
    /// enough not to compete with the row the user is about to click.
    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue else { return }
            title.font = .systemFont(ofSize: 12, weight: isCurrent ? .semibold : .regular)
            needsDisplay = true
        }
    }

    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let worktree = ChipLabel(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        title.font = .systemFont(ofSize: 12)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)

        worktree.font = .systemFont(ofSize: 9.5)
        worktree.textColor = NSColor(srgbRed: 0.72, green: 0.62, blue: 0.86, alpha: 1)
        worktree.lineBreakMode = .byTruncatingMiddle

        let meta = NSStackView(views: [detail, worktree, NSView()])
        meta.orientation = .horizontal
        meta.alignment = .centerY
        meta.spacing = 6

        let stack = NSStackView(views: [title, meta])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = title

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isCurrent else { return }
        SessionCell.rail.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 4, width: 2.5, height: bounds.height - 8),
            xRadius: 1.25,
            yRadius: 1.25
        ).fill()
    }

    private static let rail = NSColor(srgbRed: 0.486, green: 0.753, blue: 1, alpha: 1)

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// A label with a tinted pill behind it.
final class ChipLabel: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        guard !stringValue.isEmpty else { return }
        textColor?.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: -4, dy: -1), xRadius: 3, yRadius: 3).fill()
        super.draw(dirtyRect)
    }
}

/// A row that draws the hairline between it and the row above.
private final class SeparatorRowView: NSTableRowView {
    var drawsSeparator = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard drawsSeparator else { return }
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: 6, y: bounds.maxY - 1, width: bounds.width - 12, height: 1).fill()
    }
}
