import Foundation

/// `vitra mcp`: JSON-RPC on stdio in front, the GUI's socket behind.
///
/// The agent's MCP client spawns this process; it is not the window. Everything
/// that needs the window — every `tools/call` — is forwarded over the socket,
/// while `initialize` and `tools/list` are answered here so that adding the
/// server to an agent works whether or not Vitra happens to be open.
public enum StdioBridge {
    public static func run() {
        let server = MCPServer(executor: RemoteExecutor())

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }

            guard let request = try? JSONDecoder().decode(JSONRPC.Request.self, from: data) else {
                write(JSONRPC.Response(id: nil, code: .parse, message: "malformed request"))
                continue
            }

            guard let response = blocking({ await server.handle(request) }) else { continue }
            write(response)
        }
    }

    /// Runs an async call to completion on this thread.
    ///
    /// The loop is deliberately synchronous: one request at a time is exactly
    /// the concurrency an MCP stdio server needs.
    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    private static func write(_ response: JSONRPC.Response) {
        guard var data = try? JSONRPC.encode(response) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

/// Runs tool calls in the GUI, over the socket.
struct RemoteExecutor: ToolExecutor {
    /// How long Vitra is given to come up and start answering.
    private static let startupTimeout: TimeInterval = 20

    /// Sends the call, starting Vitra first if nothing is listening.
    ///
    /// An agent asking to open a page should not have to ask a person to open
    /// the app: a tool call is a good enough reason to launch it. Everything
    /// after the launch is the same path a running app takes.
    private static func send(_ request: JSONRPC.Request) throws -> JSONRPC.Response {
        do {
            return try SocketClient.send(request)
        } catch SocketError.notRunning {
            guard AppLauncher.launch() else {
                throw ToolError("Vitra is not running and could not be started.")
            }
            let deadline = Date().addingTimeInterval(startupTimeout)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                if let response = try? SocketClient.send(request) { return response }
            }
            throw ToolError("Vitra was started but did not answer in time.")
        } catch let error as SocketError {
            throw ToolError("\(error). Open Vitra and try again.")
        }
    }

    func run(tool: String, arguments: JSONValue) async throws -> String {
        let request = JSONRPC.Request(
            id: .number(1),
            method: "tools/call",
            params: ["name": .string(tool), "arguments": arguments]
        )

        let response = try Self.send(request)

        if let error = response.error { throw ToolError(error.message) }

        // The GUI answers in MCP's own result shape, so the text comes back out
        // of the same envelope this side would have built.
        let text = response.result?["content"]?.arrayValue?.first?["text"]?.stringValue
        guard let text else { throw ToolError("Vitra sent an empty result") }
        if response.result?["isError"]?.boolValue == true { throw ToolError(text) }
        return text
    }
}
