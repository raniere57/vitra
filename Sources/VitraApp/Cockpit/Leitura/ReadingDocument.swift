import Foundation

/// An answer laid out for reading, before any font is chosen: the exact text
/// that will be drawn, and which ranges of it are a heading, a list item, a
/// table cell, bold, a link. Code blocks stand apart as segments of their
/// own, because they scroll sideways and the prose around them does not.
///
/// Pure and `Sendable`, so the find bar can search the very string the view
/// draws — off the main thread — and its match counts agree with the
/// highlights drawn.
struct ReadingDocument: Equatable, Sendable {
    enum Segment: Equatable, Sendable {
        case text(StyledText)
        case code(language: String?, text: String)
    }

    var segments: [Segment]

    /// Every segment's text, in order: what search reads.
    var searchableStrings: [String] {
        segments.map { segment in
            switch segment {
            case let .text(styled): styled.string
            case let .code(_, text): text
            }
        }
    }

    static func make(markdown: String) -> ReadingDocument {
        var segments: [Segment] = []
        var builder = StyledText.Builder()
        var tables = 0
        for block in MarkdownParser.blocks(markdown) {
            if case let .code(language, text, _) = block {
                if !builder.isEmpty { segments.append(.text(builder.finish())) }
                builder = StyledText.Builder()
                segments.append(.code(language: language, text: text))
                continue
            }
            builder.add(block, tableIndex: &tables)
        }
        if !builder.isEmpty { segments.append(.text(builder.finish())) }
        return ReadingDocument(segments: segments)
    }
}

/// A string and the meaning of its ranges, in UTF-16 offsets (NSRange), as
/// AppKit will apply them.
struct StyledText: Equatable, Sendable {
    enum Paragraph: Equatable, Sendable {
        case body
        case heading(Int)
        case listItem(depth: Int)
        case quote
        case rule
        case tableCell(table: Int, row: Int, column: Int, columns: Int, isHeader: Bool, alignment: MarkdownTable.Alignment)
    }

    struct ParagraphSpan: Equatable, Sendable {
        let range: NSRange
        let kind: Paragraph
        /// Space before this paragraph, in lines of nothing: the gap a blank
        /// line in the source asked for, or none inside a list or table.
        let isFirstOfBlock: Bool
    }

    struct InlineSpan: Equatable, Sendable {
        let range: NSRange
        let traits: InlineRun.Traits
        let link: String?
        /// A list's bullet or number, drawn quieter than the text.
        var isMarker = false
    }

    var string: String
    var paragraphs: [ParagraphSpan]
    var inlines: [InlineSpan]

    struct Builder {
        private var text = ""
        private var length = 0
        private var paragraphs: [ParagraphSpan] = []
        private var inlines: [InlineSpan] = []

        var isEmpty: Bool { paragraphs.isEmpty }

        mutating func add(_ block: MarkdownBlock, tableIndex: inout Int) {
            switch block {
            case let .heading(level, body):
                paragraph(.heading(level), first: true) { $0.inline(body) }
            case let .paragraph(body):
                paragraph(.body, first: true) { $0.inline(body) }
            case let .listItem(depth, marker, body):
                let isFirst = !(paragraphs.last.map { if case .listItem = $0.kind { true } else { false } } ?? false)
                paragraph(.listItem(depth: depth), first: isFirst) { builder in
                    builder.append(marker + "\t", traits: [], link: nil, isMarker: true)
                    builder.inline(body)
                }
            case let .quote(body):
                paragraph(.quote, first: true) { $0.inline(body) }
            case .rule:
                // A no-break space: the paragraph needs a glyph to carry its rule.
                paragraph(.rule, first: true) { $0.append("\u{00A0}", traits: [], link: nil) }
            case let .table(table):
                addTable(table, index: tableIndex)
                tableIndex += 1
            case .code:
                break
            }
        }

        private mutating func addTable(_ table: MarkdownTable, index: Int) {
            let columns = max(table.columns, 1)
            let allRows = [table.header] + table.rows
            for (rowIndex, row) in allRows.enumerated() {
                for column in 0 ..< columns {
                    let cell = row.indices.contains(column) ? row[column] : ""
                    let declared = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
                    let alignment: MarkdownTable.Alignment = rowIndex > 0 && table.isNumeric(column) ? .trailing
                        : (rowIndex == 0 && table.isNumeric(column) ? .trailing : declared)
                    let kind = Paragraph.tableCell(table: index, row: rowIndex, column: column, columns: columns, isHeader: rowIndex == 0, alignment: alignment)
                    paragraph(kind, first: rowIndex == 0 && column == 0) { $0.inline(cell.isEmpty ? "\u{00A0}" : cell) }
                }
            }
        }

        private mutating func paragraph(_ kind: Paragraph, first: Bool, body: (inout Builder) -> Void) {
            if length > 0 { append("\n", traits: [], link: nil) }
            let start = length
            body(&self)
            paragraphs.append(ParagraphSpan(range: NSRange(location: start, length: length - start), kind: kind, isFirstOfBlock: first))
        }

        private mutating func inline(_ markdown: String) {
            for run in MarkdownInline.runs(markdown) {
                // A line break inside a block is a line separator, not a new
                // paragraph: paragraph spacing must not open up inside it.
                let text = run.text.replacingOccurrences(of: "\n", with: "\u{2028}")
                if run.link == nil, !run.traits.contains(.code) {
                    appendLinkingURLs(text, traits: run.traits)
                } else {
                    append(text, traits: run.traits, link: run.link)
                }
            }
        }

        /// Bare `https://…` in prose becomes a link.
        private mutating func appendLinkingURLs(_ text: String, traits: InlineRun.Traits) {
            var rest = Substring(text)
            while let range = rest.range(of: #"https?://[^\s<>()]+[^\s<>().,;:!?'"]"#, options: .regularExpression) {
                append(String(rest[..<range.lowerBound]), traits: traits, link: nil)
                append(String(rest[range]), traits: traits, link: String(rest[range]))
                rest = rest[range.upperBound...]
            }
            append(String(rest), traits: traits, link: nil)
        }

        fileprivate mutating func append(_ piece: String, traits: InlineRun.Traits, link: String?, isMarker: Bool = false) {
            guard !piece.isEmpty else { return }
            let count = piece.utf16.count
            text += piece
            if !traits.isEmpty || link != nil || isMarker {
                inlines.append(InlineSpan(range: NSRange(location: length, length: count), traits: traits, link: link, isMarker: isMarker))
            }
            length += count
        }

        func finish() -> StyledText {
            StyledText(string: text, paragraphs: paragraphs, inlines: inlines)
        }
    }
}
