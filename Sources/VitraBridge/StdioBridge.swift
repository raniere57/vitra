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
        let out = OutputQueue()
        let group = DispatchGroup()

        // Requests are handled concurrently, not one at a time. A `tools/call`
        // can take seconds — a page loading, or the app being launched and
        // waited on — and while the old loop blocked on it the client's own
        // `ping` sat unanswered behind it and the connection was dropped as
        // dead. Reading never stops now; each request answers on its own, and
        // only the writes are serialised. Replies carry their id, so the client
        // matches them however they interleave.
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }

            guard let request = try? JSONDecoder().decode(JSONRPC.Request.self, from: data) else {
                out.write(JSONRPC.Response(id: nil, code: .parse, message: "malformed request"))
                continue
            }

            group.enter()
            Task {
                defer { group.leave() }
                if let response = await server.handle(request) { out.write(response) }
            }
        }

        // stdin closed: let the calls already in flight finish writing before
        // the process goes, so a reply is never cut off mid-line.
        group.wait()
    }
}

/// Serialises writes to stdout, the one resource the concurrent handlers share.
private final class OutputQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.vitra.mcp.stdout")

    func write(_ response: JSONRPC.Response) {
        queue.sync {
            guard var data = try? JSONRPC.encode(response) else { return }
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        }
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

        // The socket call is blocking; off the cooperative pool so it never
        // parks one of its threads for a page that takes its time.
        let response = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.send(request) })
            }
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
