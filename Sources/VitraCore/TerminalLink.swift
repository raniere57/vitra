import Foundation

/// Finds the link under a column of a terminal row.
///
/// A row is handed in as one character per column, blanks included, so the
/// range that comes back is in columns and needs no mapping: what the user
/// clicked and what is on screen are the same coordinates.
public enum TerminalLink {
    /// What a URL can be surrounded by. Everything else belongs to the URL.
    private static let boundaries = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\"'`<>|"))

    /// Punctuation a sentence leaves behind: `see https://x.dev/a.` is a link
    /// and a full stop, not a link ending in one.
    private static let trailing = CharacterSet(charactersIn: ".,;:!?")

    private static let schemes = ["https://", "http://", "file://"]

    public struct Match: Equatable, Sendable {
        public let url: URL
        /// The columns the link occupies, both ends inclusive.
        public let columns: ClosedRange<Int>

        public init(url: URL, columns: ClosedRange<Int>) {
            self.url = url
            self.columns = columns
        }
    }

    /// `base` is the shell's working directory, which is what a relative path
    /// in its output is relative to. Without it only absolute and `~` paths
    /// count.
    public static func match(in row: [Character], at column: Int, base: URL? = nil) -> Match? {
        guard row.indices.contains(column) else { return nil }
        guard !isBoundary(row[column]) else { return nil }

        var start = column
        while start > row.startIndex, !isBoundary(row[start - 1]) { start -= 1 }
        var end = column
        while end < row.count - 1, !isBoundary(row[end + 1]) { end += 1 }

        // An opening bracket or quote in front of the link belongs to the prose.
        while start < end, "([{".contains(row[start]) { start += 1 }

        // Trailing punctuation, and a closing bracket the token never opened.
        while end > start {
            let last = row[end]
            let unbalanced = (last == ")" && !row[start ... end].contains("("))
                || (last == "]" && !row[start ... end].contains("["))
            guard isTrailing(last) || unbalanced else { break }
            end -= 1
        }

        let token = String(row[start ... end])
        guard let url = url(from: token, base: base) else { return nil }
        return Match(url: url, columns: start ... end)
    }

    /// The URL a token stands for, or nil when it is only text.
    ///
    /// `www.` counts: it is written as a link far more often than it is
    /// written as prose, and every browser resolves it the same way.
    public static func url(from token: String, base: URL? = nil) -> URL? {
        let lowered = token.lowercased()
        if schemes.contains(where: lowered.hasPrefix) {
            // A scheme and nothing after it is not a link.
            guard let scheme = schemes.first(where: lowered.hasPrefix),
                  token.count > scheme.count
            else { return nil }
            return URL(string: token)
        }
        if lowered.hasPrefix("www."), token.count > 4, token.contains(".", after: 4) {
            return URL(string: "https://" + token)
        }
        return fileURL(from: token, base: base)
    }

    /// A path written in output — `/Users/me/shot.png`, `~/notes.md`,
    /// `src/App.swift:12:3` — as a file URL, or nil when the token is prose.
    ///
    /// This decides only whether the text has the *shape* of a path. Whether a
    /// file is really there is the caller's question, and it asks the
    /// filesystem for the one token under the pointer rather than for every
    /// word on the screen.
    public static func fileURL(from token: String, base: URL?) -> URL? {
        // `file.swift:12:3` is how compilers and agents cite a place; the
        // place is the file.
        let path = stripLineReference(token)
        guard !path.isEmpty, !path.hasPrefix("-"), !path.contains("://") else { return nil }

        if path.hasPrefix("~/") || path == "~" {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        if path.hasPrefix("/") {
            return path.count > 1 ? URL(fileURLWithPath: path) : nil
        }
        // Relative: needs somewhere to be relative to, and has to look like a
        // path rather than a word — a slash in it, or a name with an
        // extension. `3.14` and `v2.0` are numbers, not files.
        guard let base else { return nil }
        let hasSlash = path.contains("/")
        let hasExtension: Bool = {
            guard let dot = path.lastIndex(of: "."), dot > path.startIndex else { return false }
            let ext = path[path.index(after: dot)...]
            let name = path[..<dot]
            return (1 ... 8).contains(ext.count)
                && ext.allSatisfy { $0.isLetter || $0.isNumber }
                && ext.contains { $0.isLetter }
                && !name.isEmpty
        }()
        guard hasSlash || hasExtension else { return nil }
        let directory = URL(fileURLWithPath: base.path, isDirectory: true)
        return URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
    }

    /// Drops a trailing `:line` or `:line:column`.
    static func stripLineReference(_ token: String) -> String {
        var text = Substring(token)
        for _ in 0 ..< 2 {
            guard let colon = text.lastIndex(of: ":"), colon > text.startIndex else { break }
            let digits = text[text.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { break }
            text = text[..<colon]
        }
        return String(text)
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { boundaries.contains($0) || $0.properties.generalCategory == .control }
    }

    private static func isTrailing(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { trailing.contains($0) }
    }
}

private extension String {
    /// Whether the string holds `needle` beyond the first `offset` characters.
    func contains(_ needle: Character, after offset: Int) -> Bool {
        dropFirst(offset).contains(needle)
    }
}
