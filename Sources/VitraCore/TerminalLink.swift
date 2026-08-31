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

    public static func match(in row: [Character], at column: Int) -> Match? {
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
        guard let url = url(from: token) else { return nil }
        return Match(url: url, columns: start ... end)
    }

    /// The URL a token stands for, or nil when it is only text.
    ///
    /// `www.` counts: it is written as a link far more often than it is
    /// written as prose, and every browser resolves it the same way.
    public static func url(from token: String) -> URL? {
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
        return nil
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
