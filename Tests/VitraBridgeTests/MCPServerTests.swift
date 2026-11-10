import Foundation
import Testing
@testable import VitraBridge

/// Records what it was asked to run and answers with whatever it was told to.
private struct StubExecutor: ToolExecutor {
    let answer: String
    let failure: String?

    init(answer: String = "ok", failure: String? = nil) {
        self.answer = answer
        self.failure = failure
    }

    func run(tool: String, arguments: JSONValue, pane: String?) async throws -> String {
        if let failure { throw ToolError(failure) }
        return "\(tool):\(answer):\(arguments["path"]?.stringValue ?? "-"):\(pane ?? "nopane")"
    }
}

@Test func theCallingPaneReachesTheExecutor() async {
    let server = MCPServer(executor: StubExecutor())
    let response = await server.handle(request("tools/call", [
        "name": "browser_snapshot", "arguments": [:], "pane": "ABC-123",
    ]))
    let text = response?.result?["content"]?.arrayValue?.first?["text"]?.stringValue
    #expect(text == "browser_snapshot:ok:-:ABC-123")
}

@Test func aCallWithoutAPaneStillRuns() async {
    let server = MCPServer(executor: StubExecutor())
    let response = await server.handle(request("tools/call", ["name": "browser_snapshot", "arguments": [:]]))
    let text = response?.result?["content"]?.arrayValue?.first?["text"]?.stringValue
    #expect(text == "browser_snapshot:ok:-:nopane")
}

private func request(_ method: String, _ params: JSONValue? = nil, id: JSONValue? = .number(1)) -> JSONRPC.Request {
    JSONRPC.Request(id: id, method: method, params: params)
}

@Test func initializeEchoesTheClientsProtocolVersion() async {
    let server = MCPServer(executor: StubExecutor())
    let response = await server.handle(request("initialize", ["protocolVersion": "2025-06-18"]))
    #expect(response?.result?["protocolVersion"]?.stringValue == "2025-06-18")
    #expect(response?.result?["serverInfo"]?["name"]?.stringValue == "vitra")
}

@Test func initializeFallsBackWhenTheClientNamesNoVersion() async {
    let server = MCPServer(executor: StubExecutor())
    let response = await server.handle(request("initialize"))
    #expect(response?.result?["protocolVersion"]?.stringValue == MCPServer.defaultProtocolVersion)
}

@Test func everyToolIsListedWithAUsableSchema() async {
    let server = MCPServer(executor: StubExecutor())
    let response = await server.handle(request("tools/list"))
    let tools = try? #require(response?.result?["tools"]?.arrayValue)

    #expect(tools?.count == 24)
    for tool in tools ?? [] {
        #expect(tool["name"]?.stringValue?.isEmpty == false)
        // A description is what the agent picks the tool by; an empty one is a bug.
        #expect((tool["description"]?.stringValue?.count ?? 0) > 20)
        #expect(tool["inputSchema"]?["type"]?.stringValue == "object")
        #expect(tool["inputSchema"]?["properties"] != nil)
    }
}

@Test func aToolCallReturnsItsTextAsContent() async {
    let server = MCPServer(executor: StubExecutor())
    let response = await server.handle(request("tools/call", [
        "name": "preview_file",
        "arguments": ["path": "/tmp/a.png"],
    ]))

    #expect(response?.result?["isError"]?.boolValue == false)
    #expect(response?.result?["content"]?.arrayValue?.first?["type"]?.stringValue == "text")
    #expect(response?.result?["content"]?.arrayValue?.first?["text"]?.stringValue == "preview_file:ok:/tmp/a.png:nopane")
}

/// A tool that fails answers through the result, not through a protocol error:
/// the agent is meant to read the message and try something else.
@Test func aFailingToolIsReportedAsAnErrorResult() async {
    let server = MCPServer(executor: StubExecutor(failure: "not a readable file: /tmp/nope"))
    let response = await server.handle(request("tools/call", ["name": "preview_file", "arguments": [:]]))

    #expect(response?.error == nil)
    #expect(response?.result?["isError"]?.boolValue == true)
    #expect(response?.result?["content"]?.arrayValue?.first?["text"]?.stringValue == "not a readable file: /tmp/nope")
}

