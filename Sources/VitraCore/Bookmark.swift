import Foundation

/// A directory the user works in often, with what it takes to recognise it.
///
/// The emoji and the colour are not decoration: a list of twenty paths that all
/// start with `~/Dev/` is unreadable, and a glyph plus a colour is what the eye
/// finds before it has read anything.
public struct Bookmark: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// As the user typed it, tilde and all, so a home directory that moves still
    /// resolves.
    public var path: String
    public var emoji: String
    /// An SF Symbol name. The rail, the menu and the palette draw this; the
    /// emoji stays behind it for the window title, where a glyph is text.
    public var icon: String?
    /// `#rrggbb`, used to mark the window this folder opened in.
    public var colorHex: String?
    /// A theme name for terminals opened here, so production and staging never
    /// look alike.
    public var theme: String?
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        emoji: String = "📁",
        icon: String? = nil,
        colorHex: String? = nil,
        theme: String? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.emoji = emoji
        self.icon = icon
        self.colorHex = colorHex
        self.theme = theme
        self.tags = tags
    }

    /// The symbol drawn for this folder.
    ///
    /// Favourites made before icons existed carry an emoji and nothing else, so
    /// the twelve the picker offered map onto the twelve it offers now: nobody
    /// has to re-pick anything, and a folder that had a rocket keeps one.
    public var symbolName: String {
        if let icon, !icon.isEmpty { return icon }
        return Self.symbolsForEmoji[emoji] ?? "folder.fill"
    }

    /// The twelve the picker offers, in the order it offers them.
    public static let symbols = [
        "folder.fill", "paperplane.fill", "testtube.2", "ladybug.fill",
        "wrench.and.screwdriver.fill", "shippingbox.fill", "globe", "lock.fill",
        "gearshape.fill", "note.text", "paintpalette.fill", "archivebox.fill",
    ]

    private static let symbolsForEmoji: [String: String] = [
        "📁": "folder.fill", "🚀": "paperplane.fill", "🧪": "testtube.2",
        "🐛": "ladybug.fill", "🔧": "wrench.and.screwdriver.fill",
        "📦": "shippingbox.fill", "🌐": "globe", "🔒": "lock.fill",
        "⚙️": "gearshape.fill", "📝": "note.text", "🎨": "paintpalette.fill",
        "🗄️": "archivebox.fill", "🏠": "house.fill", "⬇️": "arrow.down.circle.fill",
    ]

    /// The directory, with `~` expanded and symlinks left alone.
    public var url: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    public var exists: Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }

    /// A path shortened for display: the home directory as `~`.
    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let full = url.path
        return full.hasPrefix(home) ? "~" + full.dropFirst(home.count) : full
    }

    /// Whether this bookmark answers `query`.
    ///
    /// Every field is searched, including the tags, because the tag is often the
    /// only thing the user remembers — "the rust one", "work".
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        // Space-separated terms all have to match, which is what makes
        // "work api" narrow instead of widen.
        return needle.split(separator: " ").allSatisfy { term in
            let part = String(term)
            return name.lowercased().contains(part)
                || displayPath.lowercased().contains(part)
                || emoji.contains(part)
                || tags.contains { $0.lowercased().contains(part) }
        }
    }
}

/// The bookmark list on disk.
///
/// JSON rather than the TOML the configuration uses: this file is written by the
/// app every time a folder is starred, and a format the app owns end to end
/// cannot lose a user's hand-written comments — because there are none.
public struct BookmarkStore: Sendable {
    public let path: URL

    public init(path: URL = Vitra.supportDirectory.appendingPathComponent("bookmarks.json")) {
        self.path = path
    }

    public func load() -> [Bookmark] {
        guard let data = try? Data(contentsOf: path) else { return [] }
        // A corrupt file is not worth an alert on launch; it is worth not
        // destroying, so nothing is written until the user changes something.
        return (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }

    public func save(_ bookmarks: [Bookmark]) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bookmarks).write(to: path, options: .atomic)
    }
}
