import AppKit
import VitraCore

/// The left sidebar: favourites always, the directory tree when expanded.
///
/// Collapsed it is the rail it has always been — one column of emoji, one
/// click per project. Expanded it keeps that column and puts a folder tree
/// beside it, so widening the sidebar adds navigation instead of replacing
/// what was already there.
@MainActor
final class FolderSidebar: NSView {
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

    /// A folder in the tree was chosen: `newTab` is true when Cmd was held.
    var onOpenDirectory: ((URL, Bool) -> Void)? {
        get { tree.onOpen }
        set { tree.onOpen = newValue }
    }

    private(set) var isExpanded = false

    private let rail = FolderRail()
    private let tree = DirectoryTreeView()
    private let divider = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        rail.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        tree.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rail)
        addSubview(divider)
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

            tree.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            tree.trailingAnchor.constraint(equalTo: trailingAnchor),
            tree.topAnchor.constraint(equalTo: topAnchor, constant: 8),
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

    func apply(_ config: Config) {
        let background = NSColor(hex: config.theme.background.hex) ?? .black
        layer?.backgroundColor = background.blended(withFraction: 0.04, of: .white)?.cgColor
        rail.apply(config)
        tree.apply(config)
    }
}
