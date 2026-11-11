import Foundation

/// The file or directory under a click in terminal text.
///
/// Shape only, plus one existence check the caller makes on click (or after
/// the pointer has rested). Soft-wrapped rows are joined first so a long path
/// that filled the last column still reads as one token.
enum TerminalPathLink {
    /// Punctuation and quotes that bound a path; spaces too.
    private static let boundaries = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\"'`<>|"))

    private static let trailing = CharacterSet(charactersIn: ".,;:)]}")

    struct Hit: Equatable, Sendable {
        var url: URL
        /// Dropped from a trailing `:line` or `:line:col`; unused for opening.
        var line: Int?
        var column: Int?
    }

    /// `rows` is one character per column, blanks included. `wrapped[i]` means
    /// row `i` continues onto `i+1`; if omitted, a row that fills its last
    /// column is treated as wrapped.
    static func match(
        rows: [[Character]],
        row: Int,
        column: Int,
        base: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Hit? {
        guard let (text, index) = joined(rows: rows, row: row, column: column) else { return nil }
        return match(in: text, at: index, base: base, fileExists: fileExists)
    }

    static func match(
        in row: [Character],
        at column: Int,
        base: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Hit? {
        guard row.indices.contains(column), !isBoundary(row[column]) else { return nil }

        var start = column
        while start > row.startIndex, !isBoundary(row[start - 1]) { start -= 1 }
        var end = column
        while end < row.count - 1, !isBoundary(row[end + 1]) { end += 1 }

        var token = String(row[start ... end])
        token = stripWrappers(token)
        token = trimTrailing(token)
        let (path, line, col) = stripLocation(token)
        guard looksLikePath(path) else { return nil }
        guard let url = resolve(path, base: base) else { return nil }
        guard fileExists(url) else { return nil }
        return Hit(url: url, line: line, column: col)
    }

    /// Concatenates the soft-wrapped run that holds `(row, column)`.
    static func joined(rows: [[Character]], row: Int, column: Int) -> ([Character], Int)? {
        guard rows.indices.contains(row) else { return nil }
        let width = rows[row].count
        guard width > 0, (0 ..< width).contains(column) else { return nil }

        var start = row
        while start > 0, isWrapped(rows[start - 1]) { start -= 1 }
        var end = row
        while end < rows.count - 1, isWrapped(rows[end]) { end += 1 }

        var text: [Character] = []
        text.reserveCapacity((end - start + 1) * width)
        for index in start ... end { text.append(contentsOf: rows[index]) }
        return (text, (row - start) * width + column)
    }

    static func isWrapped(_ row: [Character]) -> Bool {
        guard let last = row.last else { return false }
        return !last.isWhitespace
    }

    private static func looksLikePath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return path.count > 1 }
        if path.hasPrefix("~/") || path.hasPrefix("./") || path.hasPrefix("../") { return true }
        guard path.contains("/"), !path.hasPrefix("-") else { return false }
        guard let dot = path.lastIndex(of: "."), dot > path.startIndex else { return false }
        let ext = path[path.index(after: dot)...]
        return (1 ... 8).contains(ext.count)
            && ext.allSatisfy { $0.isLetter || $0.isNumber }
            && ext.contains { $0.isLetter }
    }

    private static func resolve(_ path: String, base: URL) -> URL? {
        if path.hasPrefix("~/") {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        let directory = URL(fileURLWithPath: base.path, isDirectory: true)
        return URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
    }

    private static func stripWrappers(_ token: String) -> String {
        var text = token
        while text.count >= 2, let first = text.first, let last = text.last {
            let pair: Bool
            switch (first, last) {
            case ("`", "`"), ("'", "'"), ("\"", "\""), ("(", ")"): pair = true
            default: pair = false
            }
            guard pair else { break }
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    private static func trimTrailing(_ token: String) -> String {
        var text = Substring(token)
        while let last = text.last, last.unicodeScalars.allSatisfy({ trailing.contains($0) }) {
            text = text.dropLast()
        }
        return String(text)
    }

    private static func stripLocation(_ token: String) -> (String, Int?, Int?) {
        var text = Substring(token)
        var line: Int?
        var column: Int?
        for which in 0 ..< 2 {
            guard let colon = text.lastIndex(of: ":"), colon > text.startIndex else { break }
            let digits = text[text.index(after: colon)...]
            guard !digits.isEmpty, let number = Int(digits) else { break }
            text = text[..<colon]
            if which == 0 { column = number } else { line = number }
        }
        if line == nil, let only = column {
            line = only
            column = nil
        }
        return (String(text), line, column)
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            boundaries.contains($0) || $0.properties.generalCategory == .control
        }
    }
}
