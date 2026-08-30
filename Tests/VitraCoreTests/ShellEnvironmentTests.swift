import Foundation
import Testing
@testable import VitraCore

@Test func terminalSizeClampsZeroDimensions() {
    // Zero rows or columns makes downstream reflow arithmetic divide by zero.
    let size = TerminalSize(columns: 0, rows: 0)
    #expect(size.columns == 1)
    #expect(size.rows == 1)
}

@Test func terminalSizeKeepsPixelDimensions() {
    let size = TerminalSize(columns: 80, rows: 24, pixelWidth: 640, pixelHeight: 408)
    #expect(size.pixelWidth == 640)
    #expect(size.pixelHeight == 408)
}

@Test func childEnvironmentAdvertisesVitra() {
    let env = ShellEnvironment.childEnvironment(term: "xterm-256color")
    #expect(env["TERM"] == "xterm-256color")
    #expect(env["COLORTERM"] == "truecolor")
    #expect(env["TERM_PROGRAM"] == "vitra")
    #expect(env["TERM_PROGRAM_VERSION"] == Vitra.version)
}

@Test func childEnvironmentDropsInheritedTerminalState() {
    // COLUMNS/LINES from the parent would make the child size itself to the
    // wrong terminal, and they are not updated on SIGWINCH.
    setenv("COLUMNS", "999", 1)
    setenv("TERMINFO", "/somewhere/else", 1)
    defer { unsetenv("COLUMNS"); unsetenv("TERMINFO") }

    let env = ShellEnvironment.childEnvironment()
    #expect(env["COLUMNS"] == nil)
    #expect(env["TERMINFO"] == nil)
}

@Test func extraEnvironmentOverridesDefaults() {
    let env = ShellEnvironment.childEnvironment(extra: ["TERM": "dumb", "VITRA_TEST": "1"])
    #expect(env["TERM"] == "dumb")
    #expect(env["VITRA_TEST"] == "1")
}

@Test func loginShellIsExecutable() {
    #expect(FileManager.default.isExecutableFile(atPath: ShellEnvironment.loginShell()))
}

@Test func resolvedTermIsOneOfTheTwoSupportedEntries() {
    #expect([ShellEnvironment.preferredTerm, ShellEnvironment.fallbackTerm].contains(ShellEnvironment.term))
}
