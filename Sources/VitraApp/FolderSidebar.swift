import AppKit
import VitraCore

/// The left sidebar: favourites always, the directory tree when expanded.
///
/// Collapsed it is the rail it has always been — one column of emoji, one
/// click per project. Expanded it keeps that column and puts a folder tree
/// beside it, so widening the sidebar adds navigation instead of replacing
/// what was already there.
@MainActor
final class FolderSidebar: NSView, NSSearchFieldDelegate {
    static let collapsedWidth: CGFloat = FolderRail.width
    static let expandedWidth: CGFloat = 260
    /// Wider than this and the sidebar counts as expanded.
    static let expansionThreshold: CGFloat = FolderRail.width + 40

    var onOpenBookmark: ((Bookmark) -> Void)? {
        get { rail.onOpen }
        set { rail.onOpen = newValue }
    }

    var onMenu: ((NSButton) -> Void)? {
        get { rail.onMenu }
        set { rail.onMenu = newValue }
    }

    /// Escape in the filter field: the caller puts the keyboard back where it
    /// belongs, which is the terminal.
    var onDismissSearch: (() -> Void)?

    /// A folder in the tree was chosen: `newTab` is true when Cmd was held.
    var onOpenDirectory: ((URL, Bool) -> Void)? {
        get { tree.onOpen }
        set { tree.onOpen = newValue }
    }

    private(set) var isExpanded = false

    private let rail = FolderRail()
    private let tree = DirectoryTreeView()
    private let divider = NSBox()
    private let search = NSSearchField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        rail.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        tree.translatesAutoresizingMaskIntoConstraints = false

        search.placeholderString = "Filter folders"
        search.font = .systemFont(ofSize: 11.5)
        search.controlSize = .small
        search.focusRingType = .none
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rail)
        addSubview(divider)
        addSubview(search)
        addSubview(tree)

        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.widthAnchor.constraint(equalToConstant: FolderRail.width),

            divider.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            search.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            search.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            tree.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            tree.trailingAnchor.constraint(equalTo: trailingAnchor),
            tree.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            tree.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setExpanded(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded || tree.isHidden == expanded else { return }
        isExpanded = expanded
        tree.isHidden = !expanded
        divider.isHidden = !expanded
        search.isHidden = !expanded
        // Collapsing hides the field, so a filter left behind would go on
        // hiding folders from a tree nobody can see to clear it.
        if !expanded, !search.stringValue.isEmpty {
            search.stringValue = ""
            tree.setFilter("")
        }
    }

    @objc private func searchChanged() {
        tree.setFilter(search.stringValue)
    }

    /// Focuses the filter field, for the shortcut and for expanding by menu.
    func focusSearch() {
        guard isExpanded else { return }
        window?.makeFirstResponder(search)
    }

    func update(bookmarks: [Bookmark], current: Bookmark.ID?) {
        rail.update(bookmarks: bookmarks, current: current)
        tree.setRoots(bookmarks)
    }

    /// Shows which folder the focused terminal is in.
    func reveal(_ directory: URL?) {
        guard isExpanded else { return }
        tree.reveal(directory)
    }

    /// Live-updates as the field is typed in; the action alone fires late.
    func controlTextDidChange(_ notification: Notification) {
        tree.setFilter(search.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            search.stringValue = ""
            tree.setFilter("")
            onDismissSearch?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            tree.openFirstMatch()
            return true
        default:
            return false
        }
    }

    func apply(_ config: Config) {
        let background = NSColor(hex: config.theme.background.hex) ?? .black
        layer?.backgroundColor = background.blended(withFraction: 0.04, of: .white)?.cgColor
        rail.apply(config)
        tree.apply(config)
    }
}
