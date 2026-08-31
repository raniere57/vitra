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
    private var filtered: [ClaudeSession] = []
    private var filter = ""
    private var hasLoaded = false

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
        filtered = filter.isEmpty ? sessions : sessions.filter { session in
            session.title.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || session.projectName.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        table.reloadData()
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < filtered.count else { return }
        onOpen?(filtered[row])
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SessionCell
            ?? SessionCell(identifier: identifier)

        let session = filtered[row]
        cell.title.stringValue = session.title
        cell.detail.stringValue = "\(session.projectName) · \(Self.dateFormatter.localizedString(for: session.modified, relativeTo: Date()))"
        cell.toolTip = "\(session.projectPath)\n\(session.id)"
        return cell
    }
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
