import Foundation

/// ⌘F in Leitura: where a query falls in the text the rows draw.
///
/// The same folding as the terminal's search (`ConversationSearch.fold`):
/// case, accents and width forgiven. Ranges are UTF-16, as AppKit paints
/// them. Pure, so the count runs off the main thread over every loaded item
/// and the row views find the same matches when they paint.
enum LeituraSearch {
    /// What a row draws, segment by segment, in the order it draws them.
    static func strings(for item: TranscriptItem) -> [String] {
        switch item {
        case let .user(message): [message.text]
        case let .answer(answer): ReadingDocument.make(markdown: answer.markdown).searchableStrings
        case let .note(note): [note.line]
        default: []
        }
    }

    static func ranges(of query: String, in text: String) -> [NSRange] {
        let needle = query.flatMap(ConversationSearch.fold)
        guard !needle.isEmpty, !text.isEmpty else { return [] }
        // Each folded character, with the UTF-16 span of the character it came from.
        var folded: [(Character, Int, Int)] = []
        var offset = 0
        for character in text {
            let width = character.utf16.count
            for piece in ConversationSearch.fold(character) { folded.append((piece, offset, width)) }
            offset += width
        }
        var found: [NSRange] = []
        var index = 0
        while index + needle.count <= folded.count {
            var matches = true
            for step in needle.indices where folded[index + step].0 != needle[step] {
                matches = false
                break
            }
            if matches {
                let start = folded[index].1
                let last = folded[index + needle.count - 1]
                found.append(NSRange(location: start, length: last.1 + last.2 - start))
                index += needle.count
            } else {
                index += 1
            }
        }
        return found
    }

    /// How many matches each item has, in order; nil if cancelled midway.
    static func counts(of query: String, in items: [TranscriptItem]) -> [Int]? {
        var counts: [Int] = []
        counts.reserveCapacity(items.count)
        for item in items {
            if Task.isCancelled { return nil }
            counts.append(strings(for: item).reduce(0) { $0 + ranges(of: query, in: $1).count })
        }
        return counts
    }
}
