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

@Test func aPathWithDotComponentsOrAHomeTildeIsRefused() {
    let parsed = WorktreeSetup.parse("copy .\nlink vendor/./lib\ncopy ~/keys\ncopy ~other\n")

    #expect(parsed.entries.isEmpty)
    #expect(parsed.skipped.count == 4)
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

    let outcome = WorktreeSetup.apply(repository: repository, to: tree)

    let linked = tree.appendingPathComponent("vendor/lib")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path) == repository.appendingPathComponent("vendor/lib").path)
    #expect(try String(contentsOf: linked.appendingPathComponent("a.a"), encoding: .utf8) == "archive")

    let copied = tree.appendingPathComponent("include/h.h")
    let attributes = try FileManager.default.attributesOfItem(atPath: copied.path)
    #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    #expect(try String(contentsOf: copied, encoding: .utf8) == "header")

    #expect(outcome.applied == ["vendor/lib", "include"])
    #expect(outcome.skipped.count == 1)
    #expect(outcome.skipped[0].contains("copy nothing/here"))
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

    let outcome = WorktreeSetup.apply(repository: repository, to: tree)

    #expect(try String(contentsOf: tree.appendingPathComponent("config.txt"), encoding: .utf8) == "mine")
    #expect(outcome.applied.isEmpty)
    #expect(outcome.skipped.count == 1)
    #expect(outcome.skipped[0].contains("already"))
}

@Test func aRepositoryWithoutAWorktreeFileChangesNothing() throws {
    let repository = try scratchDirectory()
    let tree = try scratchDirectory()
    defer {
        try? FileManager.default.removeItem(at: repository)
        try? FileManager.default.removeItem(at: tree)
    }
    try write("theirs", to: repository.appendingPathComponent("config.txt"))

    #expect(WorktreeSetup.apply(repository: repository, to: tree) == WorktreeSetup.Outcome())
    #expect(try FileManager.default.contentsOfDirectory(atPath: tree.path).isEmpty)
}

@Test func applyRefusesDotDotTildeAndDotEntriesEvenWhenNotParsed() throws {
    let repository = try scratchDirectory()
    let tree = try scratchDirectory()
    defer {
        try? FileManager.default.removeItem(at: repository)
        try? FileManager.default.removeItem(at: tree)
    }
    // A real file just outside the repository, which `../` would reach.
    let name = "escape-\(UUID().uuidString)"
    let escaped = repository.deletingLastPathComponent().appendingPathComponent(name)
    defer { try? FileManager.default.removeItem(at: escaped) }
    try write("outside", to: escaped)
    try write("keys", to: repository.appendingPathComponent("~/keys"))

    // Entries handed over directly, bypassing the parser.
    let outcome = WorktreeSetup.apply([
        WorktreeSetup.Entry(kind: .copy, path: "../\(name)"),
        WorktreeSetup.Entry(kind: .link, path: "~/keys"),
        WorktreeSetup.Entry(kind: .copy, path: "."),
        WorktreeSetup.Entry(kind: .copy, path: ""),
    ], repository: repository, to: tree)

    #expect(outcome.applied.isEmpty)
    #expect(outcome.skipped.count == 4)
    #expect(try FileManager.default.contentsOfDirectory(atPath: tree.path).isEmpty)
    #expect(try String(contentsOf: escaped, encoding: .utf8) == "outside")
}

@Test func aSourceThatResolvesOutsideTheRepositoryIsRefused() throws {
    let repository = try scratchDirectory()
    let tree = try scratchDirectory()
    let outside = try scratchDirectory()
    defer {
        for url in [repository, tree, outside] { try? FileManager.default.removeItem(at: url) }
    }
    try write("secret", to: outside.appendingPathComponent("key.txt"))
    try FileManager.default.createSymbolicLink(at: repository.appendingPathComponent("vendor"), withDestinationURL: outside)
    try write("link vendor/key.txt\ncopy vendor/key.txt\n", to: repository.appendingPathComponent(".vitra/worktree"))

    let outcome = WorktreeSetup.apply(repository: repository, to: tree)

    #expect(outcome.applied.isEmpty)
    #expect(outcome.skipped.count == 2)
    #expect(outcome.skipped.allSatisfy { $0.contains("outside the repository") })
    #expect(try FileManager.default.contentsOfDirectory(atPath: tree.path).isEmpty)
}

@Test func aLinkOrCopyThroughASymlinkedFolderInTheTreeIsRefused() throws {
    let repository = try scratchDirectory()
    let tree = try scratchDirectory()
    let outside = try scratchDirectory()
    defer {
        for url in [repository, tree, outside] { try? FileManager.default.removeItem(at: url) }
    }
    try write("inside", to: repository.appendingPathComponent("config/app.txt"))
    // The worktree already has `config` as a symlink to a folder outside it.
    try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("config"), withDestinationURL: outside)
    try write("link config/app.txt\ncopy config/app.txt\n", to: repository.appendingPathComponent(".vitra/worktree"))

    let outcome = WorktreeSetup.apply(repository: repository, to: tree)

    #expect(outcome.applied.isEmpty)
    #expect(outcome.skipped.count == 2)
    #expect(outcome.skipped.allSatisfy { $0.contains("symlink") })
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}
