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
    /// A remote favourite was chosen. It has no local directory to `cd` into,
    /// so it always opens a tab.
    var onOpenRemote: ((Bookmark) -> Void)?

    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var roots: [Node] = []
    /// What the search field holds, and what it matched.
    private var filter = ""
    private var matches: [Node] = []
    /// Where the terminal is, so the row can be lit even after the user has
    /// scrolled somewhere else in the tree.
    private var current: URL?
    private var hoverTracking: NSTrackingArea?

    /// One folder in the tree. A class because the outline view identifies
    /// items by pointer, and because children are filled in later.
    final class Node {
        let url: URL
        let label: String
        /// An SF Symbol, for the roots — favourites and home carry one.
        let symbol: String?
        /// Set on a remote favourite, which is a leaf: there is no local disk
        /// under it to list.
        let remote: Bookmark?
        private(set) var children: [Node]?

        init(url: URL, label: String? = nil, symbol: String? = nil, remote: Bookmark? = nil) {
            self.url = url
            self.label = label ?? url.lastPathComponent
            self.symbol = symbol
            self.remote = remote
        }

        /// The subdirectories, read the first time they are asked for.
        func loadedChildren() -> [Node] {
            if let children { return children }
            if remote != nil { children = []; return [] }
            let loaded = DirectoryListing.directories(of: url).map { Node(url: $0.url) }
            children = loaded
            return loaded
        }

        /// The children already in hand, without going to disk for them.
        var cachedChildren: [Node]? { children }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = SidebarStyle.folderRow
        outline.indentationPerLevel = 14
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular
        // Plain, because the plate under a row is drawn here: the inset style
        // adds its own margins and its own blue bar on top of them.
        outline.style = .plain
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
        var roots = bookmarks.filter { $0.exists || $0.isRemote }.map { bookmark in
            Node(
                url: bookmark.url,
                label: bookmark.name,
                symbol: bookmark.symbolName,
                remote: bookmark.isRemote ? bookmark : nil
            )
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if !roots.contains(where: { $0.url.path == home.path }) {
            roots.append(Node(url: home, label: "Home", symbol: "house.fill"))
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

    /// Filters the tree down to folders whose name contains `text`.
    ///
    /// The search covers one level under every root plus everything already
    /// opened, which is what makes it instant: a favourite with two hundred
    /// projects is one `readdir`, and nothing walks the disk in the background.
    func setFilter(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed != filter else { return }
        filter = trimmed
        matches = trimmed.isEmpty ? [] : findMatches(trimmed)
        outline.reloadData()
        if trimmed.isEmpty { reveal(current) }
    }

    /// `Return` in the filter field takes the first result, which is the one
    /// the list is sorted to put there.
    func openFirstMatch() {
        guard let first = matches.first else { return }
        onOpen?(first.url, false)
    }

    private func findMatches(_ text: String) -> [Node] {
        var results: [Node] = []
        var seen: Set<String> = []

        func consider(_ node: Node) {
            guard results.count < 200 else { return }
            let name = node.url.lastPathComponent
            guard name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                  seen.insert(node.url.path).inserted
            else { return }
            results.append(node)
        }

        func walkOpened(_ node: Node) {
            // Only what is already in memory: opening folders to search them is
            // how a sidebar ends up stat-ing a home directory on every keystroke.
            guard let children = node.cachedChildren else { return }
            for child in children {
                consider(child)
                walkOpened(child)
            }
        }

        for root in roots {
            for child in root.loadedChildren() {
                consider(child)
                walkOpened(child)
            }
        }

        // A folder whose name starts with what was typed is the one being
        // looked for; the rest follow in the order a file browser would list.
        return results.sorted { lhs, rhs in
            let lhsPrefix = lhs.url.lastPathComponent.lowercased().hasPrefix(text.lowercased())
            let rhsPrefix = rhs.url.lastPathComponent.lowercased().hasPrefix(text.lowercased())
            if lhsPrefix != rhsPrefix { return lhsPrefix }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
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
        if let remote = node.remote {
            onOpenRemote?(remote)
            return
        }
        onOpen?(node.url, NSEvent.modifierFlags.contains(.command))
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return isFiltering ? matches.count : roots.count }
        return isFiltering ? 0 : node.loadedChildren().count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return isFiltering ? matches[index] : roots[index] }
        return node.loadedChildren()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard !isFiltering, let node = item as? Node else { return false }
        return !node.loadedChildren().isEmpty
    }

    /// Results are a flat list: a tree of matches would hide the ones whose
    /// parent did not match, which is the opposite of what searching is for.
    private var isFiltering: Bool { !filter.isEmpty }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        SidebarHover.update(outline, at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        SidebarHover.update(outline, at: nil)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView {
        SidebarRowView()
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("row")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier)

        let label = node.label
        cell.textField?.stringValue = isFiltering ? "\(label)  —  \(Self.parentLabel(of: node.url))" : label
        let isCurrent = node.url.path == current?.path
        cell.textField?.font = .systemFont(
            ofSize: 12,
            weight: isCurrent ? .semibold : (node.symbol == nil ? .regular : .medium)
        )
        // Roots carry the favourite's own symbol; everything below is a folder.
        cell.imageView?.image = NSImage(
            systemSymbolName: node.symbol ?? "folder",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        cell.imageView?.contentTintColor = isCurrent ? SidebarStyle.accent : .secondaryLabelColor
        cell.textField?.textColor = isCurrent ? .labelColor : .secondaryLabelColor
        cell.toolTip = node.url.path
        return cell
    }

    /// Where a search result lives, shortened the way a shell prompt would.
    private static func parentLabel(of url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.imageView = icon

        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -SidebarStyle.inset),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
