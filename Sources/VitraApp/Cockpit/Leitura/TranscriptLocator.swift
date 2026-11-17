import Foundation

/// Where a project's maestro writes its conversation.
///
/// Claude Code keeps it at `~/.claude/projects/<slug>/<session>.jsonl`, the
/// slug being the project's absolute path with every "/" and "." turned into
/// "-". The session is the one the SessionStart hook last noted — it changes
/// with /resume, /clear and compaction into a new file — else the one the
/// project was started with.
enum TranscriptLocator {
    static func slug(for project: String) -> String {
        project.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    /// The file for `session`: under the project's own folder, or under a
    /// worktree's when the maestro was started in one; where Claude Code
    /// would write it when it is nowhere yet.
    static func url(project: String, session: String, root: URL = Maestro.conversationsDirectory) -> URL {
        let direct = root.appendingPathComponent(slug(for: project)).appendingPathComponent(session + ".jsonl")
        guard !FileManager.default.fileExists(atPath: direct.path) else { return direct }
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.map { $0.appendingPathComponent(session + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? direct
    }

    /// The model of the conversation's last answer, as claude names it
    /// ("Fable 5.2"): read from the end of the file.
    static func lastModel(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        guard let match = modelPattern.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).last,
              let id = Range(match.range(at: 1), in: tail)
        else { return nil }
        return displayName(String(tail[id]))
    }

    private static let modelPattern = try! NSRegularExpression(pattern: #""model":"(claude-[a-z0-9-]+)""#)

    /// "claude-fable-5-2" → "Fable 5.2".
    static func displayName(_ id: String) -> String? {
        let parts = id.split(separator: "-").dropFirst()
        guard let family = parts.first, parts.count > 1 else { return nil }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version.joined(separator: "."))
    }

    /// The session the maestro of `project` is in, as far as the app knows.
    static func session(project: CockpitProject, sessions: URL = Maestro.sessionsDirectory) -> String? {
        Maestro.rememberedSession(for: project.path, in: sessions) ?? project.session
    }
}
