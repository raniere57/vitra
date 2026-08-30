import AppKit

/// A deliberately small, language-agnostic highlighter.
///
/// It colours the three things that carry most of the shape of a file at a
/// glance — comments, strings and numbers — plus a shared keyword set. It does
/// not parse: a keyword inside a string keeps the string's colour only because
/// comments and strings are applied last and win.
///
/// ponytail: regex over the whole text, no incremental relex. Fine for a
/// preview capped at a couple of megabytes; a real editor would need a lexer.
enum SyntaxHighlighter {
    private static let keyword = NSColor(red: 0.78, green: 0.60, blue: 0.98, alpha: 1)
    private static let string = NSColor(red: 0.60, green: 0.84, blue: 0.55, alpha: 1)
    private static let number = NSColor(red: 0.94, green: 0.71, blue: 0.44, alpha: 1)
    private static let comment = NSColor(white: 0.45, alpha: 1)

    /// Words common to the languages this app is likely to show.
    private static let words = [
        "func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum",
        "protocol", "extension", "import", "public", "private", "internal", "static", "throws",
        "try", "async", "await", "for", "while", "switch", "case", "default", "break", "continue",
        "def", "lambda", "None", "True", "False", "self", "elif", "pass", "yield", "with", "as",
        "function", "const", "type", "interface", "export", "from", "new", "this", "null",
        "undefined", "true", "false", "package", "fn", "impl", "match", "mut", "pub", "use",
        "int", "float", "double", "bool", "string", "void", "nil", "in", "do", "end", "then",
    ]

    private static let patterns: [(NSRegularExpression, NSColor)] = {
        let escaped = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let sources: [(String, NSColor)] = [
            ("\\b(?:\(escaped))\\b", keyword),
            ("\\b\\d+(?:\\.\\d+)?\\b", number),
            // Strings before comments: a // inside a string should stay a string.
            ("\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'", string),
            ("//[^\\n]*|#[^\\n]*|/\\*(?s:.)*?\\*/", comment),
        ]
        return sources.compactMap { pattern, colour in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, colour) }
        }
    }()

    /// Colours `text` in place. Returns quickly for very large files.
    static func highlight(_ text: NSMutableAttributedString) {
        // Beyond this the regex passes cost more than the colour is worth, and
        // the file is not something anyone reads in a side panel anyway.
        guard text.length < 200_000 else { return }
        let whole = NSRange(location: 0, length: text.length)
        for (expression, colour) in patterns {
            expression.enumerateMatches(in: text.string, range: whole) { match, _, _ in
                guard let range = match?.range else { return }
                text.addAttribute(.foregroundColor, value: colour, range: range)
            }
        }
    }
}
