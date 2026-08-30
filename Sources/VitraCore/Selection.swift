import Foundation

/// A cell position in screen coordinates, which include scrollback.
///
/// Screen coordinates rather than viewport coordinates on purpose: a selection
/// anchor has to survive the terminal scrolling underneath it while the user is
/// still dragging.
public struct GridPosition: Equatable, Sendable {
    public var column: UInt16
    public var row: UInt32

    public init(column: UInt16, row: UInt32) {
        self.column = column
        self.row = row
    }
}

/// What a drag selects: single cells, whole words, or whole lines.
public enum SelectionMode: Sendable {
    case cell
    case word
    case line

    /// The mode a click count maps to, following the platform convention of
    /// single/double/triple click.
    public init(clickCount: Int) {
        switch clickCount {
        case 2: self = .word
        case let count where count >= 3: self = .line
        default: self = .cell
        }
    }
}
