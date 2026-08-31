import Foundation

/// A value in a configuration file.
public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case let .integer(value): return value
        case let .double(value): return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .double(value): return value
        case let .integer(value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case let .boolean(value) = self { return value }
        return nil
    }

    public var arrayValue: [TOMLValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var tableValue: [String: TOMLValue]? {
        if case let .table(value) = self { return value }
        return nil
    }
}

/// The subset of TOML Vitra's configuration file uses.
///
/// Tables, dotted table headers, strings, integers, floats, booleans and
/// arrays — no inline tables, no dates, no multi-line strings. A dependency for
/// this would drag in a C++ library to read a file whose shape this project
/// defines itself.
public enum TOML {
    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let line: Int
        public let reason: String
        public var description: String { "line \(line): \(reason)" }
    }

    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        var path: [String] = []

        let source = text.components(separatedBy: .newlines)
        var index = 0
        while index < source.count {
            defer { index += 1 }
            var line = strip(comment: source[index]).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // An array may run over several lines, which is how anyone writes a
            // sixteen-colour palette. Gather until the brackets balance.
            if line.contains("["), !line.hasPrefix("["), !isBalanced(line) {
                while index + 1 < source.count, !isBalanced(line) {
                    index += 1
                    line += " " + strip(comment: source[index]).trimmingCharacters(in: .whitespaces)
                }
            }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw ParseError(line: index + 1, reason: "unterminated table header")
                }
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    throw ParseError(line: index + 1, reason: "empty table name")
                }
                path = name.split(separator: ".").map {
                    unquote(String($0).trimmingCharacters(in: .whitespaces))
                }
                continue
            }

            guard let separator = line.firstIndex(of: "=") else {
                throw ParseError(line: index + 1, reason: "expected key = value")
            }
            let key = unquote(String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces))
            guard !key.isEmpty else { throw ParseError(line: index + 1, reason: "empty key") }

            let raw = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard let value = parseValue(raw) else {
                throw ParseError(line: index + 1, reason: "cannot read value: \(raw)")
            }
            insert(value, at: path + [key], into: &root)
        }

        return root
    }

    /// True when every `[` in the line outside a string has its `]`.
    private static func isBalanced(_ line: String) -> Bool {
        var depth = 0
        var quote: Character?
        for character in line {
            if let active = quote {
                if character == active { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "[": depth += 1
            case "]": depth -= 1
            default: break
            }
        }
        return depth == 0
    }

    // MARK: - Values

    private static func parseValue(_ raw: String) -> TOMLValue? {
        if raw.hasPrefix("\"") || raw.hasPrefix("'") { return .string(unquote(raw)) }
        if raw == "true" { return .boolean(true) }
        if raw == "false" { return .boolean(false) }
        if raw.hasPrefix("[") { return parseArray(raw) }

        // Underscores are legal digit separators in TOML numbers.
        let number = raw.replacingOccurrences(of: "_", with: "")
        if let integer = Int(number) { return .integer(integer) }
        if let double = Double(number) { return .double(double) }
        return nil
    }

    private static func parseArray(_ raw: String) -> TOMLValue? {
        guard raw.hasSuffix("]") else { return nil }
        let body = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return .array([]) }

        var values: [TOMLValue] = []
        for element in splitElements(body) {
            guard let value = parseValue(element.trimmingCharacters(in: .whitespaces)) else { return nil }
            values.append(value)
        }
        return .array(values)
    }

    /// Splits on commas that are not inside a string.
    private static func splitElements(_ body: String) -> [String] {
        var elements: [String] = []
        var current = ""
        var quote: Character?

        for character in body {
            if let active = quote {
                current.append(character)
                if character == active { quote = nil }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case ",":
                elements.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        // A trailing comma is legal, and leaves an empty last element.
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { elements.append(current) }
        return elements
    }

    // MARK: - Text

    /// Removes a trailing comment, leaving `#` inside strings alone.
    private static func strip(comment line: String) -> String {
        var result = ""
        var quote: Character?

        for character in line {
            if let active = quote {
                result.append(character)
                if character == active { quote = nil }
                continue
            }
            if character == "#" { break }
            if character == "\"" || character == "'" { quote = character }
            result.append(character)
        }
        return result
    }

    private static func unquote(_ text: String) -> String {
        if text.hasPrefix("'") && text.hasSuffix("'") && text.count >= 2 {
            // Literal strings have no escapes at all.
            return String(text.dropFirst().dropLast())
        }
        guard text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2 else { return text }

        var result = ""
        var escaped = false
        for character in text.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func insert(_ value: TOMLValue, at path: [String], into table: inout [String: TOMLValue]) {
        guard let head = path.first else { return }
        if path.count == 1 {
            table[head] = value
            return
        }
        var child = table[head]?.tableValue ?? [:]
        insert(value, at: Array(path.dropFirst()), into: &child)
        table[head] = .table(child)
    }
}
