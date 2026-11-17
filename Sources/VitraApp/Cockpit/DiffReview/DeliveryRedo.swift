import Foundation
import VitraBridge
import VitraOrchestrator

/// Sends review notes back to the worker: the maestro's own `agent_redo`,
/// run in the app.
///
/// Not a copy of the redo: the same `AgentToolExecutor` the maestro's
/// `vitra mcp` helper serves, built here with the same orchestrator store and
/// the same CLIs, so the checks (still running, a sibling on the branch, an
/// audit in the way), the worker pick and the continuation in the same
/// worktree are the ones the maestro gets. The new run lands in the runs
/// directory, where the run feed picks it up like any other.
enum DeliveryRedo {
    enum Outcome: Equatable, Sendable {
        /// Started; the new run's id.
        case started(String)
        /// The tool said no, in its own words.
        case refused(String)
    }

    /// `project` and `pane` are the maestro's: a worker the helper spawns
    /// inherits them from the maestro's shell, and finds its way back to this
    /// project's browser through them.
    static func send(
        run: String,
        notes: String,
        project: String,
        pane: String,
        done: @escaping @MainActor @Sendable (Outcome) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            let outcome = await redo(run: run, notes: notes, project: project, pane: pane)
            await MainActor.run { done(outcome) }
        }
    }

    private static func redo(run: String, notes: String, project: String, pane: String) async -> Outcome {
        // Discovered here, off the main thread: it looks at the disk.
        let executables = Executables.discover()
        var environment = ProcessInfo.processInfo.environment
        // The app's PATH is thinner than the shell's, and a worker CLI may be
        // a script that needs node from Homebrew.
        environment["PATH"] = Executables.defaultSearchPath
        environment["VITRA_PANE"] = pane
        environment["VITRA_PROJECT"] = project
        let tools = AgentToolExecutor(
            orchestrator: Orchestrator(executables: executables, spawnEnvironment: environment),
            executables: executables,
            project: project
        )
        do {
            let text = try await tools.run(
                tool: "agent_redo",
                arguments: .object(["id": .string(run), "notes": .string(notes)]),
                pane: pane
            )
            return newRun(in: text).map(Outcome.started) ?? .refused(text)
        } catch let error as ToolError {
            return .refused(error.message)
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// The id out of "Started agent <id>: …", the redo's answer.
    static func newRun(in text: String) -> String? {
        let prefix = "Started agent "
        guard text.hasPrefix(prefix) else { return nil }
        let id = text.dropFirst(prefix.count).prefix { $0 != ":" && !$0.isWhitespace }
        return id.isEmpty ? nil : String(id)
    }
}
