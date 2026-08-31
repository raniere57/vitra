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

    private(set) var directory: URL

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var entries: [DirectoryEntry] = []
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
        table.backgroundColor = PanelStyle.surface
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
        entries = DirectoryListing.entries(of: directory)
        table.reloadData()
        table.scrollRowToVisible(0)
    }

    /// How many files are listed, for the panel's header.
    var summary: String {
        "\(entries.count) items"
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
            cell.textField?.textColor = PanelStyle.secondaryText
            cell.imageView?.image = NSWorkspace.shared.icon(
                forFile: directory.deletingLastPathComponent().path
            )
            cell.toolTip = directory.deletingLastPathComponent().path
            return cell
        }

        cell.textField?.stringValue = entry.isDirectory ? entry.name + "/" : entry.name
        cell.textField?.textColor = entry.isDirectory ? PanelStyle.primaryText : PanelStyle.secondaryText
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
        label.font = PanelStyle.monospaced(11)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
