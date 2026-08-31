import Foundation

/// One Claude Code conversation, as it sits on disk.
///
/// The CLI and the desktop app write the same store — `~/.claude/projects/`,
/// one directory per project, one `.jsonl` per session — so a session started
/// in the app is a session the terminal can resume.
public struct ClaudeSession: Sendable, Equatable, Identifiable {
    /// The session id, which is the file's name and what `--resume` takes.
    public let id: String
    public let title: String
    /// The directory the session was run in, read from the transcript itself
    /// rather than decoded from the folder name — the encoding replaces every
    /// slash with a dash and cannot be undone.
    public let projectPath: String
    public let modified: Date

    /// The project this session belongs to.
    ///
    /// A worktree is not its own project: a session in
    /// `farol/.claude/worktrees/eager-lamport` belongs to `farol`, which is
    /// where its work lands and where it should be listed.
    public var projectName: String {
        let components = URL(fileURLWithPath: projectPath).pathComponents
        if let index = worktreeIndex(in: components) { return components[index - 2] }
        return components.last ?? projectPath
    }

    /// The worktree the session ran in, when it ran in one.
    public var worktree: String? {
        let components = URL(fileURLWithPath: projectPath).pathComponents
        guard let index = worktreeIndex(in: components), index + 1 < components.count
        else { return nil }
        return components[index + 1]
    }

    /// Where `.claude/worktrees` sits in the path, if it is in there at all.
    private func worktreeIndex(in components: [String]) -> Int? {
        guard let index = components.lastIndex(of: "worktrees"),
              index >= 2,
              components[index - 1] == ".claude"
        else { return nil }
        return index
    }

    public init(id: String, title: String, projectPath: String, modified: Date) {
        self.id = id
        self.title = title
        self.projectPath = projectPath
        self.modified = modified
    }
}

/// Reads the session store.
///
/// Deliberately shallow: the newest transcripts only, and a bounded slice of
/// each. A session file runs to tens of megabytes, and the sidebar needs one
/// title out of it.
public enum ClaudeSessionStore {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// How much of a transcript is read from each end.
    private static let headBytes = 32 * 1024
    private static let tailBytes = 64 * 1024

    /// The most recently touched sessions, newest first.
    public static func recent(limit: Int = 80, in directory: URL = ClaudeSessionStore.directory) -> [ClaudeSession] {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Sorting by date before reading anything is what bounds the work: the
        // store holds hundreds of transcripts and the sidebar shows dozens.
        let files = projects
            .flatMap { project -> [URL] in
                (try? manager.contentsOfDirectory(
                    at: project,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ))?.filter { $0.pathExtension == "jsonl" } ?? []
            }
            .map { (url: $0, modified: modificationDate(of: $0)) }
            .sorted { $0.modified > $1.modified }
            .prefix(limit)

        return files.compactMap { session(at: $0.url, modified: $0.modified) }
    }

    /// The line a shell needs to reopen the session.
    ///
    /// The directory comes first because `--resume` only lists the sessions of
    /// the directory it is run in.
    public static func resumeCommand(for session: ClaudeSession) -> String {
        "cd " + ShellQuote.quote(session.projectPath) + " && claude --resume " + session.id + "\n"
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Reads one transcript's head and tail and builds a session from them.
    static func session(at url: URL, modified: Date) -> ClaudeSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()

        var tail = Data()
        if size > headBytes + tailBytes {
            try? handle.seek(toOffset: UInt64(size - tailBytes))
            tail = (try? handle.readToEnd()) ?? Data()
        }

        // The newest title wins, and titles are appended: the tail is where the
        // current one is. The head carries the working directory and, for a
        // session nobody has named, the prompt it started from.
        let headFields = fields(in: head)
        let tailFields = fields(in: tail)
        guard let projectPath = headFields.cwd ?? tailFields.cwd else { return nil }

        let title = tailFields.title
            ?? headFields.title
            ?? tailFields.prompt
            ?? headFields.prompt
            ?? url.deletingPathExtension().lastPathComponent

        return ClaudeSession(
            id: url.deletingPathExtension().lastPathComponent,
            title: Self.trim(title),
            projectPath: projectPath,
            modified: modified
        )
    }

    private struct Fields {
        var title: String?
        var cwd: String?
        var prompt: String?
    }

    /// Scans whole JSON lines out of a slice, ignoring the partial ones the
    /// slice necessarily starts or ends with.
    private static func fields(in data: Data) -> Fields {
        guard let text = String(data: data, encoding: .utf8) else { return Fields() }
        var fields = Fields()

        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }

            if let title = object["customTitle"] as? String, !title.isEmpty {
                fields.title = title
            }
            if fields.cwd == nil, let cwd = object["cwd"] as? String, !cwd.isEmpty {
                fields.cwd = cwd
            }
            if fields.prompt == nil, let prompt = object["lastPrompt"] as? String {
                fields.prompt = readable(prompt)
            }
            if fields.prompt == nil, object["type"] as? String == "user" {
                fields.prompt = userText(in: object).flatMap(readable)
            }
        }
        return fields
    }

    /// The text of a user turn, whether it is a plain string or content blocks.
    private static func userText(in object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text.isEmpty ? nil : text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// A prompt with the machinery taken out, or nil if that was all it was.
    ///
    /// A turn can start with a pasted image, a slash command's caveat or a
    /// `<command-name>` block, none of which name a conversation. Dropping them
    /// is what keeps the list from being a column of `<local-command-caveat>`.
    private static func readable(_ prompt: String) -> String? {
        // A session that is only a slash command is named after the command:
        // `/sessions` says more about it than the session's own uuid does.
        if let range = prompt.range(of: #"<command-name>[^<]+</command-name>"#, options: .regularExpression) {
            let command = prompt[range]
                .replacingOccurrences(of: "<command-name>", with: "")
                .replacingOccurrences(of: "</command-name>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty { return command }
        }

        var text = prompt
        // Paired blocks go with their contents: the caveat inside
        // `<local-command-caveat>` is machinery too, not a name for anything.
        for pattern in [#"<([a-zA-Z-]+)>[\s\S]*?</\1>"#, #"<[^>]+>"#, #"\[Image[^\]]*\]"#] {
            while let range = text.range(of: pattern, options: .regularExpression) {
                text.removeSubrange(range)
            }
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count >= 3 ? cleaned : nil
    }

    /// One line of it, and not a paragraph: the sidebar has one row per session.
    private static func trim(_ title: String) -> String {
        let flattened = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count <= 80 ? flattened : String(flattened.prefix(79)) + "…"
    }
}
