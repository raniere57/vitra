import Foundation
import Testing
@testable import VitraApp

@Test func theTailOfTheTerminalIsItsLastLinesWithoutTheBlankOnesBelow() {
    let screen = "one\ntwo\nthree\n\n   \n"
    #expect(SharedTerminalText.tail(screen, lines: 2) == "two\nthree")
    #expect(SharedTerminalText.tail(screen, lines: 50) == "one\ntwo\nthree")
    #expect(SharedTerminalText.tail("", lines: 5) == "")
}

@Test func whatACommandAddedIsThePromptItWasTypedOnAndEverythingAfter() {
    let before = "$ ls\na.txt\n$ \n\n"
    let after = "$ ls\na.txt\n$ git status\nnothing to commit\n$ \n"
    #expect(SharedTerminalText.added(before: before, after: after) == "$ git status\nnothing to commit\n$ ")
    // The screen was cleared meanwhile: there is nothing to compare with, so
    // the answer is what is on it now.
    #expect(SharedTerminalText.added(before: before, after: "$ clear\n$ ") == "$ clear\n$ ")
    #expect(SharedTerminalText.added(before: "", after: "$ pwd\n/x\n$ ") == "$ pwd\n/x\n$ ")
}

@Test func onlyOneLineIsEverTypedIntoTheTerminal() {
    #expect(SharedTerminalText.problem(with: "bun test") == nil)
    #expect(SharedTerminalText.problem(with: "  ") == "command is required")
    #expect(SharedTerminalText.problem(with: "echo a\nrm -rf x") != nil)
    #expect(SharedTerminalText.problem(with: String(repeating: "x", count: 3000)) != nil)
}
