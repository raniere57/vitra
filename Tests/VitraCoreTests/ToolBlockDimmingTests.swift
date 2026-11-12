import Testing
@testable import VitraCore

@Suite("Tool blocks drawn quieter in the maestro's terminal")
struct ToolBlockDimmingTests {
    private func levels(_ screen: String) -> [UInt8] {
        ToolBlockDimming.levels(rows: screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)).map(\.rawValue)
    }

    @Test func aCallAndItsOutputAreQuietAndTheWordsAreNot() {
        let screen = """
        ⏺ Vou olhar o arquivo primeiro.

        ⏺ Bash(cd /x && ls)
          ⎿  a.swift
             b.swift

             … +12 lines (ctrl+o to expand)

        ⏺ vitra - screen_capture (MCP)(app: "Vitra")
          ⎿  Error: not allowed

        ⏺ Pronto: o arquivo existe (e compila).
          Segunda linha da resposta.
        """
        #expect(levels(screen) == [0, 0, 1, 2, 2, 0, 2, 0, 1, 2, 0, 0, 0])
    }

    @Test func theCallBeingMadeNowStaysAsItIs() {
        let screen = """
        ⏺ Read(a.swift)
          ⎿  Read 10 lines

        ⏺ Bash(swift build)
          ⎿  Compiling…

        ✻ Working… (12s)
        ❯
        """
        #expect(levels(screen) == [1, 2, 0, 0, 0, 0, 0, 0])
    }

    @Test func aScreenThatOpensInsideABlockQuietsItsTail() {
        let screen = """
             linha 41
          ⎿  resto
             linha 43

        ⏺ Terminei.
        """
        #expect(levels(screen) == [2, 2, 2, 0, 0])
    }

    @Test func proseWithAParenthesisIsNotACall() {
        #expect(!ToolBlockDimming.isCall("⏺ O método useMemo(…) resolve"))
        #expect(!ToolBlockDimming.isCall("⏺ Pronto (ver abaixo)"))
        #expect(ToolBlockDimming.isCall("⏺ Update(Sources/A.swift)"))
        #expect(ToolBlockDimming.isCall("⏺ Read 3 files (ctrl+o to expand)     "))
        #expect(levels("  - item de lista\n    - subitem") == [0, 0])
    }
}
