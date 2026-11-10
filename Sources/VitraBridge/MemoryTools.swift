import Foundation
import VitraOrchestrator

/// The tools that read and add a project's shared notes.
///
/// They run in this process, for the maestro and for workers alike: the notes
/// are a file on disk, and a worker has no window to forward a call to.
public enum MemoryTools {
    public static let all: [JSONValue] = [
        MCPTools.tool(
            "memory_read",
            "Read the notes earlier agents left about this project: how to build and test it, traps they hit, where things live. Read them before you start, so you do not have to find those things out again. Returns one dated line per note, or says there are none yet.",
            properties: [:],
            required: []
        ),
        MCPTools.tool(
            "memory_add",
            "Leave a note for the agents that come after you on this project. Add only what stays true beyond this task: how to build or test, a trap you hit, where something lives. Not task status, not what you did. One line, at most 300 characters.",
            properties: ["note": MCPTools.string("The fact, in one line.")],
            required: ["note"]
        ),
    ]

    public static let names: Set<String> = Set(all.compactMap { $0["name"]?.stringValue })
}

/// Runs the memory tools against the project's notes.
public struct MemoryToolExecutor: ToolExecutor {
    private let memory: ProjectMemory
    /// The project the agent runs in, from the environment the cockpit set.
    private let project: String?
    /// Who is writing: the worker's run id, or "maestro".
    private let author: String

    public init(
        memory: ProjectMemory = ProjectMemory(),
        project: String? = AgentToolExecutor.inheritedProject,
        author: String = Self.inheritedAuthor
    ) {
        self.memory = memory
        self.project = project
        self.author = author
    }

    /// The run id of a worker, or "maestro" when no worker id is set.
    public static var inheritedAuthor: String {
        let agent = ProcessInfo.processInfo.environment["VITRA_AGENT"] ?? ""
        return agent.isEmpty ? "maestro" : agent
    }

    public func run(tool: String, arguments: JSONValue, pane: String?) async throws -> String {
        guard let project else { throw ToolError("this agent is not running in a Vitra project") }
        switch tool {
        case "memory_read":
            let notes = memory.read(project: project)
            return notes.isEmpty ? "(no notes yet)" : notes
        case "memory_add":
            guard let note = arguments["note"]?.stringValue else { throw ToolError("missing argument: note") }
            do {
                try memory.add(note, author: author, project: project)
            } catch {
                // The reason is for the agent to read and rephrase from.
                throw ToolError(error.description)
            }
            return "noted"
        default:
            throw ToolError("unknown tool: \(tool)")
        }
    }
}

/// Serves the tools named in `names` here, and sends every other tool to `otherwise`.
public struct LocalToolRouter: ToolExecutor {
    private let names: Set<String>
    private let local: any ToolExecutor
    private let otherwise: any ToolExecutor

    public init(names: Set<String>, local: any ToolExecutor, otherwise: any ToolExecutor) {
        self.names = names
        self.local = local
        self.otherwise = otherwise
    }

    public func run(tool: String, arguments: JSONValue, pane: String?) async throws -> String {
        let executor = names.contains(tool) ? local : otherwise
        return try await executor.run(tool: tool, arguments: arguments, pane: pane)
    }
}
