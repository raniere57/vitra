import Foundation

/// A command-line coding agent the terminal knows how to host.
///
/// Each one keeps its conversations somewhere of its own and resumes them with
/// a line of its own; everything else about them — a sidebar of sessions, a
/// pane that is recognised as running one, the browser in the side panel — is
/// the same work, which is why they are one type rather than two code paths.
public enum Harness: String, Codable, Sendable, CaseIterable, Identifiable {
    case claudeCode
    case openCode

    public var id: String { rawValue }

    /// What the user calls it.
    public var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .openCode: return "opencode"
        }
    }

    /// The executable, which is also what a pane running one is recognised by.
    public var command: String {
        switch self {
        case .claudeCode: return "claude"
        case .openCode: return "opencode"
        }
    }

    /// The glyph in front of a session in the sidebar and the title bar.
    public var marker: String {
        switch self {
        case .claudeCode: return "✳"
        case .openCode: return "◆"
        }
    }

    /// Where this agent keeps its conversations, for the line a sidebar shows
    /// when it has none to list.
    public var storeDescription: String {
        switch self {
        case .claudeCode: return "~/.claude/projects"
        case .openCode: return "opencode's store"
        }
    }

    /// The most recently touched sessions this agent wrote.
    public func recent(limit: Int = 80, includeArchived: Bool = false) -> AgentSession.Listing {
        switch self {
        case .claudeCode:
            return ClaudeSessionStore.recent(limit: limit, includeArchived: includeArchived)
        case .openCode:
            return OpenCodeSessionStore.recent(limit: limit, includeArchived: includeArchived)
        }
    }

    /// The session a pane is in, as far as the pane can say.
    ///
    /// Claude Code names the terminal after the conversation, so its own
    /// matching works on the title. opencode names nothing, so the directory is
    /// all there is: the newest session there is the one it can reasonably be.
    public func matching(
        title: String,
        directory: String?,
        in sessions: [AgentSession]
    ) -> AgentSession? {
        switch self {
        case .claudeCode:
            return ClaudeSessionStore.matching(title: title, directory: directory, in: sessions)
        case .openCode:
            guard let directory else { return nil }
            return sessions
                .filter { directory == $0.projectPath || directory.hasPrefix($0.projectPath + "/") }
                .max { $0.modified < $1.modified }
        }
    }

    /// The agent a process name belongs to, if it belongs to one.
    ///
    /// What the pane is actually running, asked of the kernel: a title is set
    /// by whoever cares to set one, and opencode does not.
    public static func running(_ processName: String?) -> Harness? {
        guard let processName, !processName.isEmpty else { return nil }
        return allCases.first { $0.command == processName }
    }

    /// Flags the user asked to have on every launch of an agent, from the
    /// configuration. Set by the app when the config is read; a process-wide
    /// setting because the config is one.
    nonisolated(unsafe) public static var launchFlags: [Harness: String] = [:]

    /// The executable with the user's flags, ready to be followed by arguments.
    public var launchLine: String {
        let flags = Self.launchFlags[self]?.trimmingCharacters(in: .whitespaces) ?? ""
        return flags.isEmpty ? command : command + " " + flags
    }

    /// The line that reopens the session `id`, in whatever directory the
    /// shell is already in.
    public func resumeLine(id: String) -> String {
        switch self {
        case .claudeCode: return launchLine + " --resume " + id + "\n"
        case .openCode: return launchLine + " --session " + id + "\n"
        }
    }

    /// The line that reopens `session` in a shell.
    ///
    /// The directory comes first because both agents list and resume the
    /// sessions of the directory they are run in.
    public func resumeCommand(for session: AgentSession) -> String {
        "cd " + ShellQuote.quote(session.projectPath) + " && " + resumeLine(id: session.id)
    }
}
