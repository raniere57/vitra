import CryptoKit
import Foundation
import VitraCore

/// A diary every maestro of one folder writes to and reads from.
///
/// Two tabs on the same project are two conversations, and each knows only
/// its own: in a day they drift into what look like two projects. At the end
/// of each turn the hook notes what was asked, what was answered and the
/// commits made; at the start of a conversation, and before each prompt, a
/// maestro is told what the other tabs did since it last heard.
enum ProjectJournal {
    struct Entry: Codable, Equatable {
        let time: Date
        let session: String
        let tab: String
        let prompt: String
        let answer: String
        let commits: [String]
    }

    /// How far back a new conversation is told about, and how much.
    static let startWindow: TimeInterval = 3 * 24 * 3600
    static let startCount = 15
    static let promptCount = 10

    static var directory: URL { Vitra.supportDirectory.appendingPathComponent("journal") }

    /// The folder a tab works in: "/x/hapto#2" is "/x/hapto".
    static func folder(of tab: String) -> String {
        var folder = tab
        if let hash = folder.lastIndex(of: "#"), Int(folder[folder.index(after: hash)...]) != nil {
            folder = String(folder[..<hash])
        }
        return CockpitProject(path: folder).path
    }

    static func file(for tab: String, in directory: URL = directory) -> URL {
        let digest = SHA256.hash(data: Data(folder(of: tab).utf8))
        return directory.appendingPathComponent(digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".jsonl")
    }

    // MARK: - Hooks

    /// What `Vitra hook <event>` adds for the journal. Stop writes the turn;
    /// UserPromptSubmit returns the other tabs' news, which claude adds to the
    /// conversation. Nil when there is nothing to say.
    static func hook(event: String?, input: Data, tab: String?, in directory: URL = directory, now: Date = Date()) -> String? {
        guard let tab, !tab.isEmpty,
              let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let session = payload["session_id"] as? String,
              Maestro.belongs(cwd: payload["cwd"] as? String, to: tab)
        else { return nil }
        switch event ?? payload["hook_event_name"] as? String {
        case "Stop":
            guard let path = payload["transcript_path"] as? String,
                  let turn = lastTurn(in: URL(fileURLWithPath: path))
            else { return nil }
            let cwd = payload["cwd"] as? String ?? folder(of: tab)
            let entry = Entry(
                time: now, session: session, tab: tabName(tab),
                prompt: clipped(turn.prompt, 300), answer: clipped(turn.answer, 600),
                commits: commits(in: cwd, since: turn.started)
            )
            append(entry, for: tab, in: directory)
            return nil
        case "UserPromptSubmit":
            return news(for: session, tab: tab, in: directory, now: now, limit: promptCount)
        default:
            return nil
        }
    }

    /// What a conversation that starts (or resumes, or is cleared) is told.
    static func start(input: Data, tab: String?, in directory: URL = directory, now: Date = Date()) -> String? {
        guard let tab, !tab.isEmpty,
              let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let session = payload["session_id"] as? String,
              Maestro.belongs(cwd: payload["cwd"] as? String, to: tab)
        else { return nil }
        return news(for: session, tab: tab, in: directory, now: now, limit: startCount)
    }

    // MARK: - Reading and writing

    static func append(_ entry: Entry, for tab: String, in directory: URL = directory) {
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = file(for: tab, in: directory)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    static func entries(for tab: String, in directory: URL = directory) -> [Entry] {
        guard let data = try? Data(contentsOf: file(for: tab, in: directory)) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: $0) }
    }

    /// The other tabs' entries this session has not been told about yet,
    /// formatted for the conversation; moves the session's cursor past them.
    static func news(for session: String, tab: String, in directory: URL, now: Date, limit: Int) -> String? {
        let cursorURL = directory.appendingPathComponent("seen-" + session)
        let seen = (try? String(contentsOf: cursorURL, encoding: .utf8)).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let since = seen ?? now.addingTimeInterval(-startWindow)
        let fresh = entries(for: tab, in: directory).filter { $0.session != session && $0.time > since }.suffix(limit)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? String(now.timeIntervalSince1970).write(to: cursorURL, atomically: true, encoding: .utf8)
        guard !fresh.isEmpty else { return nil }
        return format(Array(fresh))
    }

    static func format(_ entries: [Entry]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MM HH:mm"
        let lines = entries.map { entry in
            var line = "- \(formatter.string(from: entry.time)) · aba \(entry.tab) · pediu: \(entry.prompt) · respondeu: \(entry.answer)"
            if !entry.commits.isEmpty { line += " · commits: " + entry.commits.joined(separator: "; ") }
            return line
        }
        return """
        Diário do projeto (Vitra): o que outras abas deste mesmo projeto fizeram, a mais recente por último. \
        Use como contexto; o git tem o detalhe.
        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: - The turn that just ended

    /// The last prompt in a conversation, when it was made, and the last
    /// thing the maestro said after it. Reads the file's end only.
    static func lastTurn(in url: URL) -> (prompt: String, started: Date, answer: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        var prompt: (String, Date)?
        var answer = ""
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: 0x0A) {
            guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  entry["isSidechain"] as? Bool != true,
                  let message = entry["message"] as? [String: Any]
            else { continue }
            if entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
               let text = MaestroWorkLog.prompt(message["content"]) {
                prompt = (text, (entry["timestamp"] as? String).flatMap(iso.date(from:)) ?? Date())
                answer = ""
            } else if entry["type"] as? String == "assistant", let blocks = message["content"] as? [[String: Any]] {
                let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                if !text.isEmpty { answer = text }
            }
        }
        guard let prompt else { return nil }
        return (prompt.0, prompt.1, answer)
    }

    /// Commits made since `date` in the checkout at `cwd`, newest first.
    static func commits(in cwd: String, since date: Date) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "log", "--since=\(Int(date.timeIntervalSince1970))", "--format=%h %s", "-5"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private static func tabName(_ tab: String) -> String {
        let name = URL(fileURLWithPath: folder(of: tab)).lastPathComponent
        guard let hash = tab.lastIndex(of: "#"), let slot = Int(tab[tab.index(after: hash)...]) else { return name }
        return "\(name) \(slot)"
    }

    private static func clipped(_ text: String, _ length: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count <= length ? flat : flat.prefix(length - 1) + "…"
    }

    private static let encoder: JSONEncoder = {
        let made = JSONEncoder()
        made.dateEncodingStrategy = .secondsSince1970
        return made
    }()

    private static let decoder: JSONDecoder = {
        let made = JSONDecoder()
        made.dateDecodingStrategy = .secondsSince1970
        return made
    }()
}
