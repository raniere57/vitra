import Foundation

/// One line of a Claude Code transcript, turned into what it means for the
/// reading: zero or more events. Most lines mean nothing here — request
/// blobs, hook summaries, file snapshots, sidechain turns of subagents,
/// system reminders — and give no event at all.
///
/// Tolerant by design: a line that is not JSON, a type it does not know, a
/// block of a shape it has not seen, are all skipped. A transcript is
/// written by a program that changes every week; the reader must never be
/// what breaks.
enum TranscriptLine {
    enum Event: Equatable, Sendable {
        case userText(id: String, time: Date?, text: String)
        case userImage(id: String, time: Date?, ImageRef)
        /// "[Image: source: /path]": where the image just pasted was saved.
        case imageSource(String)
        case command(id: String, time: Date?, text: String)
        case commandOutput(String)
        case shell(id: String, time: Date?, command: String)
        case interrupted(id: String, time: Date?)
        case task(id: String, time: Date?, summary: String)
        case assistantText(id: String, time: Date?, text: String)
        case thinking(id: String, time: Date?)
        case toolUse(id: String, time: Date?, ToolCall)
        case toolResult(ToolResult)
        case compacted(id: String, time: Date?)
        case turnDuration(id: String, time: Date?, seconds: TimeInterval)
        /// A prompt typed while the maestro worked, waiting for its turn.
        case queued(id: String, time: Date?, text: String)
        /// A waiting prompt left the queue: the one with this text, or the
        /// oldest when nil. It comes back as a user entry when it was read.
        case unqueued(text: String?)
    }

    /// How much of a tool's output is kept: enough for "mostrar tudo" to be
    /// worth it, bounded so a 10 MB log dump does not sit in memory.
    static let maxOutput = 64 * 1024
    /// A pasted image's bytes are kept only below this; above it the
    /// thumbnail waits for the file path.
    static let maxInlineImage = 6 * 1024 * 1024

    /// The kinds of line that never carry anything to read, recognised from
    /// the first bytes so their (often huge) JSON is never parsed.
    private static let skippedPrefixes: [Data] = [
        "\"type\":\"api-request", "\"type\":\"file-history", "\"type\":\"attachment\"",
    ].map { Data($0.utf8) }
    private static let sidechain = Data("\"isSidechain\":true".utf8)
    private static let queuedCommand = Data("queued_command".utf8)

    static func events(from line: Data) -> [Event] {
        guard !line.isEmpty, !isSkippable(line),
              let object = try? JSONSerialization.jsonObject(with: line),
              let entry = object as? [String: Any]
        else { return [] }
        return events(from: entry)
    }

    /// Cheap checks on the raw bytes, before any JSON is parsed.
    static func isSkippable(_ line: Data) -> Bool {
        let head = line.prefix(400)
        if head.range(of: sidechain) != nil { return true }
        // A queued prompt is an attachment, and the one attachment kept.
        if head.range(of: skippedPrefixes[2]) != nil { return line.range(of: queuedCommand) == nil }
        return skippedPrefixes.dropLast().contains { head.range(of: $0) != nil }
    }

    static func events(from entry: [String: Any]) -> [Event] {
        if entry["isSidechain"] as? Bool == true { return [] }
        let id = entry["uuid"] as? String ?? UUID().uuidString
        let time = (entry["timestamp"] as? String).flatMap(date)
        switch entry["type"] as? String {
        case "user":
            return userEvents(entry, id: id, time: time)
        case "assistant":
            return assistantEvents(entry, id: id, time: time)
        case "system":
            return systemEvents(entry, id: id, time: time)
        case "attachment":
            return queuedEvents(entry, id: id, time: time)
        case "queue-operation":
            return queueOperation(entry, time: time)
        default:
            return []
        }
    }

    // MARK: - Entries

