import Foundation
import VitraCore

/// Whether a project's terminals live in `Vitra pty-host`, where they survive
/// the app quitting and being reinstalled, and how they are named there.
enum TerminalHosting {
    /// `defaults write <bundle> ptyHost -bool false` puts the terminals back
    /// in the app, as they were. Never for an automated run: it is launched
    /// from a build folder, and must neither leave a host behind running that
    /// binary nor attach to the user's own maestro in the same project.
    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VITRA_SELF_SHOT"] == nil, environment["VITRA_COCKPIT_STORE"] == nil else { return false }
        return UserDefaults.standard.object(forKey: "ptyHost") as? Bool ?? true
    }

    /// The same for every launch of the app, so the next one finds it.
    static func sessionID(project: String, role: Role) -> String {
        "\(role.rawValue):\(project)"
    }

    enum Role: String {
        case maestro
        case shared
    }

    /// Ends every hosted terminal and the host, then `done` on the main
    /// queue — whether or not there was a host to end.
    static func endAll(then done: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            try? PTYHostClient.shutdown()
            DispatchQueue.main.async { done() }
        }
    }
}
