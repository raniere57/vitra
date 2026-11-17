import Foundation
import Testing
@testable import VitraOrchestrator

private func parse(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func worker(project: String?) -> WorkerSpec {
    WorkerSpec(cli: .claude, model: "haiku", prompt: "do it", directory: NSTemporaryDirectory(), project: project)
}

// MARK: - The role the maestro's configuration carries

@Test func theMaestrosConfigurationNamesTheMaestroRole() throws {
    let config = try parse(VitraMCPConfig.claudeConfig(binary: "/Applications/Vitra", environment: VitraMCPConfig.maestroEnvironment()))
    let vitra = try #require((config["mcpServers"] as? [String: Any])?["vitra"] as? [String: Any])

    #expect(vitra["command"] as? String == "/Applications/Vitra")
    #expect(vitra["args"] as? [String] == ["mcp"])
    #expect(vitra["env"] as? [String: String] == ["VITRA_ROLE": "maestro"])
}

// MARK: - A worker's claude configuration

@Test func aClaudeWorkerConfigurationNamesItsRun() throws {
    let run = URL(fileURLWithPath: "/home/.vitra/runs/abcd1234")
    let text = VitraMCPConfig.claudeConfig(
        binary: "/Applications/Vitra",
        environment: VitraMCPConfig.workerEnvironment(id: "abcd1234", run: run, project: "/work/app")
    )
    let config = try parse(text)
    let vitra = try #require((config["mcpServers"] as? [String: Any])?["vitra"] as? [String: Any])

    #expect(vitra["command"] as? String == "/Applications/Vitra")
    #expect(vitra["args"] as? [String] == ["mcp"])
    #expect(vitra["env"] as? [String: String] == [
        "VITRA_AGENT": "abcd1234",
        "VITRA_RUN": "/home/.vitra/runs/abcd1234",
        "VITRA_PROJECT": "/work/app",
    ])
}

@Test func theProjectIsOmittedWhenThereIsNone() {
    let run = URL(fileURLWithPath: "/home/.vitra/runs/abcd1234")
    let environment = VitraMCPConfig.workerEnvironment(id: "abcd1234", run: run, project: nil)

    #expect(environment["VITRA_PROJECT"] == nil)
    #expect(environment["VITRA_AGENT"] == "abcd1234")
    #expect(VitraMCPConfig.workerEnvironment(id: "abcd1234", run: run, project: "") == environment)
}

// MARK: - An opencode configuration

@Test func anOpencodeConfigurationStartsTheHelperWithTheRunsIdentity() throws {
    let run = URL(fileURLWithPath: "/home/.vitra/runs/abcd1234")
    let text = VitraMCPConfig.opencodeConfig(
        binary: "/Applications/Vitra",
        environment: VitraMCPConfig.workerEnvironment(id: "abcd1234", run: run, project: "/work/app")
    )
    let config = try parse(text)
    let vitra = try #require((config["mcp"] as? [String: Any])?["vitra"] as? [String: Any])

    #expect(config["$schema"] as? String == "https://opencode.ai/config.json")
    #expect(vitra["type"] as? String == "local")
    #expect(vitra["command"] as? [String] == ["/Applications/Vitra", "mcp"])
    #expect(vitra["enabled"] as? Bool == true)
    #expect(vitra["environment"] as? [String: String] == [
        "VITRA_AGENT": "abcd1234",
        "VITRA_RUN": "/home/.vitra/runs/abcd1234",
        "VITRA_PROJECT": "/work/app",
    ])
}

// MARK: - Written per run

@Test func aClaudeWorkerGetsItsOwnFileAndNoEnvironment() throws {
    let run = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: run) }

    let served = try Orchestrator.writeRunConfig(for: worker(project: "/work/app"), id: "abcd1234", run: run, binary: "/Applications/Vitra")

    let file = run.appendingPathComponent("mcp.json")
    #expect(served.config == file.path)
    #expect(served.environment.isEmpty)
    let config = try parse(String(decoding: try Data(contentsOf: file), as: UTF8.self))
    let vitra = try #require((config["mcpServers"] as? [String: Any])?["vitra"] as? [String: Any])
    #expect((vitra["env"] as? [String: String])?["VITRA_AGENT"] == "abcd1234")
}

@Test func anOpencodeWorkerGetsItsConfigThroughTheEnvironment() throws {
    let run = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: run) }
    let spec = WorkerSpec(cli: .opencode, model: "opencode/x-free", prompt: "do it", directory: NSTemporaryDirectory())

    let served = try Orchestrator.writeRunConfig(for: spec, id: "abcd1234", run: run, binary: "/Applications/Vitra")

    let file = run.appendingPathComponent("opencode.json")
    #expect(served.environment == ["OPENCODE_CONFIG": file.path])
    let config = try parse(String(decoding: try Data(contentsOf: file), as: UTF8.self))
    let vitra = try #require((config["mcp"] as? [String: Any])?["vitra"] as? [String: Any])
    #expect(vitra["command"] as? [String] == ["/Applications/Vitra", "mcp"])
    #expect((vitra["environment"] as? [String: String])?["VITRA_AGENT"] == "abcd1234")
}
