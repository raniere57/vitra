import Foundation

/// Turning a selection on the line being typed into keystrokes the program's
/// own line editor understands.
///
/// A terminal selection is a rectangle over cells; the program on the other end
/// knows nothing about it, which is why selecting a word and typing over it
/// does nothing anywhere. What the program does understand is its own cursor:
/// move it to the end of the selected word with arrow keys, press backspace
/// once per cell, and the word is gone from *its* buffer — after which the next
/// keystroke lands where the word was.
///
/// Only a selection on the cursor's own row is ever answered this way. A word
/// selected out of the scrolled-back transcript is not text anyone is editing,
/// and arrows sent for it would eat the line the user is actually typing.
public struct SelectionEdit: Equatable, Sendable {
    /// Cells to move the cursor by, negative for left.
    public let move: Int
    /// Backspaces to press once it is there.
    public let backspaces: Int

    /// The keystrokes that delete `start...end` of `row`, or nil when the
    /// selection is not on the line being typed.
    ///
    /// Counted in cells, so a double-width character costs the two presses its
    /// two cells suggest rather than the one it takes — the terminal is told
    /// widths, never how many keys the program thinks they are.
    public static func replacing(
        selectionRow: Int,
        start: Int,
        end: Int,
        cursorRow: Int,
        cursorColumn: Int
    ) -> SelectionEdit? {
        guard selectionRow == cursorRow, start >= 0, end >= start else { return nil }
        return SelectionEdit(move: (end + 1) - cursorColumn, backspaces: end - start + 1)
    }
}
