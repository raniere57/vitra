import Foundation

/// A run of text inside a block, with the emphasis Markdown gave it.
struct InlineRun: Equatable, Sendable {
    struct Traits: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let bold = Traits(rawValue: 1)
        static let italic = Traits(rawValue: 2)
        static let code = Traits(rawValue: 4)
        static let strike = Traits(rawValue: 8)
    }

    var text: String
    var traits: Traits = []
    var link: String?
}

/// Emphasis, inline code, strikethrough and links inside one block.
///
/// A small scanner instead of a full CommonMark inline parser: delimiters
/// are matched only when a closing one exists, so an unclosed `**` or a lone
/// backtick at the end of a streaming answer shows as the character it is,
/// never as a runaway bold paragraph.
enum MarkdownInline {
    static func runs(_ text: String) -> [InlineRun] {
        var runs: [InlineRun] = []
        scan(Array(text), traits: [], into: &runs)
        return merged(runs)
    }

    /// The text without its markup: what a run list draws.
    static func plain(_ text: String) -> String {
        runs(text).map(\.text).joined()
    }

    private static func scan(_ chars: [Character], traits: InlineRun.Traits, into runs: inout [InlineRun]) {
        var buffer = ""
        var index = 0
        func flush() {
            if !buffer.isEmpty { runs.append(InlineRun(text: buffer, traits: traits)) }
            buffer = ""
        }
        while index < chars.count {
            let char = chars[index]
            // A backslash keeps the next punctuation literal.
            if char == "\\", index + 1 < chars.count, chars[index + 1].isPunctuation || chars[index + 1].isSymbol {
                buffer.append(chars[index + 1])
                index += 2
                continue
            }
            if char == "`" {
                let ticks = run(of: "`", in: chars, at: index)
                if let close = find(String(repeating: "`", count: ticks), in: chars, from: index + ticks) {
                    flush()
                    var code = String(chars[(index + ticks) ..< close])
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2 { code = String(code.dropFirst().dropLast()) }
                    runs.append(InlineRun(text: code, traits: traits.union(.code)))
                    index = close + ticks
                    continue
                }
            }
            if char == "[", let (label, url, next) = link(in: chars, at: index) {
                flush()
                var inner: [InlineRun] = []
                scan(Array(label), traits: traits, into: &inner)
                runs += inner.map { InlineRun(text: $0.text, traits: $0.traits, link: url) }
                index = next
                continue
            }
            if char == "*" || char == "_" || char == "~" {
                let count = min(run(of: char, in: chars, at: index), char == "~" ? 2 : 3)
                let marker = String(repeating: String(char), count: count)
                let opensWord = index + count < chars.count && !chars[index + count].isWhitespace
                // Underscores inside a word (snake_case) are not emphasis.
                let inWord = char == "_" && index > 0 && (chars[index - 1].isLetter || chars[index - 1].isNumber)
                if opensWord, !inWord, (char != "~" || count == 2),
                   let close = closing(marker, in: chars, from: index + count) {
                    flush()
                    var added: InlineRun.Traits = []
                    if char == "~" { added = .strike } else {
                        if count >= 2 { added.insert(.bold) }
                        if count != 2 { added.insert(.italic) }
                    }
                    scan(Array(chars[(index + count) ..< close]), traits: traits.union(added), into: &runs)
                    index = close + count
                    continue
                }
            }
            buffer.append(char)
            index += 1
        }
        flush()
    }

    private static func run(of char: Character, in chars: [Character], at index: Int) -> Int {
        var end = index
        while end < chars.count, chars[end] == char { end += 1 }
        return end - index
    }

    private static func find(_ needle: String, in chars: [Character], from start: Int) -> Int? {
        let target = Array(needle)
        var index = start
        while index + target.count <= chars.count {
            if Array(chars[index ..< index + target.count]) == target,
               index + target.count == chars.count || chars[index + target.count] != target[0] {
                return index
            }
            index += 1
        }
        return nil
    }

    /// The closing marker: not preceded by a space, not in the middle of a
    /// longer run of the same character.
    private static func closing(_ marker: String, in chars: [Character], from start: Int) -> Int? {
        let target = Array(marker)
        var index = start + 1
        while index + target.count <= chars.count {
            if chars[index] == "`", let skip = find("`", in: chars, from: index + 1) {
                index = skip + 1
                continue
            }
            if Array(chars[index ..< index + target.count]) == target, !chars[index - 1].isWhitespace {
                let after = index + target.count
                let isWordEnd = target[0] != "_" || after == chars.count || !(chars[after].isLetter || chars[after].isNumber)
                if isWordEnd { return index }
            }
            index += 1
        }
        return nil
    }

    /// `[label](url)`: the label, the url, and where scanning goes on.
    private static func link(in chars: [Character], at index: Int) -> (String, String, Int)? {
        guard let closeBracket = chars[index...].firstIndex(of: "]"),
              closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
              let closeParen = chars[(closeBracket + 2)...].firstIndex(of: ")")
        else { return nil }
        let label = String(chars[(index + 1) ..< closeBracket])
        let url = String(chars[(closeBracket + 2) ..< closeParen]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !url.isEmpty, !url.contains(" ") else { return nil }
        return (label, url, closeParen + 1)
    }

    /// Neighbouring runs of the same look as one.
    private static func merged(_ runs: [InlineRun]) -> [InlineRun] {
        var out: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if var last = out.last, last.traits == run.traits, last.link == run.link {
                last.text += run.text
                out[out.count - 1] = last
            } else {
                out.append(run)
            }
        }
        return out
    }
}
