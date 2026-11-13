import Foundation

/// A tool call said in one line, the way a person would say what was done:
/// "Rodar os testes", "ProjectView.swift +12 −3", "delegou: Migrar a lista
/// (implement)". The terminal prints the call's raw input; this is what makes
/// a folded run of thirty calls readable at a glance.
enum ToolSummary {
    struct Described: Equatable {
        var summary: String
        var icon: String
        var input: String
        var filePath: String?
        var workerID: String?
        var added: Int?
        var removed: Int?
    }

    static let genericIcon = "wrench.and.screwdriver"
    /// How long a one-liner may get before it is cut with an ellipsis.
    static let maxLength = 120

    static func describe(name: String, input: [String: Any]) -> Described {
        let string = { (key: String) in (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        var described = Described(summary: name, icon: genericIcon, input: render(input))
        switch name {
        case "Bash":
            described.icon = "terminal"
            described.summary = string("description").flatMap { $0.isEmpty ? nil : $0 } ?? firstWords(of: string("command") ?? "")
            described.input = string("command") ?? described.input
        case "Read":
            described.icon = "doc.text"
            let path = string("file_path") ?? ""
            described.filePath = path.isEmpty ? nil : path
            var line = fileName(path)
            if let offset = input["offset"] as? Int {
                let limit = input["limit"] as? Int
                line += limit.map { " · linhas \(offset)–\(offset + $0 - 1)" } ?? " · desde a linha \(offset)"
            }
            described.summary = line
        case "Edit", "MultiEdit":
            described.icon = "pencil"
            let path = string("file_path") ?? ""
            described.filePath = path.isEmpty ? nil : path
            let edits = (input["edits"] as? [[String: Any]]) ?? [input]
            var (added, removed) = (0, 0)
            for edit in edits {
                let counts = lineChanges(old: edit["old_string"] as? String ?? "", new: edit["new_string"] as? String ?? "")
                added += counts.added
                removed += counts.removed
            }
            (described.added, described.removed) = (added, removed)
            described.summary = fileName(path)
            described.input = path
        case "Write":
            described.icon = "square.and.pencil"
            let path = string("file_path") ?? ""
            described.filePath = path.isEmpty ? nil : path
            described.added = lines(in: input["content"] as? String ?? "")
            described.removed = 0
            described.summary = fileName(path)
            described.input = path
        case "Grep", "Glob":
            described.icon = "magnifyingglass"
            let pattern = string("pattern") ?? ""
            let place = string("path").map { " em " + fileName($0) } ?? ""
            described.summary = (name == "Grep" ? "buscou “\(pattern)”" : "listou \(pattern)") + place
        case "Agent", "Task":
            described.icon = "person.2"
            let kind = string("subagent_type").map { " (\($0))" } ?? ""
            described.summary = "agente: " + (string("description") ?? "sem descrição") + kind
            described.input = string("prompt") ?? described.input
        case "WebSearch":
            described.icon = "globe"
            described.summary = "pesquisou “\(string("query") ?? "")”"
        case "WebFetch":
            described.icon = "globe"
            let url = string("url") ?? ""
            described.summary = "leu " + (URL(string: url)?.host ?? url)
        case "TodoWrite", "mcp__ccd_turn__update_plan":
            described.icon = "checklist"
            described.summary = "atualizou o plano"
        case "ToolSearch":
            described.icon = "shippingbox"
            described.summary = "carregou ferramentas"
        default:
            describeMCP(name: name, input: input, string: string, into: &described)
        }
        described.summary = clip(described.summary.isEmpty ? name : described.summary)
        return described
    }

    /// `mcp__<server>__<tool>`: Vitra's own tools in words, anything else as
    /// "server · tool".
    private static func describeMCP(name: String, input: [String: Any], string: (String) -> String?, into described: inout Described) {
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return }
        let server = parts[1]
        let tool = parts[2...].joined(separator: "__")
        switch (server, tool) {
        case ("vitra", "agent_spawn"):
            described.icon = "arrow.triangle.branch"
            let label = string("label") ?? string("worker") ?? "operário"
            described.summary = "delegou: \(label)" + (string("kind").map { " (\($0))" } ?? "")
            described.input = string("prompt") ?? described.input
        case ("vitra", "agent_wait"):
            described.icon = "hourglass"
            let count = (input["ids"] as? [Any])?.count ?? 1
            described.summary = count == 1 ? "aguardou 1 operário" : "aguardou \(count) operários"
        case ("vitra", "agent_merge"):
            described.icon = "arrow.triangle.merge"
            let id = string("id") ?? ""
            described.workerID = id.isEmpty ? nil : id
            described.summary = ((input["discard"] as? Bool) == true ? "descartou " : "integrou ") + id
        case ("vitra", "agent_rate"):
            described.icon = "star"
            let id = string("id") ?? ""
            described.workerID = id.isEmpty ? nil : id
            let score = (input["score"] as? NSNumber)?.intValue ?? string("score").flatMap { Int($0) }
            described.summary = "nota \(score.map(String.init) ?? "?")/5 a \(id)"
        case ("vitra", "agent_cancel"):
            described.icon = "xmark.circle"
            described.workerID = string("id")
            described.summary = "cancelou " + (string("id") ?? "")
        case ("vitra", "preview_file"):
            described.icon = "eye"
            let path = string("path") ?? ""
            described.filePath = path.isEmpty ? nil : path
            described.summary = "mostrou " + fileName(path)
        case (_, let tool) where tool.hasPrefix("browser_"):
            described.icon = "safari"
            let detail = string("url") ?? string("selector") ?? string("text") ?? ""
            let action = tool.dropFirst("browser_".count).replacingOccurrences(of: "_", with: " ")
            described.summary = "navegador: " + action + (detail.isEmpty ? "" : " " + detail)
        default:
            described.icon = genericIcon
            described.summary = server.replacingOccurrences(of: "plugin_", with: "") + " · " + tool.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// A worker's id in what `agent_spawn` answered: "Started agent 09c1ff2b: …".
    static func workerID(inResult text: String) -> String? {
        guard let range = text.range(of: #"(?i)agent\s+([0-9a-f]{8})\b"#, options: .regularExpression) else { return nil }
        let match = text[range]
        return match.split(whereSeparator: \.isWhitespace).last.map(String.init)
    }

    // MARK: - Helpers

    static func fileName(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return (path as NSString).lastPathComponent
    }

    /// The first words of a command: its first line, cut where it gets long.
    static func firstWords(of command: String) -> String {
        let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        // `cd somewhere && real-command` reads as the real command.
        let parts = line.components(separatedBy: " && ")
        let meaningful = parts.count > 1 && parts[0].hasPrefix("cd ") ? parts.dropFirst().joined(separator: " && ") : line
        return clip(meaningful.trimmingCharacters(in: .whitespaces), to: 72)
    }

    /// Lines added and removed going from `old` to `new`.
    ///
    /// ponytail: lines are matched as a multiset, not in order — a moved line
    /// counts as unchanged. `CollectionDifference` would be exact, but its
    /// Myers diff takes memory quadratic in the edit's size, and a real
    /// transcript's 2,000-line rewrite took gigabytes. Exact counts would
    /// need a linear-space diff.
    static func lineChanges(old: String, new: String) -> (added: Int, removed: Int) {
        var pool: [Substring: Int] = [:]
        for line in old.split(separator: "\n", omittingEmptySubsequences: false) where !old.isEmpty { pool[line, default: 0] += 1 }
        var added = 0
        for line in new.split(separator: "\n", omittingEmptySubsequences: false) where !new.isEmpty {
            if let count = pool[line], count > 0 { pool[line] = count - 1 } else { added += 1 }
        }
        return (added, pool.values.reduce(0, +))
    }

    static func lines(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let count = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return text.hasSuffix("\n") ? count : count + 1
    }

    static func clip(_ text: String, to length: Int = maxLength) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > length ? String(flat.prefix(length - 1)) + "…" : flat
    }

    /// The input as readable lines, keys sorted: what an opened call shows.
    static func render(_ input: [String: Any]) -> String {
        input.keys.sorted().map { key in
            let value = input[key]
            let text: String
            if let string = value as? String {
                text = string
            } else if let value, JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                text = String(decoding: data, as: UTF8.self)
            } else {
                text = value.map { "\($0)" } ?? ""
            }
            return "\(key): \(text)"
        }.joined(separator: "\n")
    }
}
