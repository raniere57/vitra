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

    public var symbolName: String {
        switch self {
        case .claudeCode: return "clock.arrow.circlepath"
        case .openCode: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The line that reopens `session` in a shell.
    ///
    /// The directory comes first because both agents list and resume the
    /// sessions of the directory they are run in.
    public func resumeCommand(for session: AgentSession) -> String {
        let cd = "cd " + ShellQuote.quote(session.projectPath) + " && "
        switch self {
        case .claudeCode: return cd + "claude --resume " + session.id + "\n"
        case .openCode: return cd + "opencode --session " + session.id + "\n"
        }
    }
}
