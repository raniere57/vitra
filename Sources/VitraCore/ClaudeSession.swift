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
    /// Put away in the desktop app. Hidden here too, unless asked for.
    public let isArchived: Bool

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

    public init(
        id: String,
        title: String,
        projectPath: String,
        modified: Date,
        isArchived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.projectPath = projectPath
        self.modified = modified
        self.isArchived = isArchived
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

    /// What the sidebar shows, and what it left out.
    public struct Listing: Sendable, Equatable {
        public let sessions: [ClaudeSession]
        /// How many archived sessions were dropped, for the line that says so.
        public let archivedHidden: Int

        public init(sessions: [ClaudeSession], archivedHidden: Int) {
            self.sessions = sessions
            self.archivedHidden = archivedHidden
        }
    }

    /// The most recently touched sessions, newest first.
    ///
    /// Archived ones are counted and dropped: they are sessions the user has
    /// already put away in the app, and a list that ignores that is a list of
    /// everything that ever happened.
    public static func recent(
        limit: Int = 80,
        in directory: URL = ClaudeSessionStore.directory,
        indexDirectory: URL = ClaudeSessionIndex.directory,
        includeArchived: Bool = false
    ) -> Listing {
        let index = ClaudeSessionIndex.load(from: indexDirectory)
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return Listing(sessions: [], archivedHidden: 0) }

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

        var seen: Set<String> = []
        let all = files
            .filter { !index.superseded.contains($0.url.deletingPathExtension().lastPathComponent) }
            .compactMap { session(at: $0.url, modified: $0.modified, index: index) }
            .filter { session in
                // A session the app knows is listed as the app lists it. One it
                // does not know can be the same conversation resumed twice, two
                // files with the same opening prompt: the newest is the one to
                // reopen, and the files are already newest first.
                guard index[session.id] == nil else { return true }
                return seen.insert(session.projectPath + "\u{0}" + session.title).inserted
            }
        let hidden = all.filter(\.isArchived).count
        return Listing(
            sessions: includeArchived ? all : all.filter { !$0.isArchived },
            archivedHidden: hidden
        )
    }

    /// The line a shell needs to reopen the session.
    ///
    /// The directory comes first because `--resume` only lists the sessions of
    /// the directory it is run in.
    /// The session a terminal is showing, recognised by the title it wears.
    ///
    /// Claude Code names the terminal after the conversation and decorates it
    /// with a status glyph that changes while it works, so the comparison is
    /// made on the letters alone. The directory is what keeps two projects with
    /// a session called "Marketing" apart, and the newest wins when a project
    /// has the same conversation twice.
    public static func matching(
        title: String,
        directory: String?,
        in sessions: [ClaudeSession]
    ) -> ClaudeSession? {
        let wanted = plainTitle(title)
        // Two letters is not a name, it is a coincidence waiting to happen.
        guard wanted.count >= 3 else { return nil }
        return sessions
            .filter { plainTitle($0.title) == wanted && belongs(directory, to: $0) }
            .max { $0.modified < $1.modified }
    }

    /// Whether a terminal sitting in `directory` is inside a session's project.
    /// A worktree runs under the project it belongs to, and a session's own path
    /// can be the worktree while the terminal is at the root.
    private static func belongs(_ directory: String?, to session: ClaudeSession) -> Bool {
        guard let directory else { return true }
        return directory == session.projectPath
            || directory.hasPrefix(session.projectPath + "/")
            || session.projectPath.hasPrefix(directory + "/")
    }

    /// A title with its decoration taken off: the glyph in front, the spaces
    /// around it, and the case.
    private static func plainTitle(_ title: String) -> String {
        String(title.drop { !$0.isLetter && !$0.isNumber })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public static func resumeCommand(for session: ClaudeSession) -> String {
        "cd " + ShellQuote.quote(session.projectPath) + " && claude --resume " + session.id + "\n"
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Reads one transcript's head and tail and builds a session from them.
    static func session(
        at url: URL,
        modified: Date,
        index: SessionIndex = .empty
    ) -> ClaudeSession? {
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

        // The app's own title wins: it is the one the user reads in the app,
        // and the one they renamed by hand when they renamed anything.
        let id = url.deletingPathExtension().lastPathComponent
        let entry = index[id]

        // What a compaction leaves behind is not a session: it opens with a
        // summary the CLI wrote, not with anything the user said. The app lists
        // the conversation once, under the id still running; only when the app
        // itself points at this file is it the conversation and not a fragment.
        if headFields.isContinuation, entry == nil { return nil }

        guard let title = entry?.title
            ?? tailFields.title
            ?? headFields.title
            ?? tailFields.prompt
            ?? headFields.prompt
        // Nothing said, nothing named: a uuid in the list is a row nobody clicks.
        else { return nil }

        return ClaudeSession(
            id: id,
            title: Self.trim(title),
            projectPath: projectPath,
            modified: modified,
            isArchived: entry?.isArchived ?? false
        )
    }

    private struct Fields {
        var title: String?
        var cwd: String?
        var prompt: String?
        /// The first thing said here was the CLI summarising an older session.
        var isContinuation = false
    }

    /// How a compacted session opens, verbatim.
    private static let continuationMarker = "This session is being continued from a previous conversation"

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
                let text = userText(in: object)
                if fields.title == nil, text?.hasPrefix(continuationMarker) == true {
                    fields.isContinuation = true
                }
                fields.prompt = text.flatMap(readable)
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
