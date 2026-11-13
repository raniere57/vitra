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

    /// One level per row. The call being made now is quiet like the rest:
    /// its bullet blinks, and a block that brightened with it would flash.
    ///
    /// `notices` are the rows that open a notice from the harness, not the
    /// maestro's words: told by the caller from the bullet's colour, which
    /// the text alone does not carry. A notice runs until a blank row.
    public static func levels(rows: [String], notices: Set<Int> = []) -> [Level] {
        var levels = Array(repeating: Level.none, count: rows.count)
        // The viewport may open in the middle of a block whose call scrolled
        // away: rows before the first one that starts at the margin are
        // output if they look like nothing else.
        var inBlock = opensInsideBlock(rows)
        var inNotice = false
        for (index, row) in rows.enumerated() {
            if notices.contains(index) {
                levels[index] = .output
                inNotice = true
                inBlock = false
            } else if inNotice, !isBlank(row), row.first == " " {
                levels[index] = .output
            } else if isDone(row) {
                levels[index] = .output
                inNotice = false
                inBlock = false
            } else if isCall(row) {
                inNotice = false
                levels[index] = .call
                inBlock = true
            } else if isBlank(row) {
                inNotice = false
                continue
            } else if inBlock, isOutput(row) {
                levels[index] = .output
            } else {
                inBlock = false
                inNotice = false
            }
        }
        return levels
    }

    public static func isBullet(_ character: Character) -> Bool { bullets.contains(character) }

    /// A warning's yellow: red and green high, blue low. The maestro's own
    /// bullet is the text colour, a call's is green or red.
    public static func isNoticeColor(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        red > 150 && green > 120 && blue < 130 && Int(red) - Int(blue) > 70 && Int(red) + 40 >= Int(green)
    }

    /// "✻ Worked for 3m 44s · done 3:51 PM": how long a turn took, under a
    /// glyph and a verb that change. The live "✻ Working… (12s)" is not it.
    static func isDone(_ row: String) -> Bool {
        guard let first = row.first, !first.isLetter, !first.isNumber, first != " ", !bullets.contains(first),
              !"❯>".contains(first), row.dropFirst().first == " " else { return false }
        return row.dropFirst(2).range(of: #"^\p{Lu}\p{L}+ for \d"#, options: .regularExpression) != nil
    }

    static func isBlank(_ row: String) -> Bool { row.allSatisfy { $0 == " " } }

    /// "⏺ Bash(…", "⏺ vitra - screen_capture (MCP)(…", "⏺ mcp__x__y(…", and
    /// the folded "⏺ Read 3 files (ctrl+o to expand)".
    static func isCall(_ row: String) -> Bool {
        // A running call's bullet blinks: while it is off the row opens with
        // a space where the bullet was.
        guard let first = row.first, bullets.contains(first) || first == " ", row.dropFirst().first == " ",
              row.dropFirst(2).first != " " else { return false }
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
