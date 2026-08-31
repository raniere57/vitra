import Foundation

public struct TerminalColor: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = TerminalColor(red: 0, green: 0, blue: 0)
    public static let white = TerminalColor(red: 255, green: 255, blue: 255)
}

public struct CellFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold = CellFlags(rawValue: 1 << 0)
    public static let italic = CellFlags(rawValue: 1 << 1)
    public static let faint = CellFlags(rawValue: 1 << 2)
    public static let blink = CellFlags(rawValue: 1 << 3)
    public static let inverse = CellFlags(rawValue: 1 << 4)
    public static let invisible = CellFlags(rawValue: 1 << 5)
    public static let strikethrough = CellFlags(rawValue: 1 << 6)
    public static let overline = CellFlags(rawValue: 1 << 7)
    public static let underline = CellFlags(rawValue: 1 << 8)
    public static let selected = CellFlags(rawValue: 1 << 9)
}

public enum CursorStyle: Sendable {
    case block
    case blockHollow
    case bar
    case underline
}

public struct CursorSnapshot: Sendable {
    public var column: UInt16
    public var row: UInt16
    public var style: CursorStyle
    public var isBlinking: Bool
    public var color: TerminalColor

    public init(column: UInt16, row: UInt16, style: CursorStyle, isBlinking: Bool, color: TerminalColor) {
        self.column = column
        self.row = row
        self.style = style
        self.isBlinking = isBlinking
        self.color = color
    }
}

/// One cell of the grid, with its text stored out of line.
///
/// Text lives in the snapshot's shared UTF-8 buffer rather than in a `String`
/// per cell: a full 80x24 redraw would otherwise allocate two thousand strings
/// per frame, which is exactly the kind of churn the CPU budget forbids.
public struct RenderCell: Sendable {
    public var textOffset: UInt32
    public var textLength: UInt8
    public var flags: CellFlags
    public var foreground: TerminalColor
    public var background: TerminalColor

    public init(
        textOffset: UInt32 = 0,
        textLength: UInt8 = 0,
        flags: CellFlags = [],
        foreground: TerminalColor = .white,
        background: TerminalColor = .black
    ) {
        self.textOffset = textOffset
        self.textLength = textLength
        self.flags = flags
        self.foreground = foreground
        self.background = background
    }

    public var isBlank: Bool { textLength == 0 }
}

/// A reusable frame of grid state, filled in by the terminal engine and read by
/// the renderer.
///
/// Reused across frames on purpose: the storage grows to the size of the grid
/// once and is then refilled in place, so a steady-state redraw allocates nothing.
/// What a row is, as far as the shell told the terminal (OSC 133).
///
/// This is what makes a command block a block: without it a terminal has one
/// undifferentiated stream of text and no way to say where a command's output
/// starts or ends.
/// One command on screen: where it sits, and which row you typed it on.
public struct CommandBlock: Equatable, Sendable {
    /// Every row of the block: the prompt, the command, and its output.
    public var rows: Range<Int>
    /// The row the command itself is on, which is where its status belongs.
    public var commandRow: Int

    public init(rows: Range<Int>, commandRow: Int) {
        self.rows = rows
        self.commandRow = commandRow
    }
}

public enum RowSemantic: UInt8, Sendable {
    case output = 0
    case prompt = 1
    case promptContinuation = 2
}

public final class RenderSnapshot {
    public private(set) var columns: UInt16 = 0
    public private(set) var rows: UInt16 = 0

    /// Row-major grid, `columns * rows` entries.
    public private(set) var cells: [RenderCell] = []

    /// UTF-8 bytes for every cell's grapheme cluster, addressed by cell offsets.
    public private(set) var text: [UInt8] = []

    /// One entry per row: prompt, prompt continuation, or plain output.
    public private(set) var rowSemantics: [RowSemantic] = []
    /// Which rows carry cells the user typed, as marked by OSC 133 `B`.
    public private(set) var rowHasInput: [Bool] = []

    public var defaultForeground: TerminalColor = .white
    public var defaultBackground: TerminalColor = .black
    public var cursor: CursorSnapshot?

    public init() {}

    public subscript(column: Int, row: Int) -> RenderCell {
        cells[row * Int(columns) + column]
    }

    /// The grapheme cluster in `cell`, or nil when the cell is blank.
    public func text(of cell: RenderCell) -> String? {
        guard cell.textLength > 0 else { return nil }
        let start = Int(cell.textOffset)
        return String(decoding: text[start ..< start + Int(cell.textLength)], as: UTF8.self)
    }

