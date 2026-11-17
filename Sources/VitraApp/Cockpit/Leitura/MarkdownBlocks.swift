import Foundation

/// The block structure of an answer's Markdown: what the maestro writes, and
/// nothing it does not — no HTML, no reference links, no setext headings.
///
/// Written here rather than taken from `AttributedString(markdown:)`, which
/// drops tables entirely and gives fenced code no block of its own: the two
/// things that make the terminal's rendering hardest to read. Line-based and
/// forgiving, because the text may be cut mid-stream: a fence never closed is
/// still a code block, a table whose delimiter row has not arrived yet is
/// still a paragraph.
enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `marker` is "•" for a bullet, "3." for a numbered item.
    case listItem(depth: Int, marker: String, text: String)
    case quote(String)
    case code(language: String?, text: String, isClosed: Bool)
    case table(MarkdownTable)
    case rule
}

struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case leading, center, trailing }

    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]

    var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    /// A column whose body cells are all numbers (or empty) reads right-aligned,
    /// whatever the delimiter row said.
    func isNumeric(_ column: Int) -> Bool {
        let cells = rows.compactMap { $0.indices.contains(column) ? $0[column] : nil }.filter { !$0.isEmpty }
        return !cells.isEmpty && cells.allSatisfy(Self.looksNumeric)
    }

    static func looksNumeric(_ cell: String) -> Bool {
        let stripped = cell.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
        return stripped.range(of: #"^[-+−~≈]?\s*(R\$|US\$|\$|€)?\s*[0-9][0-9.,:\s]*\s*(%|ms|s|m|h|k|kb|mb|gb|x|×|pt|px)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

enum MarkdownParser {
    static func blocks(_ text: String) -> [MarkdownBlock] {
        var parser = State(lines: text.components(separatedBy: "\n"))
        return parser.run()
    }

    private struct State {
        let lines: [String]
        var index = 0
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        init(lines: [String]) { self.lines = lines }

        mutating func run() -> [MarkdownBlock] {
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    flush()
                    index += 1
                } else if let fence = Self.fence(trimmed), Self.indent(of: line) < 4 {
                    flush()
                    readCode(fence: fence, language: String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces))
                } else if let heading = Self.heading(trimmed) {
                    flush()
                    blocks.append(heading)
                    index += 1
                } else if Self.isRule(trimmed) {
                    flush()
                    blocks.append(.rule)
                    index += 1
                } else if trimmed.contains("|"), index + 1 < lines.count, Self.isDelimiterRow(lines[index + 1]) {
                    flush()
                    readTable()
                } else if trimmed.hasPrefix(">") {
                    flush()
                    readQuote()
                } else if let item = Self.listItem(line) {
                    flush()
                    readList(first: item)
                } else {
                    paragraph.append(trimmed)
                    index += 1
                }
            }
            flush()
            return blocks
        }

        mutating func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        mutating func readCode(fence: String, language: String) {
            index += 1
            var body: [String] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(fence), trimmed.allSatisfy({ $0 == fence.first }) {
                    index += 1
                    blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n"), isClosed: true))
                    return
                }
                body.append(lines[index])
                index += 1
            }
            blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n"), isClosed: false))
        }

        mutating func readTable() {
            let header = Self.cells(lines[index])
            let alignments = Self.cells(lines[index + 1]).map { cell -> MarkdownTable.Alignment in
                let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
                return left && right ? .center : (right ? .trailing : .leading)
            }
            index += 2
            var rows: [[String]] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.contains("|") else { break }
                rows.append(Self.cells(trimmed))
                index += 1
            }
            blocks.append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
        }

        mutating func readQuote() {
            var body: [String] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(">") else { break }
                body.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
            }
            blocks.append(.quote(body.joined(separator: "\n")))
        }

        /// Items until a blank line followed by something that is not an
        /// item; lines in between continue the item above them.
        mutating func readList(first: (indent: Int, marker: String, text: String)) {
            var items = [first]
            var baseIndent = first.indent
            index += 1
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    // A blank between items keeps the list going.
                    if index + 1 < lines.count, Self.listItem(lines[index + 1]) != nil {
                        index += 1
                        continue
                    }
                    break
                }
                if let item = Self.listItem(line) {
                    items.append(item)
                    baseIndent = min(baseIndent, item.indent)
                } else if Self.fence(trimmed) != nil || Self.heading(trimmed) != nil || trimmed.hasPrefix(">") || Self.isRule(trimmed) {
                    break
                } else {
                    items[items.count - 1].text += "\n" + trimmed
                }
                index += 1
            }
            // Depth from indentation relative to the list's own left edge,
            // in steps of whatever the first nested item used (2 or 4 spaces).
            let step = items.map(\.indent).filter { $0 > baseIndent }.min().map { $0 - baseIndent } ?? 2
            for item in items {
                let depth = min((item.indent - baseIndent) / max(step, 1), 4)
                blocks.append(.listItem(depth: depth, marker: item.marker, text: item.text))
            }
        }

        // MARK: Line shapes

        static func indent(of line: String) -> Int {
            line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        }

        static func fence(_ trimmed: String) -> String? {
            for mark in ["```", "~~~"] where trimmed.hasPrefix(mark) {
                return String(trimmed.prefix { $0 == mark.first })
            }
            return nil
        }

        static func heading(_ trimmed: String) -> MarkdownBlock? {
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return nil }
            let text = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            return .heading(level: hashes, text: text.replacingOccurrences(of: #"\s#+$"#, with: "", options: .regularExpression))
        }

        static func isRule(_ trimmed: String) -> Bool {
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
            return compact.allSatisfy { $0 == first }
        }

        static func isDelimiterRow(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("-") else { return false }
            return trimmed.range(of: #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$"#, options: .regularExpression) != nil
        }

        static func cells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
            // An escaped pipe stays in its cell.
            let placeholder = "\u{0}"
            return trimmed.replacingOccurrences(of: "\\|", with: placeholder)
                .components(separatedBy: "|")
                .map { $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces) }
        }

        static func listItem(_ line: String) -> (indent: Int, marker: String, text: String)? {
            let indent = indent(of: line)
            let body = line.drop { $0 == " " || $0 == "\t" }
            if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
                let text = String(body.dropFirst(2))
                // "- [x] done": a task list's box, drawn as a mark.
                if text.hasPrefix("[ ] ") { return (indent, "☐", String(text.dropFirst(4))) }
                if text.lowercased().hasPrefix("[x] ") { return (indent, "☑", String(text.dropFirst(4))) }
                return (indent, "•", text)
            }
            let digits = body.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 3 else { return nil }
            let rest = body.dropFirst(digits.count)
            guard let punctuation = rest.first, ".)".contains(punctuation), rest.dropFirst().first == " " else { return nil }
            return (indent, digits + ".", String(rest.dropFirst(2)))
        }
    }
}
