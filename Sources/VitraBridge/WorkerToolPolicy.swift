import Foundation
import VitraOrchestrator

/// Holds a worker to its `WorkerToolTier`, on both ends of the bridge.
///
/// The helper uses it to advertise only the tier's tools — a model that never
/// sees a tool does not try it — and to refuse a call for any other. The app
/// uses it again on every call that reaches the socket, deriving the tier from
/// the run's record on disk rather than from anything the helper said: a
/// helper is a process the worker could have started itself.
public enum WorkerToolPolicy {
    /// The prefix of every refusal, so the model reads it as final.
    public static let refusalPrefix = "not available to this worker: "

    /// Why a worker of `tier`, whose run is `agent`, may not make this call,
    /// or nil when it may.
    ///
    /// Beyond the tier's list: a worker sees and drives its own browser tab
    /// only, never another agent's or the maestro's, and shoots one named
    /// app's window, never the whole display with whatever else is on it.
    public static func refusal(tool: String, arguments: JSONValue, tier: WorkerToolTier, agent: String?) -> String? {
        if let reason = tier.refusal(of: tool) { return refusalPrefix + reason }
        if let tab = nonEmpty(arguments["tab"]), tab != agent {
            return refusalPrefix + "a worker sees only its own tab, and '\(tab)' is not yours"
        }
        if tool == "screen_capture", nonEmpty(arguments["app"]) == nil {
            return refusalPrefix + "a worker captures one app's window: name it in `app`; the whole screen is not a worker's to see"
        }
        return nil
    }

    /// The app's check of a call from the socket, or nil when it may run.
    ///
    /// A call is a worker's when the helper named a run (`_agent`) or said it
    /// serves a worker (`_worker`). Its tier comes from that run's record
    /// under `runsRoot`, and a run that cannot be found there gets the least.
    /// A call that says neither is the maestro's, as it always was.
    public static func appRefusal(tool: String, arguments: JSONValue, runsRoot: URL = Orchestrator.defaultRoot) -> String? {
        guard isWorkerCall(arguments) else { return nil }
        let agent = nonEmpty(arguments["_agent"])
        return refusal(tool: tool, arguments: arguments, tier: .of(run: agent, root: runsRoot), agent: agent)
    }

    /// Whether the helper said this call comes from a worker.
    public static func isWorkerCall(_ arguments: JSONValue) -> Bool {
        nonEmpty(arguments["_agent"]) != nil || arguments["_worker"]?.boolValue == true
    }

    /// The lines of a `browser_tabs` listing that are `agent`'s own tab. A
    /// line starts with the tab's id, then ` · `.
    public static func ownTabs(_ lines: [String], agent: String?) -> [String] {
        guard let agent, !agent.isEmpty else { return [] }
        return lines.filter { $0 == agent || $0.hasPrefix(agent + " · ") }
    }

    private static func nonEmpty(_ value: JSONValue?) -> String? {
        value?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension MCPTools {
    /// What a worker of `tier` is served: the panel's and the notes' tools of
    /// its tier, each described as a worker may use it. The `tab` that lets
    /// the maestro look at another agent's tab is gone, and `app` is required.
    public static func worker(_ tier: WorkerToolTier) -> [JSONValue] {
        (panel + MemoryTools.all)
            .filter { $0["name"]?.stringValue.map(tier.tools.contains) == true }
            .map(asWorkers)
    }

    private static func asWorkers(_ tool: JSONValue) -> JSONValue {
        switch tool["name"]?.stringValue {
        case "browser_snapshot", "browser_screenshot", "browser_console":
            guard case var .object(fields) = tool,
                  case var .object(schema) = fields["inputSchema"],
                  case var .object(properties) = schema["properties"]
            else { return tool }
            properties["tab"] = nil
            schema["properties"] = .object(properties)
            fields["inputSchema"] = .object(schema)
            return .object(fields)
        case "browser_tabs":
            return MCPTools.tool(
                "browser_tabs",
                "List your own tab of Vitra's browser: its id, page title and URL. A worker sees and drives only its own tab.",
                properties: [:],
                required: []
            )
        case "screen_capture":
            return MCPTools.tool(
                "screen_capture",
                "Save a PNG of the frontmost window of the app named — \"Safari\", \"Simulator\", in any case — to ~/.vitra/screenshots and return its path; read the file to look at it. A worker names the app: the whole screen is not available to it. The first use asks the user for Screen Recording permission, which macOS only gives to a Vitra started after the permission was granted: ask the user to reopen it and try again.",
                properties: ["app": MCPTools.string("Application whose window to capture, such as \"Safari\" or \"Simulator\".")],
                required: ["app"]
            )
        default:
            return tool
        }
    }
}
