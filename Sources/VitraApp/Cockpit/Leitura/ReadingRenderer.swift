import AppKit

/// Turns a `StyledText` into the attributed string the reading view draws.
///
/// Tables become real `NSTextTable`s inside the text — aligned columns,
/// wrapping cells, hairlines between rows — so they select and copy with the
/// prose around them, and never as box-drawing characters. That is TextKit 1
/// (TextKit 2 has no tables), which is why the reading text views are built
/// on an explicit `NSLayoutManager`.
@MainActor
enum ReadingRenderer {
    /// Turns the text of an inline code span into a link when it names a file
    /// that exists; nil when it does not.
    typealias FileResolver = (String) -> URL?

    static func attributed(_ styled: StyledText, resolveFile: FileResolver? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(string: styled.string, attributes: [
            .font: ReadingStyle.body, .foregroundColor: ReadingStyle.text,
        ])
        var tables: [Int: NSTextTable] = [:]
        let shares = columnShares(styled)
        for (index, span) in styled.paragraphs.enumerated() {
            let next = styled.paragraphs.indices.contains(index + 1) ? styled.paragraphs[index + 1] : nil
            let isLast = next == nil
            let endsBlock = next?.isFirstOfBlock ?? true
            apply(span, endsBlock: endsBlock, isLast: isLast, isFirst: index == 0, tables: &tables, shares: shares, to: result)
        }
        for inline in styled.inlines { apply(inline, to: result, resolveFile: resolveFile) }
        return result
    }

    // MARK: - Paragraphs

    private static func apply(
        _ span: StyledText.ParagraphSpan, endsBlock: Bool, isLast: Bool, isFirst: Bool,
        tables: inout [Int: NSTextTable], shares: [Int: [CGFloat]], to text: NSMutableAttributedString
    ) {
        // The paragraph's own newline belongs to it, so its style covers it.
        let range = NSRange(location: span.range.location, length: min(span.range.length + 1, text.length - span.range.location))
        let gap = isLast ? 0 : ReadingStyle.paragraphGap
        var attributes: [NSAttributedString.Key: Any] = [:]
        switch span.kind {
        case .body:
            attributes[.paragraphStyle] = ReadingStyle.paragraphStyle(after: gap)
        case let .heading(level):
            attributes[.font] = ReadingStyle.heading(level)
            attributes[.paragraphStyle] = ReadingStyle.paragraphStyle(before: isFirst ? 0 : 8, after: isLast ? 0 : 6)
        case let .listItem(depth):
            let indent = 22 + CGFloat(depth) * 20
            attributes[.paragraphStyle] = ReadingStyle.paragraphStyle(
                indent: indent, firstIndent: indent - 18, after: endsBlock ? gap : 5, tabs: [indent]
            )
        case .quote:
            let block = NSTextBlock()
            block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
            let style = ReadingStyle.paragraphStyle(after: gap)
            style.textBlocks = [block]
            attributes[.paragraphStyle] = style
            attributes[.foregroundColor] = CockpitStyle.code
            attributes[.quoteBar] = true
        case .rule:
            let block = NSTextBlock()
            block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            block.setBorderColor(ReadingStyle.tableRule, for: .maxY)
            block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
            let style = ReadingStyle.paragraphStyle(after: gap)
            style.lineHeightMultiple = 0.6
            style.textBlocks = [block]
            attributes[.paragraphStyle] = style
            attributes[.font] = CockpitStyle.ui(6)
        case let .tableCell(index, row, column, columns, isHeader, alignment):
            let table = tables[index] ?? makeTable(columns: columns)
            tables[index] = table
            let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
            cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
            cell.setWidth(column == 0 ? 2 : 12, type: .absoluteValueType, for: .padding, edge: .minX)
            cell.setWidth(column == columns - 1 ? 2 : 12, type: .absoluteValueType, for: .padding, edge: .maxX)
            cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            cell.setBorderColor(isHeader ? CockpitStyle.raisedLine : ReadingStyle.tableRule, for: .maxY)
            cell.verticalAlignment = .topAlignment
            if let share = shares[index].flatMap({ $0.indices.contains(column) ? $0[column] : nil }) {
                cell.setValue(share, type: .percentageValueType, for: .width)
            }
            let style = ReadingStyle.paragraphStyle(after: 0, alignment: alignment.textAlignment)
            style.lineHeightMultiple = 1.12
            style.textBlocks = [cell]
            // The gap after the table hangs on its last cell's paragraph.
            if endsBlock, row > 0 || columns == 1, column == columns - 1, !isLast { style.paragraphSpacing = gap + 4 }
            attributes[.paragraphStyle] = style
            attributes[.font] = isHeader ? ReadingStyle.smallMedium : ReadingStyle.small
            if isHeader { attributes[.foregroundColor] = ReadingStyle.quiet }
        }
        text.addAttributes(attributes, range: range)
    }