    /// Runs `body` over the raw UTF-8 of `cell` without building a `String`.
    ///
    /// This is the hot path: the renderer keys its glyph cache off these bytes.
    public func withText<T>(of cell: RenderCell, _ body: (UnsafeRawBufferPointer) -> T) -> T? {
        guard cell.textLength > 0 else { return nil }
        let start = Int(cell.textOffset)
        return text.withUnsafeBytes { buffer in
            body(UnsafeRawBufferPointer(rebasing: buffer[start ..< start + Int(cell.textLength)]))
        }
    }

    // MARK: - Filling

    /// Resizes to `columns` x `rows` and clears the frame for refilling.
    ///
    /// Cells start as blanks in the terminal's own default colours, so a cell the
    /// engine never writes to blends into the background instead of showing up as
    /// a black hole in the grid.
    public func beginFrame(
        columns: UInt16,
        rows: UInt16,
        foreground: TerminalColor,
        background: TerminalColor
    ) {
        defaultForeground = foreground
        defaultBackground = background

        let blank = RenderCell(foreground: foreground, background: background)
        let count = Int(columns) * Int(rows)
        if self.columns != columns || self.rows != rows {
            self.columns = columns
            self.rows = rows
            cells = Array(repeating: blank, count: count)
            rowSemantics = Array(repeating: .output, count: Int(rows))
            rowHasInput = Array(repeating: false, count: Int(rows))
        } else {
            // Keep the allocation; only the contents are stale.
            for index in cells.indices { cells[index] = blank }
            for index in rowSemantics.indices { rowSemantics[index] = .output }
            for index in rowHasInput.indices { rowHasInput[index] = false }
        }
        text.removeAll(keepingCapacity: true)
        cursor = nil
    }

    /// Appends UTF-8 bytes to the shared text buffer and returns their location.
    public func appendText(_ bytes: UnsafeRawBufferPointer) -> (offset: UInt32, length: UInt8) {
        // A grapheme cluster longer than 255 bytes is pathological input, not
        // something to render; truncating keeps the cell layout honest.
        let length = min(bytes.count, Int(UInt8.max))
        let offset = UInt32(text.count)
        text.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[0 ..< length]))
        return (offset, UInt8(length))
    }

    public func setCell(_ cell: RenderCell, column: Int, row: Int) {
        cells[row * Int(columns) + column] = cell
    }

    public func setSemantic(_ semantic: RowSemantic, row: Int) {
        guard row >= 0, row < rowSemantics.count else { return }
        rowSemantics[row] = semantic
    }

    /// Marks the row as carrying typed input: it is the row of a command.
    public func setHasInput(row: Int) {
        guard row >= 0, row < rowHasInput.count else { return }
        rowHasInput[row] = true
    }

    /// The command blocks visible on screen.
    ///
    /// A block starts on a prompt row and runs to the row before the next one,
    /// so a command and everything it printed are one range. Continuation rows
    /// belong to the block they continue, never to a new one.
    public var commandBlocks: [CommandBlock] {
        var blocks: [CommandBlock] = []
        var start: Int?
        var promptEnd: Int?
        var commandRow: Int?

        func close(at row: Int) {
            guard let open = start, open < row else { return }
            blocks.append(CommandBlock(rows: open ..< row, commandRow: commandRow ?? promptEnd ?? open))
        }

        for (row, semantic) in rowSemantics.enumerated() {
            guard semantic != .output else { continue }
            let continuesPrompt = start != nil && row <= (promptEnd ?? -1) + 1
            // A prompt row that does not continue the one above starts a block.
            // So does a fresh prompt inside a run of prompt rows: a command that
            // printed nothing leaves its row touching the next prompt, and
            // merging the two would shift every status below it by one.
            if !continuesPrompt || (semantic == .prompt && commandRow != nil) {
                close(at: row)
                start = row
                commandRow = nil
            }
            promptEnd = row
            // The first typed row, not the last: a command long enough to wrap
            // owns every row it wraps onto, and its status belongs on the line
            // it starts on.
            if commandRow == nil, row < rowHasInput.count, rowHasInput[row] { commandRow = row }
        }
        // The last block ends where the text does, not at the bottom of the
        // pane: a rail running down forty blank rows says a command is still
        // printing when it is not.
        let end = cursor.map { min(Int($0.row) + 1, rowSemantics.count) } ?? rowSemantics.count
        close(at: end)
        return blocks
    }
}
