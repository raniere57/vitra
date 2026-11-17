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

    /// The file for `session`, where Claude Code would write it; the caller
    /// learns from the reader whether it is there.
    static func url(project: String, session: String, root: URL = Maestro.conversationsDirectory) -> URL {
        root.appendingPathComponent(slug(for: project)).appendingPathComponent(session + ".jsonl")
    }

    /// The session the maestro of `project` is in, as far as the app knows.
    static func session(project: CockpitProject, sessions: URL = Maestro.sessionsDirectory) -> String? {
        Maestro.rememberedSession(for: project.path, in: sessions) ?? project.session
    }
}
