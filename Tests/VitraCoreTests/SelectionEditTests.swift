import Testing
@testable import VitraCore

@Suite("Editing over a selection")
struct SelectionEditTests {
    @Test("a word before the cursor is reached by going left")
    func before() {
        // "hello world" with the cursor past the end, "hello" selected.
        let edit = SelectionEdit.replacing(
            selectionRow: 4, start: 0, end: 4, cursorRow: 4, cursorColumn: 11
        )
        #expect(edit == SelectionEdit(move: -6, backspaces: 5))
    }

    @Test("a word after the cursor is reached by going right")
    func after() {
        let edit = SelectionEdit.replacing(
            selectionRow: 4, start: 6, end: 10, cursorRow: 4, cursorColumn: 0
        )
        #expect(edit == SelectionEdit(move: 11, backspaces: 5))
    }

    @Test("a selection ending at the cursor needs no move")
    func adjacent() {
        let edit = SelectionEdit.replacing(
            selectionRow: 2, start: 3, end: 5, cursorRow: 2, cursorColumn: 6
        )
        #expect(edit == SelectionEdit(move: 0, backspaces: 3))
    }

    @Test("a selection on another row is left alone")
    func otherRow() {
        #expect(
            SelectionEdit.replacing(
                selectionRow: 1, start: 0, end: 4, cursorRow: 9, cursorColumn: 2
            ) == nil
        )
    }
}
