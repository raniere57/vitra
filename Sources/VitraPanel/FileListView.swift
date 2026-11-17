import AppKit
import VitraCore

/// The files of one directory, listed in the side panel.
///
/// It is handed a directory and reports clicks; it does not know that the
/// directory came from a terminal, or that opening a folder will be typed into
/// a shell. One click opens — the panel is already the preview, so asking for
/// a second click would only be ceremony.
final class FileListView: NSView, PreviewContentView, NSTableViewDataSource, NSTableViewDelegate {
    var onOpenFile: ((URL) -> Void)?
    var onOpenDirectory: ((URL) -> Void)?
    /// The listing arrived: it is read off the main thread, so whoever shows
    /// the count has to be told when there is one.
    var onListed: (() -> Void)?

    private(set) var directory: URL

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var entries: [DirectoryEntry] = []
    /// Drops a listing that finished after the directory had already moved on.
    private var listingToken = 0
    /// Whether the list starts with a row for the parent directory.
    private var showsParent: Bool { directory.pathComponents.count > 1 }

    init(directory: URL) {
        self.directory = directory
        super.init(frame: .zero)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.rowHeight = 20
        table.backgroundColor = Theme.panel
        table.gridStyleMask = []
        table.style = .plain
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

        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Points the list at another directory, or re-reads the one it is on.
    func show(_ directory: URL) {
        self.directory = directory
        reload()
    }

    func reload() {
        // Dotfiles included: the panel is for looking at what a project has,
        // and `.env`, `.gitignore` and a `.github/` are what it has.
        // contentsOfDirectory plus a stat per name is work a large folder
        // should not do on the main thread before the table can draw.
        listingToken += 1
        let token = listingToken
        let directory = self.directory
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = DirectoryListing.entries(of: directory, includeHidden: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.listingToken, self.directory == directory else { return }
                self.entries = entries
                self.table.reloadData()
                self.table.scrollRowToVisible(0)
                self.onListed?()
            }
        }
    }

    /// How many files are listed, for the panel's header.
    var summary: String {
        "\(entries.count) \(entries.count == 1 ? "item" : "itens")"
    }

    private func entry(atRow row: Int) -> DirectoryEntry? {
        let offset = showsParent ? 1 : 0
        guard row >= offset, row - offset < entries.count else { return nil }
        return entries[row - offset]
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }

        guard let entry = entry(atRow: row) else {
            onOpenDirectory?(directory.deletingLastPathComponent())
            return
        }
        if entry.isDirectory {
            onOpenDirectory?(entry.url)
        } else {
            onOpenFile?(entry.url)
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count + (showsParent ? 1 : 0)
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier)

        guard let entry = entry(atRow: row) else {
            cell.textField?.stringValue = "../"
            cell.textField?.textColor = Theme.muted
            cell.imageView?.image = NSWorkspace.shared.icon(
                forFile: directory.deletingLastPathComponent().path
            )
            cell.toolTip = directory.deletingLastPathComponent().path
            return cell
        }

        cell.textField?.stringValue = entry.isDirectory ? entry.name + "/" : entry.name
        cell.textField?.textColor = entry.isDirectory ? Theme.text : Theme.muted
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        cell.toolTip = entry.url.path
        return cell
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.imageView = icon

        let label = NSTextField(labelWithString: "")
        label.font = Theme.meta
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            // The table sets its cells 8 pt in from its edge by itself.
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.inset - Theme.Space.md),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Theme.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Theme.iconSize),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Space.md),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Theme.inset),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
