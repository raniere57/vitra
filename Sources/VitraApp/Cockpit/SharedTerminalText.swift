import Foundation

/// What an agent is told about the project's shared terminal, as text.
enum SharedTerminalText {
    static let defaultLines = 80
    static let mostLines = 1000
    private static let longestCommand = 2000

    /// The last `lines` lines of the terminal, trailing blank ones dropped.
    static func tail(_ text: String, lines: Int) -> String {
        let all = text.components(separatedBy: "\n")
        let kept = all.reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed()
        return kept.suffix(min(max(lines, 1), mostLines)).joined(separator: "\n")
    }

    /// What appeared on the terminal after `before`: the command as typed and
    /// what it printed. When the screen was cleared or scrolled out from under
    /// the comparison, the tail of what is there now.
    static func added(before: String, after: String) -> String {
        let old = tail(before, lines: mostLines)
        let new = tail(after, lines: mostLines)
        guard !old.isEmpty, new.hasPrefix(old) else { return tail(new, lines: defaultLines) }
        // The prompt the command was typed on is the last line of `old`; it
        // is kept, so the answer reads as it does on screen.
        let prompt = old.components(separatedBy: "\n").last ?? ""
        return prompt + String(new.dropFirst(old.count))
    }

    /// Why `command` cannot be typed into the terminal, or nil when it can.
    /// One line: a newline inside it would run as a second command.
    static func problem(with command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "command is required" }
        if trimmed.contains(where: \.isNewline) { return "one command per call: this one has a line break in it" }
        if trimmed.count > longestCommand { return "the command is too long to type" }
        return nil
    }
}
