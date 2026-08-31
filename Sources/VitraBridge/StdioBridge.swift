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
    func run(tool: String, arguments: JSONValue) async throws -> String {
        let request = JSONRPC.Request(
            id: .number(1),
            method: "tools/call",
            params: ["name": .string(tool), "arguments": arguments]
        )

        let response: JSONRPC.Response
        do {
            response = try SocketClient.send(request)
        } catch let error as SocketError {
            throw ToolError("\(error). Open Vitra and try again.")
        }

        if let error = response.error { throw ToolError(error.message) }

        // The GUI answers in MCP's own result shape, so the text comes back out
        // of the same envelope this side would have built.
        let text = response.result?["content"]?.arrayValue?.first?["text"]?.stringValue
        guard let text else { throw ToolError("Vitra sent an empty result") }
        if response.result?["isError"]?.boolValue == true { throw ToolError(text) }
        return text
    }
}
