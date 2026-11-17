import Foundation
import Testing
@testable import VitraBridge
@testable import VitraOrchestrator

/// A memory root in a scratch directory, removed with the test.
private struct Scratch {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-memtools-\(UUID().uuidString)")
    var memory: ProjectMemory { ProjectMemory(root: root) }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Test func aNoteAddedThroughToolsIsReadBackAndAuthoredByTheAgent() async throws {
    let scratch = Scratch()
    defer { scratch.cleanUp() }
    let executor = MemoryToolExecutor(memory: scratch.memory, project: "/work/app", author: "abc12345")

    #expect(try await executor.run(tool: "memory_read", arguments: [:], pane: nil) == "(no notes yet)")
    #expect(try await executor.run(tool: "memory_add", arguments: ["note": "Build with bun test"], pane: nil) == "noted")

    let read = try await executor.run(tool: "memory_read", arguments: [:], pane: nil)
    #expect(read.hasSuffix("[abc12345] Build with bun test"))
}

@Test func theMaestroIsAuthoredAsMaestro() async throws {
    let scratch = Scratch()
    defer { scratch.cleanUp() }
    let executor = MemoryToolExecutor(memory: scratch.memory, project: "/work/app", author: "maestro")

    _ = try await executor.run(tool: "memory_add", arguments: ["note": "Lint with swiftlint"], pane: nil)

    #expect(try await executor.run(tool: "memory_read", arguments: [:], pane: nil).contains("[maestro] Lint with swiftlint"))
}

@Test func memoryNeedsAProjectToBeNamed() async {
    let scratch = Scratch()
    defer { scratch.cleanUp() }
    let executor = MemoryToolExecutor(memory: scratch.memory, project: nil, author: "maestro")

    await #expect(throws: ToolError("this agent is not running in a Vitra project")) {
        try await executor.run(tool: "memory_read", arguments: [:], pane: nil)
    }
    await #expect(throws: ToolError("this agent is not running in a Vitra project")) {
        try await executor.run(tool: "memory_add", arguments: ["note": "x"], pane: nil)
    }
}

@Test func aRefusedNoteComesBackAsAToolErrorTheAgentCanRead() async {
    let scratch = Scratch()
    defer { scratch.cleanUp() }
    let executor = MemoryToolExecutor(memory: scratch.memory, project: "/work/app", author: "maestro")

    await #expect(throws: ToolError(ProjectMemoryError.multiline.description)) {
        try await executor.run(tool: "memory_add", arguments: ["note": "one\ntwo"], pane: nil)
    }
}
