import Foundation

/// The menu Claude Code has up at the bottom of its screen — a permission
/// prompt, one of its questions, the review before answers are sent — read
/// from the screen's rows so it can be answered from somewhere else.
///
/// Its options are numbered, and pressing an option's digit picks it; in a
/// multiple-choice question the digit ticks it and Tab moves on. A numbered
/// list in the maestro's prose is not one: a menu has the "❯" on one of its
/// rows and sits at the very bottom of the screen.
public struct TerminalMenu: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let number: Int
        public let label: String
        public let detail: String?
        /// Ticked or not, in a multiple-choice question; nil elsewhere.
        public let isChecked: Bool?
        /// "Type something": picking it opens a field for the user's own words.
        public let isFreeText: Bool
    }

    /// The question, or "Do you want to proceed?".
    public let title: String?
    public let options: [Option]
    /// The hint row under a live menu ("Esc to cancel"): proof it is one.
    public let hasFooter: Bool

    public var isMultiple: Bool { options.contains { $0.isChecked != nil } }
    /// The option that takes the user's own words, where one digit and the
    /// words are the whole answer.
    public var freeText: Option? { isMultiple ? nil : options.first(where: \.isFreeText) }

    private static let cursor: Character = "❯"
    /// Rows a menu may have under its last option: a rule, the hint, a status line.
    private static let tail = 4

    public static func read(rows: [String]) -> TerminalMenu? {
        guard let last = rows.lastIndex(where: { option(in: $0) != nil }), let bottom = option(in: rows[last]) else { return nil }
        let after = rows[(last + 1)...].filter { !isFiller($0) }
        guard after.count <= tail else { return nil }

        var options: [Option] = []
        var details: [String] = []
        var hasCursor = false
        var expected = bottom.number
        var index = last
        while index >= 0 {
            let row = rows[index]
            if let found = option(in: row) {
                guard found.number == expected else { return nil }
                hasCursor = hasCursor || found.hasCursor
                options.append(make(found.number, found.label, details.reversed()))
                details = []
                if expected == 1 { break }
                expected -= 1
            } else if isSubmit(row) {
                hasCursor = hasCursor || row.contains(cursor)
            } else if isFiller(row) {
                // Between options: nothing.
            } else if row.prefix(while: { $0 == " " }).count >= 5 {
                details.append(row.trimmingCharacters(in: .whitespaces))
            } else {
                return nil
            }
            index -= 1
        }
        guard index >= 0, hasCursor else { return nil }
        let title = rows[..<index].last { !isFiller($0) }?.trimmingCharacters(in: .whitespaces)
        return TerminalMenu(
            title: title,
            options: options.reversed(),
            hasFooter: after.contains { $0.contains("Esc to cancel") }
        )
    }

    private static func make(_ number: Int, _ label: String, _ details: [String]) -> Option {
        var text = label
        var checked: Bool?
        let characters = Array(label)
        if characters.count > 3, characters[0] == "[", characters[2] == "]" {
            checked = characters[1] != " "
            text = String(characters[3...]).trimmingCharacters(in: .whitespaces)
        }
        return Option(
            number: number, label: text, detail: details.isEmpty ? nil : details.joined(separator: " "),
            isChecked: checked, isFreeText: text.lowercased().hasPrefix("type something")
        )
    }

    /// "❯ 1. Azul", "  2. Verde": at the margin, a digit, a dot, a label.
    private static func option(in row: String) -> (number: Int, label: String, hasCursor: Bool)? {
        var rest = Substring(row)
        let indent = rest.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        rest = rest.dropFirst(indent)
        var hasCursor = false
        if rest.first == cursor {
            hasCursor = true
            rest = rest.dropFirst().drop(while: { $0 == " " })
        }
        guard let digit = rest.first, let number = digit.wholeNumberValue, number >= 1,
              rest.dropFirst().hasPrefix(". ") else { return nil }
        let label = rest.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : (number, label, hasCursor)
    }

    private static func isSubmit(_ row: String) -> Bool {
        row.trimmingCharacters(in: CharacterSet(charactersIn: " ❯")) == "Submit"
    }

    /// Blank, or a rule drawn across the screen.
    private static func isFiller(_ row: String) -> Bool {
        row.allSatisfy { $0 == " " || $0 == "─" || $0 == "╌" }
    }
}
