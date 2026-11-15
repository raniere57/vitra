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

    @Test func theCallBeingMadeNowIsQuietTooEvenWhileItsBulletBlinksOff() {
        let screen = """
        ⏺ Read(a.swift)
          ⎿  Read 10 lines

        ⏺ Bash(swift build)
          ⎿  Compiling…

        ✻ Working… (12s)
        ❯
        """
        #expect(levels(screen) == [1, 2, 0, 1, 2, 0, 0, 0])
        let blinking = """
        ⏺ Bash(swift build)
          ⎿  ok

          Calling vitra 3 times… (ctrl+o to expand)
        """
        #expect(levels(blinking) == [1, 2, 0, 1])
    }

    @Test func aFoldedRunOfCallsWithoutBulletIsQuiet() {
        let screen = """
        ⏺ O main não andou. Vou publicar.

          Ran 1 shell command

          Read 2 files, searched for 1 pattern

          Called vitra 6 times

          Read 1 file, called vitra

          Fiz 3 ajustes no layout.
        """
        #expect(levels(screen) == [0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0])
        #expect(!ToolBlockDimming.isFolded("Fixed the logo and the sheet."))
        #expect(!ToolBlockDimming.isFolded("Testei no navegador simulando"))
    }

    @Test func aDiffFillingTheScreenStaysQuietPastItsHunkBreaks() {
        let screen = """
               11  /// once.
              ...
               18      private var began: Date?
               21 +    private var label: NSTextField?

        ⏺ Pronto.
        """
        #expect(levels(screen) == [2, 2, 2, 2, 0, 0])
        let call = "⏺ Update(A.swift)\n  ⎿  Added 2 lines\n       11  /// once.\n    ...\n       18  x"
        #expect(levels(call) == [1, 2, 2, 2, 2])
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

    @Test func aNoticeFromTheHarnessIsQuietUntilItsBlankRow() {
        let rows = ["⏺ Artifact comment monitor didn't resume: it", "  couldn't restart in this session.", "", "⏺ Pronto.", "  Segunda linha."]
        #expect(ToolBlockDimming.levels(rows: rows, notices: [0]).map(\.rawValue) == [2, 2, 0, 0, 0])
        #expect(ToolBlockDimming.isNoticeColor(red: 229, green: 192, blue: 60))
        #expect(!ToolBlockDimming.isNoticeColor(red: 80, green: 220, blue: 100))
        #expect(!ToolBlockDimming.isNoticeColor(red: 230, green: 230, blue: 230))
        #expect(!ToolBlockDimming.isNoticeColor(red: 230, green: 80, blue: 80))
    }

    @Test func theLineSayingHowLongATurnTookIsQuiet() {
        #expect(levels("✻ Worked for 3m 44s · done 3:51 PM\n\n✻ Working… (12s)\n❯ Worked for 3 days") == [2, 0, 0, 0])
    }
}
