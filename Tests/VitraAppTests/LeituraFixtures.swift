import Foundation
@testable import VitraApp

/// Synthetic Claude Code transcript lines, for the Leitura tests. Shaped
/// like the real format — one block per assistant entry, results as user
/// entries — with made-up content.
enum JSONL {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    static func stamp(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: base.addingTimeInterval(seconds))
    }

    static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func entry(_ type: String, _ uuid: String, at seconds: TimeInterval, sidechain: Bool = false, extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["type": type, "uuid": uuid, "timestamp": stamp(seconds), "isSidechain": sidechain, "sessionId": "s"]
        object.merge(extra) { _, new in new }
        return object
    }

    static func user(_ text: String, _ uuid: String, at seconds: TimeInterval, sidechain: Bool = false, meta: Bool = false) -> String {
        var extra: [String: Any] = ["message": ["role": "user", "content": text]]
        if meta { extra["isMeta"] = true }
        return line(entry("user", uuid, at: seconds, sidechain: sidechain, extra: extra))
    }

    static func userBlocks(_ blocks: [[String: Any]], _ uuid: String, at seconds: TimeInterval, meta: Bool = false) -> String {
        var extra: [String: Any] = ["message": ["role": "user", "content": blocks]]
        if meta { extra["isMeta"] = true }
        return line(entry("user", uuid, at: seconds, extra: extra))
    }

    static func assistant(_ block: [String: Any], _ uuid: String, at seconds: TimeInterval, sidechain: Bool = false) -> String {
        line(entry("assistant", uuid, at: seconds, sidechain: sidechain, extra: ["message": ["role": "assistant", "content": [block]]]))
    }

    static func text(_ text: String, _ uuid: String, at seconds: TimeInterval, sidechain: Bool = false) -> String {
        assistant(["type": "text", "text": text], uuid, at: seconds, sidechain: sidechain)
    }

    static func thinking(_ uuid: String, at seconds: TimeInterval) -> String {
        assistant(["type": "thinking", "thinking": "", "signature": "x"], uuid, at: seconds)
    }

    static func tool(_ id: String, _ name: String, _ input: [String: Any], _ uuid: String, at seconds: TimeInterval) -> String {
        assistant(["type": "tool_use", "id": id, "name": name, "input": input], uuid, at: seconds)
    }

    static func result(_ id: String, _ content: String, error: Bool = false, _ uuid: String, at seconds: TimeInterval) -> String {
        userBlocks([["type": "tool_result", "tool_use_id": id, "content": content, "is_error": error]], uuid, at: seconds)
    }

    static func system(_ subtype: String, _ uuid: String, at seconds: TimeInterval, extra: [String: Any] = [:]) -> String {
        var all = extra
        all["subtype"] = subtype
        return line(entry("system", uuid, at: seconds, extra: all))
    }

    static func items(_ lines: [String]) -> [TranscriptItem] {
        TranscriptChunk(events: lines.flatMap { TranscriptLine.events(from: Data($0.utf8)) }).items
    }

    /// A short conversation: a question, three tool calls (one failing), an answer.
    static let conversation: [String] = [
        user("Rode os testes, por favor", "u1", at: 0),
        thinking("a0", at: 1),
        tool("t1", "Bash", ["command": "swift test", "description": "Rodar os testes"], "a1", at: 2),
        result("t1", "Test run passed", "r1", at: 32),
        tool("t2", "Read", ["file_path": "/p/Sources/App/Main.swift", "offset": 10, "limit": 20], "a2", at: 33),
        result("t2", "code", "r2", at: 34),
        tool("t3", "Edit", ["file_path": "/p/Sources/App/Main.swift", "old_string": "a\nb", "new_string": "a\nc\nd"], "a3", at: 35),
        result("t3", "String not found in file\nmore", error: true, "r3", at: 36),
        text("Pronto: **tudo passou**.", "a4", at: 40),
        system("turn_duration", "d1", at: 41, extra: ["durationMs": 41000]),
    ]
}