    /// Each table's columns as shares of its width, from how much text they
    /// hold: AppKit's automatic layout splits a table nearly evenly, which
    /// squeezes the one column of prose into a ribbon beside short numbers.
    /// A column's want is its longest cell, capped, with a floor so a number
    /// column never wraps.
    private static func columnShares(_ styled: StyledText) -> [Int: [CGFloat]] {
        var wants: [Int: [CGFloat]] = [:]
        let string = styled.string as NSString
        for span in styled.paragraphs {
            guard case let .tableCell(table, _, column, columns, _, alignment) = span.kind else { continue }
            var row = wants[table] ?? Array(repeating: 4, count: columns)
            let text = string.substring(with: span.range)
            let longestWord = CGFloat(text.split(whereSeparator: \.isWhitespace).map(\.count).max() ?? 0)
            // Figures ("4m 31s", "R$ 1,20") and short cells ("Nota") never
            // break across lines. The shares are of the table's whole width,
            // cell padding included, and a narrow column is mostly padding:
            // each want carries a few characters' worth of it, or a five-letter
            // header would not fit in the column sized for it.
            let isShort = text.count <= Self.unbrokenCell
            let floor = (alignment == .trailing || isShort ? CGFloat(text.count) : longestWord) + Self.paddingInCharacters
            row[column] = max(row[column], floor, min(CGFloat(text.count), 44))
            wants[table] = row
        }
        return wants.mapValues { row in
            let total = row.reduce(0, +)
            return row.map { $0 / total * 100 }
        }
    }

    /// A cell this short is kept on one line.
    private static let unbrokenCell = 16
    /// A cell's horizontal padding, in characters of the body face.
    private static let paddingInCharacters: CGFloat = 4

    private static func makeTable(columns: Int) -> NSTextTable {
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        return table
    }

    // MARK: - Inline

    private static func apply(_ span: StyledText.InlineSpan, to text: NSMutableAttributedString, resolveFile: FileResolver?) {
        let range = span.range
        guard range.location + range.length <= text.length else { return }
        if span.isMarker {
            text.addAttributes([.foregroundColor: ReadingStyle.quiet, .font: CockpitStyle.ui(ReadingStyle.bodySize).withMonospacedDigits], range: range)
            return
        }
        let base = (text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? ReadingStyle.body
        var font = base
        if span.traits.contains(.code) {
            font = CockpitStyle.mono(max(base.pointSize - 1.5, 10), span.traits.contains(.bold) ? .semibold : .regular)
            text.addAttributes([.backgroundColor: ReadingStyle.chip, .foregroundColor: CockpitStyle.code], range: range)
            let raw = (text.string as NSString).substring(with: range)
            if span.link == nil, let url = resolveFile?(raw) { text.addAttribute(.link, value: url, range: range) }
        } else {
            if span.traits.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if span.traits.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        }
        text.addAttribute(.font, value: font, range: range)
        if span.traits.contains(.strike) {
            text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: ReadingStyle.quiet], range: range)
        }
        if let link = span.link, let url = URL(string: link) {
            text.addAttributes([.link: url], range: range)
        }
    }
}

extension MarkdownTable.Alignment {
    var textAlignment: NSTextAlignment {
        switch self {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }
}

extension NSFont {
    /// The same face with figures of one width, so numbers line up.
    var withMonospacedDigits: NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]],
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

extension NSAttributedString.Key {
    /// A block quote's paragraphs: `ChipLayoutManager` draws the bar beside them.
    static let quoteBar = NSAttributedString.Key("vitra.quoteBar")
}
