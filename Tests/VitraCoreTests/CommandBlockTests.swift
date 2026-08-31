import Foundation
import Testing
@testable import VitraCore

/// Builds a snapshot whose rows carry `semantics`, with the cursor on the last row.
private func makeSnapshot(
    _ semantics: [RowSemantic],
    cursorRow: Int? = nil,
    inputRows: [Int] = []
) -> RenderSnapshot {
    let snapshot = RenderSnapshot()
    snapshot.beginFrame(
        columns: 4,
        rows: UInt16(semantics.count),
        foreground: .white,
        background: .black
    )
    for (row, semantic) in semantics.enumerated() {
        snapshot.setSemantic(semantic, row: row)
    }
    for row in inputRows {
        snapshot.setHasInput(row: row)
    }
    snapshot.cursor = CursorSnapshot(
        column: 0,
        row: UInt16(cursorRow ?? semantics.count - 1),
        style: .block,
        isBlinking: true,
        color: .white
    )
    return snapshot
}

@Test func eachPromptStartsABlock() {
    let snapshot = makeSnapshot([.prompt, .output, .output, .prompt, .output])

    #expect(snapshot.commandBlocks.map(\.rows) == [0 ..< 3, 3 ..< 5])
}

@Test func aContinuationDoesNotStartABlock() {
    let snapshot = makeSnapshot([.prompt, .promptContinuation, .output, .prompt, .output])

    #expect(snapshot.commandBlocks.map(\.rows) == [0 ..< 3, 3 ..< 5])
}

/// A prompt that starts with a blank line spans two rows; the command is on the
/// second, and that is where its exit code has to be drawn.
@Test func theCommandRowIsTheLastRowOfThePrompt() {
    let snapshot = makeSnapshot([.prompt, .prompt, .output, .prompt, .prompt])

    #expect(snapshot.commandBlocks.map(\.commandRow) == [1, 4])
    #expect(snapshot.commandBlocks.map(\.rows) == [0 ..< 3, 3 ..< 5])
}

/// A rail down forty blank rows reads as a command still running.
@Test func theLastBlockStopsAtTheCursor() {
    let snapshot = makeSnapshot(
        [.prompt, .output, .prompt, .output, .output, .output],
        cursorRow: 3
    )

    #expect(snapshot.commandBlocks.map(\.rows) == [0 ..< 2, 2 ..< 4])
}

@Test func outputWithoutAnyPromptIsNoBlockAtAll() {
    let snapshot = makeSnapshot([.output, .output, .output])

    #expect(snapshot.commandBlocks.isEmpty)
}

@Test func aFreshFrameForgetsTheOldSemantics() {
    let snapshot = makeSnapshot([.prompt, .output])
    snapshot.beginFrame(columns: 4, rows: 2, foreground: .white, background: .black)

    #expect(snapshot.commandBlocks.isEmpty)
}

@Test func aCommandThatPrintedNothingIsStillItsOwnBlock() {
    // Blank spacing row, `false`, blank spacing row, `echo ok`, its output.
    // Nothing separates the two commands but the rows they were typed on.
    let snapshot = makeSnapshot(
        [.prompt, .prompt, .prompt, .prompt, .output],
        inputRows: [1, 3]
    )

    #expect(snapshot.commandBlocks.map(\.rows) == [0 ..< 2, 2 ..< 5])
    #expect(snapshot.commandBlocks.map(\.commandRow) == [1, 3])
}

@Test func aCommandLongEnoughToWrapKeepsOneBlock() {
    // A typed line that wrapped: the extra rows continue the prompt, so the
    // block covers all of them and the status stays on the row it started on.
    let snapshot = makeSnapshot(
        [.prompt, .promptContinuation, .promptContinuation, .output],
        inputRows: [0, 1, 2]
    )

    #expect(snapshot.commandBlocks.map(\.rows) == [0 ..< 4])
    #expect(snapshot.commandBlocks.map(\.commandRow) == [0])
}
