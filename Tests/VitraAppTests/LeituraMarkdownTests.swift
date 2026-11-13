import Foundation
import Testing
@testable import VitraApp

struct LeituraMarkdownTests {
    @Test func blocksOfATypicalAnswer() {
        let text = """
        ## Plano

        Primeiro **isto**, depois `aquilo`.

        - um
          - dois
        - três

        1. passo
        2. outro

        > citação

        ```swift
        let x = 1
        ```

        ---

        | Arquivo | Linhas |
        |---|---|
        | A.swift | 120 |
        | B.swift | 8 |
        """
        let blocks = MarkdownParser.blocks(text)
        #expect(blocks == [
            .heading(level: 2, text: "Plano"),
            .paragraph("Primeiro **isto**, depois `aquilo`."),
            .listItem(depth: 0, marker: "•", text: "um"),
            .listItem(depth: 1, marker: "•", text: "dois"),
            .listItem(depth: 0, marker: "•", text: "três"),
            .listItem(depth: 0, marker: "1.", text: "passo"),
            .listItem(depth: 0, marker: "2.", text: "outro"),
            .quote("citação"),
            .code(language: "swift", text: "let x = 1", isClosed: true),
            .rule,
            .table(MarkdownTable(header: ["Arquivo", "Linhas"], alignments: [.leading, .leading], rows: [["A.swift", "120"], ["B.swift", "8"]])),
        ])
    }

    @Test func streamingTailsRenderSensibly() {
        // A fence not closed yet is still code; a table without its delimiter
        // row yet is still a paragraph.
        #expect(MarkdownParser.blocks("```sh\nswift test") == [.code(language: "sh", text: "swift test", isClosed: false)])
        #expect(MarkdownParser.blocks("| a | b |") == [.paragraph("| a | b |")])
        #expect(MarkdownInline.runs("isto **ainda não") == [InlineRun(text: "isto **ainda não")])
    }

    @Test func inlineEmphasisCodeAndLinks() {
        let runs = MarkdownInline.runs("a **b** *c* `d_e` [f](https://x.dev) ~~g~~ snake_case_name")
        #expect(runs == [
            InlineRun(text: "a "),
            InlineRun(text: "b", traits: .bold),
            InlineRun(text: " "),
            InlineRun(text: "c", traits: .italic),
            InlineRun(text: " "),
            InlineRun(text: "d_e", traits: .code),
            InlineRun(text: " "),
            InlineRun(text: "f", link: "https://x.dev"),
            InlineRun(text: " "),
            InlineRun(text: "g", traits: .strike),
            InlineRun(text: " snake_case_name"),
        ])
    }

    @Test func numericColumnsAlignRight() {
        let table = MarkdownTable(header: ["Nome", "Tempo", "Custo"], alignments: [], rows: [["a", "4m 12s", "R$ 1,20"], ["b", "12s", "—"]])
        #expect(!table.isNumeric(0))
        #expect(MarkdownTable.looksNumeric("R$ 1,20") && MarkdownTable.looksNumeric("87%") && MarkdownTable.looksNumeric("1.172"))
        #expect(!MarkdownTable.looksNumeric("A.swift"))
    }

    @Test func documentSplitsCodeAndKeepsTheDrawnText() {
        let document = ReadingDocument.make(markdown: "Veja **isto**:\n\n```\ncódigo\n```\n\n- item com `x`")
        #expect(document.segments.count == 3)
        #expect(document.searchableStrings == ["Veja isto:", "código", "•\titem com x"])
        guard case let .text(first) = document.segments[0] else { return }
        #expect(first.inlines.first?.traits == .bold)
        #expect(first.inlines.first?.range == NSRange(location: 5, length: 4))
    }

    @Test func tablesBecomeCellsInOrder() {
        let document = ReadingDocument.make(markdown: "| A | B |\n|:-|-:|\n| 1 | x |")
        guard case let .text(styled) = document.segments.first else { Issue.record("no text"); return }
        let cells = styled.paragraphs.compactMap { span -> String? in
            guard case let .tableCell(_, row, column, _, _, _) = span.kind else { return nil }
            return "\(row),\(column)"
        }
        #expect(cells == ["0,0", "0,1", "1,0", "1,1"])
        #expect(styled.string == "A\nB\n1\nx")
    }
}

/// ⌘F over Leitura: the same forgiveness as the terminal's search, counted
/// over the text the rows draw.
struct LeituraSearchTests {
    @Test func findsAcrossAccentsAndCaseInUTF16() {
        let ranges = LeituraSearch.ranges(of: "relatorio", in: "O Relatório e o relatório 📊 relatorio")
        #expect(ranges.count == 3)
        #expect(ranges.first == NSRange(location: 2, length: 9))
        #expect(LeituraSearch.ranges(of: "", in: "x").isEmpty)
    }

    @Test func countsMatchWhatTheRowsDraw() {
        let items: [TranscriptItem] = [
            .user(UserMessage(id: "u", text: "Corrige o **teste**")),
            .answer(Answer(id: "a", markdown: "O **teste** passou.\n\n```\nteste()\n```")),
            .activity(Activity(id: "x", steps: [])),
        ]
        // The user's text is drawn as typed; the answer's markup is not drawn.
        #expect(LeituraSearch.counts(of: "teste", in: items) == [1, 2, 0])
        #expect(LeituraSearch.counts(of: "**", in: items) == [2, 0, 0])
    }
}
