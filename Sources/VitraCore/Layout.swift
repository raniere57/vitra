import Foundation

/// The shape of the windows, as they were when Vitra last closed.
///
/// Rebuilding four panes across two tabs by hand is minutes of work that the
/// app already knows how to do, so it is written down: which folders, which
/// splits, at what proportions, and which Claude Code session each pane was in.
///
/// What is *not* written down is the scrollback. A restored pane is a fresh
/// shell in the same folder — pretending otherwise would mean replaying output
/// no program produced.
public struct Layout: Codable, Equatable, Sendable {
    public var windows: [Window]

    public init(windows: [Window] = []) {
        self.windows = windows
    }

    /// One terminal, and what it was showing.
    public struct Pane: Codable, Equatable, Sendable {
        public var directory: String?
        /// The agent session this pane was running, to be resumed.
        public var session: String?
        /// Which agent that session belongs to, so it is resumed with the
        /// right line. Absent for an older layout or a plain shell — Claude
        /// Code is the fallback, which is what it always was.
        public var harness: String?

        public init(directory: String? = nil, session: String? = nil, harness: String? = nil) {
            self.directory = directory
            self.session = session
            self.harness = harness
        }
    }

    /// A pane, or a split of them. Splits nest, so this does too.
    public indirect enum Node: Codable, Equatable, Sendable {
        case pane(Pane)
        /// `vertical` is a divider running vertically: the children sit side by
        /// side. `fractions` is each child's share of the split, summing to 1.
        case split(vertical: Bool, fractions: [Double], children: [Node])

        /// Every pane in the tree, left to right and top to bottom.
        public var panes: [Pane] {
            switch self {
            case let .pane(pane): [pane]
            case let .split(_, _, children): children.flatMap(\.panes)
            }
        }
    }

    public struct Window: Codable, Equatable, Sendable {
        /// The folder the window was opened on, which is where new panes start.
        public var directory: String?
        public var frame: Frame
        public var sidebar: Sidebar
        /// Windows sharing a number were tabs of one window.
        public var tabGroup: Int
        public var root: Node

        public init(
            directory: String? = nil,
            frame: Frame,
            sidebar: Sidebar = Sidebar(),
            tabGroup: Int = 0,
            root: Node
        ) {
            self.directory = directory
            self.frame = frame
            self.sidebar = sidebar
            self.tabGroup = tabGroup
            self.root = root
        }
    }

    public struct Frame: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Sidebar: Codable, Equatable, Sendable {
        public var expanded: Bool
        /// "folders" or "sessions"; anything else falls back to folders.
        public var mode: String
        public var width: Double

        public init(expanded: Bool = false, mode: String = "folders", width: Double = 260) {
            self.expanded = expanded
            self.mode = mode
            self.width = width
        }
    }

    // MARK: - On disk

    public static var path: URL {
        // An override so a measured run can keep its own layout file instead of
        // trampling the one the user is living in.
        if let override = ProcessInfo.processInfo.environment["VITRA_LAYOUT_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return Vitra.supportDirectory.appendingPathComponent("layout.json")
    }

    /// Reads the saved layout, or nothing when there is none to read.
    ///
    /// A layout that cannot be decoded is not an error worth reporting: the app
    /// opens the way it does on a first run, which is what the user would have
    /// asked for anyway.
    public static func load(from url: URL = Layout.path) -> Layout? {
        guard let data = try? Data(contentsOf: url),
              let layout = try? JSONDecoder().decode(Layout.self, from: data),
              !layout.windows.isEmpty
        else { return nil }
        return layout
    }

    public func save(to url: URL = Layout.path) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Forgets the saved layout, so the next launch starts clean.
    public static func forget(at url: URL = Layout.path) {
        try? FileManager.default.removeItem(at: url)
    }
}
