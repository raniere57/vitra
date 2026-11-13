import Foundation

/// What a user entry's text says once the harness's additions are taken out.
///
/// Claude Code puts its own words into the user's turn: `<system-reminder>`
/// blocks, hook context, "[Image #3]" placeholders for pasted images, caveats
/// before local commands. None of it was typed by the user, and all of it is
/// noise in a reading view.
enum UserText {
    /// Wrappers whose whole content is the harness's, removed with it.
    private static let droppedBlocks = [
        "system-reminder", "local-command-caveat", "user-prompt-submit-hook", "hook-output",
        "command-message", "tools-used-before-summary",
    ]

    static func clean(_ raw: String) -> String {
        var text = raw
        for tag in droppedBlocks {
            text = text.replacingOccurrences(of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        // Self-closing markers such as `<artifact-content-authored-by-others/>`.
        text = text.replacingOccurrences(of: #"<[a-z][a-z-]*/>"#, with: "", options: .regularExpression)
        // A long paste is wrapped in `<pasted_content id="…">`: the wrapper
        // is the harness's, what is inside is the user's.
        text = text.replacingOccurrences(of: #"</?pasted_content[^>]*>\n?"#, with: "", options: .regularExpression)
        // The thumbnails show the images; their placeholders say nothing more.
        text = text.replacingOccurrences(of: #"\[Image #\d+\]\s?"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let attachment = try? NSRegularExpression(
        pattern: #"'(/[^'\n]+\.(?:png|jpe?g|gif|webp|heic|tiff?|bmp|pdf))'|(?<![\w/])(/(?:[^\s'"\\]|\\ )+\.(?:png|jpe?g|gif|webp|heic|tiff?|bmp|pdf))(?![\w.])"#,
        options: [.caseInsensitive]
    )

    /// The images and PDFs a message names by path — which is how a paste
    /// reaches the maestro — taken out of its words, to be shown as what
    /// they are. Only files that exist: a path merely talked about stays.
    static func attachments(in text: String, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> (text: String, paths: [String]) {
        guard text.contains("/"), let attachment else { return (text, []) }
        var paths: [String] = []
        var words = text
        let matches = attachment.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            let group = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let found = Range(group, in: text), let whole = Range(match.range, in: words) else { continue }
            let path = String(text[found]).replacingOccurrences(of: "\\ ", with: " ")
            guard exists(path) else { continue }
            paths.insert(path, at: 0)
            words.replaceSubrange(whole, with: "")
        }
        guard !paths.isEmpty else { return (text, []) }
        words = words.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return (words.trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }

    /// The text inside the first `<tag>…</tag>`, trimmed; nil when absent.
    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound ..< text.endIndex)
        else { return nil }
        return String(text[open.upperBound ..< close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Terminal colour codes, which local commands print and a page cannot.
    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