@Test func anUnknownToolIsRefusedBeforeItReachesTheExecutor() async {
    let server = MCPServer(executor: StubExecutor())
    let response = await server.handle(request("tools/call", ["name": "rm_rf", "arguments": [:]]))
    #expect(response?.error?.code == JSONRPC.ErrorCode.invalidParams.rawValue)
    #expect(response?.error?.message.contains("rm_rf") == true)
}

@Test func anUnknownMethodIsAProtocolError() async {
    let server = MCPServer(executor: StubExecutor())
    let response = await server.handle(request("resources/list"))
    #expect(response?.error?.code == JSONRPC.ErrorCode.methodNotFound.rawValue)
}

@Test func notificationsGetNoReply() async {
    let server = MCPServer(executor: StubExecutor())
    let response = await server.handle(request("notifications/initialized", nil, id: nil))
    #expect(response == nil)
}

@Test func responsesRoundTripThroughJSON() throws {
    let original = JSONRPC.Response(id: .number(7), result: ["content": [["type": "text", "text": "hi"]]])
    let data = try JSONRPC.encode(original)
    let decoded = try JSONDecoder().decode(JSONRPC.Response.self, from: data)
    #expect(decoded == original)
    // The wire format is JSON-RPC 2.0, whatever the Swift types are called.
    #expect(String(data: data, encoding: .utf8)?.contains("\"jsonrpc\":\"2.0\"") == true)
}

@Test func requestsWithArbitraryArgumentsSurviveDecoding() throws {
    let json = """
    {"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"browser_type","arguments":{"ref":"e3","text":"hi","submit":true}}}
    """
    let decoded = try JSONDecoder().decode(JSONRPC.Request.self, from: Data(json.utf8))
    #expect(decoded.id == .string("abc"))
    #expect(decoded.params?["arguments"]?["submit"]?.boolValue == true)
    #expect(decoded.params?["arguments"]?["text"]?.stringValue == "hi")
}

// MARK: - Workers and the browser

@Test func aWorkerIsServedTheBrowserAndThePreviewAndNothingToDelegateWith() async {
    // A worker reaches the browser through the same helper as the maestro,
    // but a worker does not hand work on: the agent tools are not there.
    let server = MCPServer(executor: StubExecutor(), tools: MCPTools.worker)
    let listed = await server.handle(request("tools/list"))?.result?["tools"]?.arrayValue ?? []
    let names = listed.compactMap { $0["name"]?.stringValue }
    #expect(names.contains("browser_open"))
    #expect(names.contains("browser_tabs"))
    #expect(!names.contains { $0.hasPrefix("agent_") })
    // It may read the shared terminal, and may not type in it: that would be
    // a way round the commands it was allowed.
    #expect(names.contains("terminal_read"))
    #expect(!names.contains("terminal_run"))
    // Notes are shared by every agent on the project, workers included.
    #expect(names.contains("memory_read"))
    #expect(names.contains("memory_add"))
    // It may look at the screen too: a picture of a window is something only
    // the app can take, and a worker is working on one.
    #expect(names.contains("screen_capture"))
    let refused = await server.handle(request("tools/call", ["name": "agent_spawn", "arguments": [:]]))
    #expect(refused?.error?.message == "unknown tool: agent_spawn")
}

@Test func whoIsCallingIsSaidByTheHelperNeverByTheModel() {
    // The tab an agent may drive is its own. Which agent it is comes from the
    // environment the orchestrator started it in, and a name the model wrote
    // into the arguments itself is thrown away.
    let forged: JSONValue = ["url": "https://a.com", "_agent": "someone-else"]
    #expect(RemoteExecutor.arguments(forged, agent: "ab12cd34") == ["url": "https://a.com", "_agent": "ab12cd34"])
    #expect(RemoteExecutor.arguments(forged, agent: nil) == ["url": "https://a.com"])
    #expect(RemoteExecutor.arguments(forged, agent: "") == ["url": "https://a.com"])
}

@Test func lookingAtAnotherAgentsTabIsOfferedOnlyByTheToolsThatOnlyLook() {
    let takesTab = MCPTools.panel.filter { $0["inputSchema"]?["properties"]?["tab"] != nil }.compactMap { $0["name"]?.stringValue }
    #expect(takesTab.sorted() == ["browser_console", "browser_screenshot", "browser_snapshot"])
}
