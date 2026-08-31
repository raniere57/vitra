import AppKit
import VitraCore

/// The directory tree in the expanded sidebar.
///
/// Clicking a folder is `cd`, not "open somewhere else": the tree drives the
/// terminal you are already in, and Cmd-click is the exception that opens a
/// tab. Children are read when a folder is expanded, never before — a tree
/// that stats the whole disk to draw ten rows is the reason file sidebars feel
/// heavy.
@MainActor
final class DirectoryTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// A folder was chosen: `newTab` is true when Cmd was held.
    var onOpen: ((URL, Bool) -> Void)?

    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var roots: [Node] = []
    /// Where the terminal is, so the row can be lit even after the user has
    /// scrolled somewhere else in the tree.
    private var current: URL?

    /// One folder in the tree. A class because the outline view identifies
    /// items by pointer, and because children are filled in later.
    final class Node {
        let url: URL
        let label: String
        let emoji: String?
        private(set) var children: [Node]?

        init(url: URL, label: String? = nil, emoji: String? = nil) {
            self.url = url
            self.label = label ?? url.lastPathComponent
            self.emoji = emoji
        }

        /// The subdirectories, read once and kept until `reload()`.
        func loadedChildren() -> [Node] {
            if let children { return children }
            let loaded = DirectoryListing.directories(of: url).map { Node(url: $0.url) }
            children = loaded
            return loaded
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = 20
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular
        outline.style = .inset
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.autoresizingMask = [.width, .height]

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The folders the tree starts from: the favourites, and home.
    func setRoots(_ bookmarks: [Bookmark]) {
        var roots = bookmarks.filter(\.exists).map { Node(url: $0.url, label: $0.name, emoji: $0.emoji) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if !roots.contains(where: { $0.url.path == home.path }) {
            roots.append(Node(url: home, label: "Home", emoji: "🏠"))
        }
        self.roots = roots
        outline.reloadData()
        reveal(current)
    }

    /// Lights the folder the terminal is in, opening the tree down to it.
    ///
    /// A directory outside every root gets one of its own rather than being
    /// dropped: a shell that wandered into `/usr/local` should still be
    /// findable in the sidebar it is supposed to be tracking.
    func reveal(_ url: URL?) {
        current = url
        guard let url else {
            outline.deselectAll(nil)
            return
        }

        if findRoot(for: url) == nil {
            roots.append(Node(url: url))
            outline.reloadData()
        }
        guard let root = findRoot(for: url) else { return }

        var node = root
        let rootComponents = root.url.pathComponents
        for component in url.pathComponents.dropFirst(rootComponents.count) {
            outline.expandItem(node)
            guard let next = node.loadedChildren().first(where: { $0.url.lastPathComponent == component })
            else { break }
            node = next
        }

        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    func apply(_ config: Config) {
        let background = NSColor(hex: config.theme.background.hex) ?? .black
        outline.backgroundColor = background.blended(withFraction: 0.04, of: .white) ?? background
    }

    private func findRoot(for url: URL) -> Node? {
        // The deepest matching root, so a favourite inside home wins over home.
        roots
            .filter { url.path == $0.url.path || url.path.hasPrefix($0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        onOpen?(node.url, NSEvent.modifierFlags.contains(.command))
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return roots.count }
        return node.loadedChildren().count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
        return node.loadedChildren()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return !node.loadedChildren().isEmpty
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("row")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier)

        cell.textField?.stringValue = node.emoji.map { "\($0)  \(node.label)" } ?? node.label
        cell.textField?.font = node.emoji == nil
            ? .systemFont(ofSize: 11.5)
            : .systemFont(ofSize: 11.5, weight: .medium)
        cell.textField?.textColor = node.url.path == current?.path ? .labelColor : .secondaryLabelColor
        cell.toolTip = node.url.path
        return cell
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
