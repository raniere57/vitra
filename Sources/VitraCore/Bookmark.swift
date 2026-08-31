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
    /// A command line to run when a tab opens on this favourite — `claude`,
    /// say. On a remote favourite it runs on the other machine, after the `cd`.
    public var command: String?
    /// An SSH destination — `user@host`, or an alias from `~/.ssh/config` — when
    /// the favourite is a machine rather than a directory on this one. `path` is
    /// then the directory over there, and nothing local is ever read from it.
    public var host: String?

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        emoji: String = "📁",
        icon: String? = nil,
        colorHex: String? = nil,
        theme: String? = nil,
        tags: [String] = [],
        host: String? = nil,
        command: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.emoji = emoji
        self.icon = icon
        self.colorHex = colorHex
        self.theme = theme
        self.tags = tags
        self.host = host
        self.command = command
    }

    /// What a tab opened on this favourite types, or nil when there is nothing
    /// to type: a local favourite already opens its shell in the right place.
    public var launchCommand: String? {
        if isRemote { return remoteCommand }
        guard let line = command?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            return nil
        }
        return line + "\n"
    }

    /// Whether this favourite lives on another machine.
    public var isRemote: Bool { !(host ?? "").isEmpty }

    /// The line a tab opened on this favourite runs, or nil for a local folder.
    ///
    /// `-t` because ssh only allocates a terminal for a bare login, and a login
    /// shell after the `cd` because ssh would otherwise disconnect the moment
    /// the `cd` returned. The single quotes keep `$SHELL` for the far side.
    public var remoteCommand: String? {
        guard let host, isRemote else { return nil }
        let directory = path.trimmingCharacters(in: .whitespaces)
        let line = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !directory.isEmpty || !line.isEmpty else { return "ssh \(host)\n" }

        // Double quotes inside, single quotes outside: the far side expands
        // `$SHELL`, this side expands nothing, and the line stays readable —
        // which matters, because the user watches it run.
        var script = directory.isEmpty ? "" : "cd \"\(Self.escapedForDoubleQuotes(directory))\""
        // `&&`, so a directory that is gone stops here instead of dropping the
        // user into a shell somewhere else on the machine.
        if !script.isEmpty { script += " && " }
        if line.isEmpty {
            script += "exec \"$SHELL\" -l"
        } else {
            // Login *and* interactive, because what puts a tool like `claude`
            // on the PATH — nvm, a `~/.local/bin` line — lives in the file the
            // far shell reads only when it is both, and `ssh host command` is
            // neither. The login shell after it means quitting the command
            // leaves the user on that machine instead of disconnecting.
            let inner = Self.escapedForDoubleQuotes("\(line); exec \"$SHELL\" -l")
            script += "exec \"$SHELL\" -lic \"\(inner)\""
        }
        return "ssh -t " + host + " " + ShellQuote.quote(script) + "\n"
    }

    /// A path as one word inside double quotes on the far side.
    private static func escapedForDoubleQuotes(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    /// The symbol drawn for this folder.
    ///
    /// Favourites made before icons existed carry an emoji and nothing else, so
    /// the twelve the picker offered map onto the twelve it offers now: nobody
    /// has to re-pick anything, and a folder that had a rocket keeps one.
    public var symbolName: String {
        if let icon, !icon.isEmpty { return icon }
        if isRemote { return "server.rack" }
        return Self.symbolsForEmoji[emoji] ?? "folder.fill"
    }

    /// The twelve the picker offers, in the order it offers them.
    public static let symbols = [
        "folder.fill", "server.rack", "paperplane.fill", "testtube.2", "ladybug.fill",
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
        // A remote favourite has no local directory; asking the network on
        // every redraw is not worth the answer.
        guard !isRemote else { return false }
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }

    /// A path shortened for display: the home directory as `~`.
    public var displayPath: String {
        if let host, isRemote { return path.isEmpty ? host : "\(host):\(path)" }
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
