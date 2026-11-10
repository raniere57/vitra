import Foundation
import Testing
@testable import VitraOrchestrator

/// A scratch directory, removed by the caller.
private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Parsing

@Test func aLinkAndACopyLineParseAsEntriesInTheOrderWritten() {
    let parsed = WorktreeSetup.parse("link vendor/ghostty-vt\ncopy Sources/CGhosttyVT/include/ghostty\n")

    #expect(parsed.entries == [
        WorktreeSetup.Entry(kind: .link, path: "vendor/ghostty-vt"),
        WorktreeSetup.Entry(kind: .copy, path: "Sources/CGhosttyVT/include/ghostty"),
    ])
    #expect(parsed.skipped.isEmpty)
}

@Test func commentsAndBlankLinesAreIgnoredAndNotReportedAsSkipped() {
    let parsed = WorktreeSetup.parse("""
    # why the worktree needs this

       # an indented comment
    link vendor/a

    """)

    #expect(parsed.entries == [WorktreeSetup.Entry(kind: .link, path: "vendor/a")])
    #expect(parsed.skipped.isEmpty)
}

@Test func anAbsolutePathIsRefusedAndNamed() {
    let parsed = WorktreeSetup.parse("link /usr/local/lib\n")

    #expect(parsed.entries.isEmpty)
    #expect(parsed.skipped.count == 1)
    #expect(parsed.skipped[0].contains("link /usr/local/lib"))
    #expect(parsed.skipped[0].contains("relative"))
}

@Test func aPathWithParentComponentsIsRefusedWhereverTheyAppear() {
    let parsed = WorktreeSetup.parse("copy ../secrets\nlink vendor/../../elsewhere\n")

    #expect(parsed.entries.isEmpty)
    #expect(parsed.skipped.count == 2)
    #expect(parsed.skipped.allSatisfy { $0.contains("..") })
}

@Test func anUnknownVerbOrAMissingPathIsSkippedAndTheRestStillParses() {
    let parsed = WorktreeSetup.parse("move a b\nlink\ncopy keep\n")

    #expect(parsed.entries == [WorktreeSetup.Entry(kind: .copy, path: "keep")])
    #expect(parsed.skipped.count == 2)
    #expect(parsed.skipped[0].contains("move a b"))
    #expect(parsed.skipped[1].contains("link"))
}

@Test func aPathWithSpacesKeepsThemAll() {
    let parsed = WorktreeSetup.parse("copy Some Folder/file name.txt\n")

    #expect(parsed.entries == [WorktreeSetup.Entry(kind: .copy, path: "Some Folder/file name.txt")])
}

// MARK: - Applying

@Test func applyingLinksAndCopiesIntoTheTreeAndSkipsAMissingSource() throws {
    let repository = try scratchDirectory()
    let tree = try scratchDirectory()
    defer {
        try? FileManager.default.removeItem(at: repository)
        try? FileManager.default.removeItem(at: tree)
    }
    try write("link vendor/lib\ncopy include\ncopy nothing/here\n", to: repository.appendingPathComponent(".vitra/worktree"))
    try write("archive", to: repository.appendingPathComponent("vendor/lib/a.a"))
    try write("header", to: repository.appendingPathComponent("include/h.h"))

    let skipped = WorktreeSetup.apply(repository: repository, to: tree)

    let linked = tree.appendingPathComponent("vendor/lib")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path) == repository.appendingPathComponent("vendor/lib").path)
    #expect(try String(contentsOf: linked.appendingPathComponent("a.a"), encoding: .utf8) == "archive")

    let copied = tree.appendingPathComponent("include/h.h")
    let attributes = try FileManager.default.attributesOfItem(atPath: copied.path)
    #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    #expect(try String(contentsOf: copied, encoding: .utf8) == "header")

    #expect(skipped.count == 1)
    #expect(skipped[0].contains("copy nothing/here"))
}

@Test func anExistingFileInTheTreeIsNotOverwritten() throws {
    let repository = try scratchDirectory()
    let tree = try scratchDirectory()
    defer {
        try? FileManager.default.removeItem(at: repository)
        try? FileManager.default.removeItem(at: tree)
    }
    try write("copy config.txt\n", to: repository.appendingPathComponent(".vitra/worktree"))
    try write("theirs", to: repository.appendingPathComponent("config.txt"))
    try write("mine", to: tree.appendingPathComponent("config.txt"))

    let skipped = WorktreeSetup.apply(repository: repository, to: tree)

    #expect(try String(contentsOf: tree.appendingPathComponent("config.txt"), encoding: .utf8) == "mine")
    #expect(skipped.count == 1)
    #expect(skipped[0].contains("already"))
}

@Test func aRepositoryWithoutAWorktreeFileChangesNothing() throws {
    let repository = try scratchDirectory()
    let tree = try scratchDirectory()
    defer {
        try? FileManager.default.removeItem(at: repository)
        try? FileManager.default.removeItem(at: tree)
    }
    try write("theirs", to: repository.appendingPathComponent("config.txt"))

    #expect(WorktreeSetup.apply(repository: repository, to: tree).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: tree.path).isEmpty)
}
