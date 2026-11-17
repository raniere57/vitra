import Foundation

/// Finds a query in the maestro's conversation: the terminal's scrollback and
/// screen, as rows of text, giving each match as the cells it covers.
///
/// Pure and `Sendable` so it runs off the main thread: a long conversation is
/// tens of thousands of rows, and the search must not stall typing. It checks
/// for cancellation between lines, so a query superseded by the next keystroke
/// stops early.
///
/// What it forgives: case, accents and width — "relatorio" finds "relatório",
/// "ＡＢ" finds "ab" — the way Finder and Safari search. What it respects: a
/// soft-wrapped line is one line, so a word cut by the edge of the pane is
/// still found, and a wide character takes the two cells it is drawn on.
enum ConversationSearch {
    /// One row of the screen, and whether its line goes on in the next row.
    struct Row: Equatable, Sendable {
        var text: String
        var wraps: Bool
    }

    /// The cells a match covers on one row: screen row (scrollback included,
    /// counting from the top) and columns.
    struct Span: Equatable, Sendable {
        let row: Int
        let columns: Range<Int>
    }

    /// One match; more than one span when it crosses a soft wrap.
    struct Match: Equatable, Sendable {
        let spans: [Span]
        var row: Int { spans.first?.row ?? 0 }
    }

    /// The screen's text, one line per row, as rows.
    ///
    /// ponytail: a row is taken as soft-wrapped when its text fills the width
    /// of the pane — the emulator's own wrap flag costs a scrollback walk per
    /// row through its C API. A line that ends exactly at the edge is then
    /// joined to the next (a stray match across them at worst), and a wrapped
    /// row whose last cells were blanks is not (a match across that blank is
    /// missed). Read the row flag if either is ever seen.
    static func rows(fromScreenText text: String, columns: Int) -> [Row] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated().map { index, line in
            let fills = columns > 0 && line.reduce(0) { $0 + width(of: $1) } >= columns
            return Row(text: String(line), wraps: fills && index < lines.count - 1)
        }
    }

    /// Every match of `query`, top to bottom; nil when the task running it was
    /// cancelled first. Matches do not overlap.
    static func matches(of query: String, in rows: [Row]) -> [Match]? {
        let needle = query.flatMap(fold)
        guard !needle.isEmpty else { return [] }
        var found: [Match] = []
        var start = 0
        while start < rows.count {
            if Task.isCancelled { return nil }
            var end = start
            while end < rows.count - 1, rows[end].wraps { end += 1 }
            found += matches(of: needle, inLine: start...end, of: rows)
            start = end + 1
        }
        return found
    }

    /// Where each folded character of a line came from.
    private struct Cell {
        let character: Character
        let row: Int
        let column: Int
        let width: Int
    }

    private static func matches(of needle: [Character], inLine range: ClosedRange<Int>, of rows: [Row]) -> [Match] {
        var cells: [Cell] = []
        for row in range {
            var column = 0
            for character in rows[row].text {
                let cellWidth = width(of: character)
                for folded in fold(character) {
                    cells.append(Cell(character: folded, row: row, column: column, width: cellWidth))
                }
                column += cellWidth
            }
        }
        guard cells.count >= needle.count else { return [] }
        var found: [Match] = []
        var index = 0
        while index + needle.count <= cells.count {
            var isMatch = true
            for offset in needle.indices where cells[index + offset].character != needle[offset] {
                isMatch = false
                break
            }
            if isMatch {
                found.append(Match(spans: spans(cells[index ..< index + needle.count])))
                index += needle.count
            } else {
                index += 1
            }
        }
        return found
    }

    /// The cells of a match, one span per row they sit on.
    private static func spans(_ cells: ArraySlice<Cell>) -> [Span] {
        var spans: [Span] = []
        for cell in cells {
            let cellRange = cell.column ..< cell.column + cell.width
            if let last = spans.last, last.row == cell.row {
                let merged = min(last.columns.lowerBound, cellRange.lowerBound) ..< max(last.columns.upperBound, cellRange.upperBound)
                spans[spans.count - 1] = Span(row: cell.row, columns: merged)
            } else {
                spans.append(Span(row: cell.row, columns: cellRange))
            }
        }
        return spans
    }

    /// A character as search compares it: no case, no accents, no width. May
    /// be more than one ("ß" is "ss") or none.
    static func fold(_ character: Character) -> [Character] {
        // The common case, without a trip through Foundation.
        if character.isASCII { return [Character(character.lowercased())] }
        return Array(String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil))
    }

    /// How many cells the terminal draws a character on: two for East Asian
    /// wide and full-width characters and for emoji, one otherwise.
    static func width(of character: Character) -> Int {
        guard !character.isASCII, let scalar = character.unicodeScalars.first else { return 1 }
        if scalar.properties.isEmojiPresentation || character.unicodeScalars.contains("\u{FE0F}") { return 2 }
        return wideRanges.contains { $0.contains(scalar.value) } ? 2 : 1
    }

    /// The East Asian Wide and Fullwidth blocks that matter in practice.
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100 ... 0x115F, 0x2E80 ... 0x303E, 0x3041 ... 0x33FF, 0x3400 ... 0x4DBF,
        0x4E00 ... 0x9FFF, 0xA000 ... 0xA4CF, 0xAC00 ... 0xD7A3, 0xF900 ... 0xFAFF,
        0xFE30 ... 0xFE4F, 0xFF00 ... 0xFF60, 0xFFE0 ... 0xFFE6, 0x20000 ... 0x3FFFD,
    ]
}
