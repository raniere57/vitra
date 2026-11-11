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
        // The thumbnails show the images; their placeholders say nothing more.
        text = text.replacingOccurrences(of: #"\[Image #\d+\]\s?"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
