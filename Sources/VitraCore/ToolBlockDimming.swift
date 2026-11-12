import Foundation

/// Which rows of a Claude Code screen are a tool call and its output, so the
/// terminal can draw them quieter and leave what the maestro *says* in front.
///
/// Claude Code prints a call as a bullet and the tool's name with its
/// arguments in parentheses, the result under it behind "⎿", and the rest of
/// the result five spaces in. Its own words are a bullet and prose. Read from
/// the rows' first characters alone: pure, cheap, and tolerant — a row it
/// does not recognise is left as it is.
public enum ToolBlockDimming {
    public enum Level: UInt8, Sendable {
        case none = 0
        /// The call itself: what was done, still worth a glance.
        case call = 1
        /// What came back: the part that floods the screen.
        case output = 2
    }

    /// How many leading characters of a row are enough to classify it.
    public static let prefixLength = 96

    private static let bullets: Set<Character> = ["⏺", "●"]

    /// One level per row. The call being made now — the last one, with
    /// nothing said after it — is left alone: it is what is being watched.
    public static func levels(rows: [String]) -> [Level] {
        var levels = Array(repeating: Level.none, count: rows.count)
        // The viewport may open in the middle of a block whose call scrolled
        // away: rows before the first one that starts at the margin are
        // output if they look like nothing else.
        var inBlock = opensInsideBlock(rows)
        var lastCall: Int?
        var saidAfterLastCall = false
        for (index, row) in rows.enumerated() {
            if isCall(row) {
                levels[index] = .call
                inBlock = true
                lastCall = index
                saidAfterLastCall = false
            } else if isBlank(row) {
                continue
            } else if inBlock, isOutput(row) {
                levels[index] = .output
            } else {
                inBlock = false
                if let first = row.first, bullets.contains(first) { saidAfterLastCall = true }
            }
        }
        if let lastCall, !saidAfterLastCall {
            for index in lastCall ..< rows.count { levels[index] = .none }
        }
        return levels
    }

    static func isBlank(_ row: String) -> Bool { row.allSatisfy { $0 == " " } }

    /// "⏺ Bash(…", "⏺ vitra - screen_capture (MCP)(…", "⏺ mcp__x__y(…", and
    /// the folded "⏺ Read 3 files (ctrl+o to expand)".
    static func isCall(_ row: String) -> Bool {
        guard let first = row.first, bullets.contains(first), row.dropFirst().first == " " else { return false }
        // A screen's row comes padded with spaces to the terminal's width.
        let rest = row.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if rest.hasSuffix("(ctrl+o to expand)") || rest.contains(" (MCP)(") { return true }
        guard let paren = rest.firstIndex(of: "("), let initial = rest.first else { return false }
        let name = rest[..<paren]
        if name.hasPrefix("mcp__") { return true }
        // A tool's name: one capitalised word. Prose with a parenthesis in
        // it has spaces before it gets there.
        return initial.isUppercase && !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Under a call: the "⎿" line, or anything five spaces in or more.
    static func isOutput(_ row: String) -> Bool {
        let indent = row.prefix { $0 == " " }.count
        return indent >= 5 || (indent >= 2 && row.dropFirst(indent).first == "⎿")
    }

    private static func opensInsideBlock(_ rows: [String]) -> Bool {
        for row in rows where !isBlank(row) {
            guard row.first == " " else { return false }
            guard isOutput(row) else { return false }
            if row.contains("⎿") { return true }
        }
        return false
    }
}