    private static func userEvents(_ entry: [String: Any], id: String, time: Date?) -> [Event] {
        if entry["isCompactSummary"] as? Bool == true || entry["isVisibleInTranscriptOnly"] as? Bool == true { return [] }
        let isMeta = entry["isMeta"] as? Bool == true
        let content = (entry["message"] as? [String: Any])?["content"]
        if let text = content as? String {
            return isMeta ? imageSources(in: text) : textEvents(text, id: id, time: time)
        }
        guard let blocks = content as? [[String: Any]] else { return [] }
        var events: [Event] = []
        let hasResults = blocks.contains { $0["type"] as? String == "tool_result" }
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result":
                if let result = toolResult(block, time: time) { events.append(.toolResult(result)) }
            case "text":
                let text = block["text"] as? String ?? ""
                if isMeta {
                    events += imageSources(in: text)
                } else if !hasResults {
                    // Text beside tool results is the harness talking, not the user.
                    events += textEvents(text, id: id, time: time)
                }
            case "image" where !isMeta && !hasResults:
                if let image = image(block) { events.append(.userImage(id: id, time: time, image)) }
            default:
                continue
            }
        }
        // The text after the images, as the user wrote it beside them.
        let images = events.filter { if case .userImage = $0 { true } else { false } }
        return images + events.filter { if case .userImage = $0 { false } else { true } }
    }

    private static func assistantEvents(_ entry: [String: Any], id: String, time: Date?) -> [Event] {
        guard let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        return blocks.enumerated().compactMap { index, block in
            // One entry may carry several blocks; each event needs its own id.
            let blockID = index == 0 ? id : "\(id)#\(index)"
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : .assistantText(id: blockID, time: time, text: text)
            case "thinking", "redacted_thinking":
                return .thinking(id: blockID, time: time)
            case "tool_use":
                guard let callID = block["id"] as? String, let name = block["name"] as? String else { return nil }
                let described = ToolSummary.describe(name: name, input: block["input"] as? [String: Any] ?? [:])
                let call = ToolCall(
                    id: callID, name: name, summary: described.summary, icon: described.icon, input: described.input,
                    filePath: described.filePath, workerID: described.workerID, added: described.added,
                    removed: described.removed, started: time
                )
                return .toolUse(id: blockID, time: time, call)
            default:
                return nil
            }
        }
    }

    private static func systemEvents(_ entry: [String: Any], id: String, time: Date?) -> [Event] {
        switch entry["subtype"] as? String {
        case "compact_boundary":
            return [.compacted(id: id, time: time)]
        case "turn_duration":
            guard let ms = (entry["durationMs"] as? NSNumber)?.doubleValue else { return [] }
            return [.turnDuration(id: id, time: time, seconds: ms / 1000)]
        case "local_command":
            return textEvents(entry["content"] as? String ?? "", id: id, time: time)
        default:
            return []
        }
    }

    /// A prompt typed while the maestro worked: Claude Code logs it as an
    /// attachment of the running turn, never as a user entry of its own.
    private static func queuedEvents(_ entry: [String: Any], id: String, time: Date?) -> [Event] {
        guard let attachment = entry["attachment"] as? [String: Any],
              attachment["type"] as? String == "queued_command",
              (attachment["commandMode"] as? String ?? "prompt") == "prompt"
        else { return [] }
        if let text = attachment["prompt"] as? String { return textEvents(text, id: id, time: time) }
        let blocks = attachment["prompt"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        let images = blocks.compactMap { $0["type"] as? String == "image" ? image($0) : nil }
        return images.map { .userImage(id: id, time: time, $0) } + textEvents(text, id: id, time: time)
    }

    /// Claude Code's own queue: "enqueue" when a prompt is typed mid-turn,
    /// "dequeue" or "remove" when it is taken. Background tasks use the same
    /// queue for their notices, which are not the user's words.
    private static func queueOperation(_ entry: [String: Any], time: Date?) -> [Event] {
        let content = entry["content"] as? String
        if content?.hasPrefix("<task-notification>") == true { return [] }
        let text = content.map(UserText.clean)
        switch entry["operation"] as? String {
        case "enqueue":
            guard let text, !text.isEmpty else { return [] }
            let stamp = entry["timestamp"] as? String ?? ""
            return [.queued(id: "queued-\(stamp)-\(text.utf8.count)", time: time, text: text)]
        case "dequeue", "remove", "popAll":
            return [.unqueued(text: text)]
        default:
            return []
        }
    }

    // MARK: - What a user's text means

    /// A user's text: their words, a slash command, a `!` command, an
    /// interruption, a task notice — or nothing, once the harness's own
    /// wrappers are taken out.
    static func textEvents(_ raw: String, id: String, time: Date?) -> [Event] {
        let text = UserText.clean(raw)
        if let command = UserText.tag("command-name", in: raw) {
            let args = UserText.tag("command-args", in: raw) ?? ""
            return [.command(id: id, time: time, text: args.isEmpty ? command : command + " " + args)]
        }
        if let output = UserText.tag("local-command-stdout", in: raw) ?? UserText.tag("local-command-stderr", in: raw) {
            return [.commandOutput(ToolCall.firstLine(of: UserText.stripANSI(output)))]
        }
        if let command = UserText.tag("bash-input", in: raw) {
            return [.shell(id: id, time: time, command: command)]
        }
        if raw.hasPrefix("<bash-stdout>") || raw.hasPrefix("<bash-stderr>") { return [] }
        if raw.hasPrefix("<task-notification>") {
            let summary = UserText.tag("summary", in: raw) ?? "tarefa em segundo plano terminou"
            return [.task(id: id, time: time, summary: summary)]
        }
        if text.hasPrefix("[Request interrupted by user") { return [.interrupted(id: id, time: time)] }
        if raw.hasPrefix("<local-command-caveat>") || text.isEmpty { return [] }
        return [.userText(id: id, time: time, text: text)]
    }

    private static func imageSources(in text: String) -> [Event] {
        let pattern = #"\[Image: source: ([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { .imageSource(String(text[$0]).trimmingCharacters(in: .whitespaces)) }
        }
    }

    private static func image(_ block: [String: Any]) -> ImageRef? {
        guard let source = block["source"] as? [String: Any] else { return nil }
        let data = source["data"] as? String
        return ImageRef(
            path: source["path"] as? String,
            base64: (data?.utf8.count ?? 0) <= maxInlineImage ? data : nil,
            mediaType: source["media_type"] as? String
        )
    }

    private static func toolResult(_ block: [String: Any], time: Date?) -> ToolResult? {
        guard let id = block["tool_use_id"] as? String else { return nil }
        var text: String
        if let string = block["content"] as? String {
            text = string
        } else if let parts = block["content"] as? [[String: Any]] {
            text = parts.map { part in
                switch part["type"] as? String {
                case "text": part["text"] as? String ?? ""
                case "image": "[imagem]"
                case "tool_reference": part["tool_name"] as? String ?? ""
                default: ""
                }
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        } else {
            text = ""
        }
        let isClipped = text.utf8.count > maxOutput
        if isClipped { text = String(decoding: Data(text.utf8.prefix(maxOutput)), as: UTF8.self) }
        return ToolResult(toolUseID: id, time: time, isError: block["is_error"] as? Bool == true, text: text, isClipped: isClipped)
    }

    // MARK: - Time

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()

    /// ISO8601DateFormatter is documented thread-safe since macOS 10.12.
    static func date(_ text: String) -> Date? {
        fractional.date(from: text) ?? whole.date(from: text)
    }
}
