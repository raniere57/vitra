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

    /// What the expanded half of the sidebar is showing.
    enum Mode { case folders, sessions }

    private(set) var isExpanded = false
    private(set) var mode: Mode = .folders

    /// A Claude Code session was chosen; it resumes in the focused pane.
    var onOpenSession: ((ClaudeSession) -> Void)? {
        get { sessions.onOpen }
        set { sessions.onOpen = newValue }
    }

    private let rail = FolderRail()
    private let tree = DirectoryTreeView()
    private let sessions = SessionListView()

    /// Marks the session the focused pane is running.
    func setCurrentSession(_ id: String?) { sessions.setCurrent(id) }

    /// The session list finished reading.
    var onSessionsLoaded: (() -> Void)? {
        get { sessions.onLoaded }
        set { sessions.onLoaded = newValue }
    }

    /// The id of the session with this title in this folder, if there is one.
    func session(named title: String, in directory: String?) -> String? {
        sessions.session(named: title, in: directory)
    }
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
        search.font = .systemFont(ofSize: 12)
        search.controlSize = .small
        search.focusRingType = .none
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.delegate = self
        // Collapsed, the whole sidebar is 52pt wide and the field is hidden -
        // but its constraints are not, and a field that refuses to be narrower
        // than its text squeezed the rail to 31pt and left every icon off
        // centre. Nothing here needs the field to keep its width.
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        search.translatesAutoresizingMaskIntoConstraints = false

        sessions.translatesAutoresizingMaskIntoConstraints = false
        sessions.isHidden = true

        addSubview(rail)
        addSubview(divider)
        addSubview(search)
        addSubview(tree)
        addSubview(sessions)

        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.widthAnchor.constraint(equalToConstant: FolderRail.width),

            divider.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            search.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            tree.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            tree.bottomAnchor.constraint(equalTo: bottomAnchor),

            sessions.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            sessions.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Collapsed, the sidebar is 52pt wide — the rail and nothing else. The
        // expanded half is hidden but still laid out, and a required rail plus a
        // required half do not fit in 52pt: the solver was dropping the rail's
        // width and leaving a 31pt rail with every icon off centre. The half
        // gives way instead; it is invisible while it does.
        for constraint in [
            search.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: SidebarStyle.inset),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarStyle.inset),
            tree.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            tree.trailingAnchor.constraint(equalTo: trailingAnchor),
            sessions.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            sessions.trailingAnchor.constraint(equalTo: trailingAnchor),
        ] {
            constraint.priority = .defaultHigh
            constraint.isActive = true
        }

        setExpanded(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Switches what the expanded half shows, loading it if it is new.
    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        clearSearch()
        applyMode()
    }

    private func applyMode() {
        let showsSessions = isExpanded && mode == .sessions
        tree.isHidden = !isExpanded || mode != .folders
        sessions.isHidden = !showsSessions
        search.placeholderString = mode == .folders ? "Filter folders" : "Filter sessions"
        if showsSessions { sessions.load() }
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded || tree.isHidden == (expanded && mode == .folders) else { return }
        isExpanded = expanded
        divider.isHidden = !expanded
        search.isHidden = !expanded
        applyMode()
        // Collapsing hides the field, so a filter left behind would go on
        // hiding rows from a list nobody can see to clear it.
        if !expanded { clearSearch() }
    }

    private func clearSearch() {
        guard !search.stringValue.isEmpty else { return }
        search.stringValue = ""
        tree.setFilter("")
        sessions.setFilter("")
    }

    @objc private func searchChanged() {
        filterChanged()
    }

    private func filterChanged() {
        switch mode {
        case .folders: tree.setFilter(search.stringValue)
        case .sessions: sessions.setFilter(search.stringValue)
        }
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
        guard isExpanded, mode == .folders else { return }
        tree.reveal(directory)
    }

    /// Live-updates as the field is typed in; the action alone fires late.
    func controlTextDidChange(_ notification: Notification) {
        filterChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            clearSearch()
            onDismissSearch?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if mode == .folders { tree.openFirstMatch() }
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
        sessions.apply(config)
    }
}
