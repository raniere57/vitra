import Foundation

/// Something that can run a tool call. The GUI implements this; the stdio shell
/// forwards to it over the socket.
public protocol ToolExecutor: Sendable {
    /// Runs `tool` and returns the text the agent should see.
    ///
    /// `pane` names the terminal the agent is running in, when the helper
    /// could tell: it is how two agents in two panes each get a browser of
    /// their own instead of fighting over one.
    func run(tool: String, arguments: JSONValue, pane: String?) async throws -> String
}

/// A tool failure the agent is meant to read and act on.
public struct ToolError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// The MCP protocol, minus transport.
///
/// Kept free of I/O so the whole request/response surface can be tested by
/// handing it decoded requests.
public struct MCPServer: Sendable {
    /// The version answered when the client does not ask for one.
    public static let defaultProtocolVersion = "2024-11-05"

    private let executor: any ToolExecutor

    public init(executor: any ToolExecutor) {
        self.executor = executor
    }

    /// Handles one request. Returns nil for notifications, which take no reply.
    public func handle(_ request: JSONRPC.Request) async -> JSONRPC.Response? {
        if request.isNotification { return nil }

        switch request.method {
        case "initialize":
            let version = request.params?["protocolVersion"]?.stringValue ?? Self.defaultProtocolVersion
            return JSONRPC.Response(id: request.id, result: [
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "vitra", "version": "0.1.0"],
            ])

        case "ping":
            return JSONRPC.Response(id: request.id, result: [:])

        case "tools/list":
            return JSONRPC.Response(id: request.id, result: ["tools": .array(MCPTools.all)])

        case "tools/call":
            return await callTool(request)

        default:
            return JSONRPC.Response(
                id: request.id,
                code: .methodNotFound,
                message: "unknown method: \(request.method)"
            )
        }
    }

    private func callTool(_ request: JSONRPC.Request) async -> JSONRPC.Response {
        guard let name = request.params?["name"]?.stringValue else {
            return JSONRPC.Response(id: request.id, code: .invalidParams, message: "missing tool name")
        }
        guard MCPTools.names.contains(name) else {
            return JSONRPC.Response(id: request.id, code: .invalidParams, message: "unknown tool: \(name)")
        }

        let arguments = request.params?["arguments"] ?? .object([:])
        let pane = request.params?["pane"]?.stringValue
        do {
            let text = try await executor.run(tool: name, arguments: arguments, pane: pane)
            return JSONRPC.Response(id: request.id, result: Self.content(text, isError: false))
        } catch let error as ToolError {
            // A tool that fails reports through the result, not through a
            // protocol error: the agent is supposed to read this and retry.
            return JSONRPC.Response(id: request.id, result: Self.content(error.message, isError: true))
        } catch {
            return JSONRPC.Response(id: request.id, result: Self.content("\(error)", isError: true))
        }
    }

    private static func content(_ text: String, isError: Bool) -> JSONValue {
        [
            "content": [["type": "text", "text": .string(text)]],
            "isError": .bool(isError),
        ]
    }
}
