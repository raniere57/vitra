import Foundation
import Testing
@testable import VitraCore

/// Builds a throwaway directory tree and hands back its root.
private func makeTree() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vitra-listing-\(UUID().uuidString)")
    let manager = FileManager.default
    try manager.createDirectory(at: root.appendingPathComponent("item10"), withIntermediateDirectories: true)
    try manager.createDirectory(at: root.appendingPathComponent("item2"), withIntermediateDirectories: true)
    try manager.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
    try Data("a".utf8).write(to: root.appendingPathComponent("beta.txt"))
    try Data("a".utf8).write(to: root.appendingPathComponent("alpha.txt"))
    try Data("a".utf8).write(to: root.appendingPathComponent(".profile"))
    return root
}

@Test func foldersComeFirstAndNamesSortTheWayPeopleRead() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }

    let names = DirectoryListing.entries(of: root).map(\.name)

    #expect(names == ["item2", "item10", "alpha.txt", "beta.txt"])
}

@Test func hiddenEntriesAreLeftOutUnlessAskedFor() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(!DirectoryListing.entries(of: root).contains { $0.name == ".hidden" })
    #expect(DirectoryListing.entries(of: root, includeHidden: true).contains { $0.name == ".profile" })
}

@Test func onlyDirectoriesReachTheTree() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(DirectoryListing.directories(of: root).map(\.name) == ["item2", "item10"])
}

@Test func anUnreadableDirectoryListsAsEmptyRatherThanThrowing() {
    let missing = URL(fileURLWithPath: "/nope-\(UUID().uuidString)")

    #expect(DirectoryListing.entries(of: missing).isEmpty)
}

@Test func aPathWithQuotesAndSpacesSurvivesBeingTyped() {
    #expect(ShellQuote.quote("/tmp/my folder") == "'/tmp/my folder'")
    #expect(ShellQuote.quote("/tmp/it's here") == "'/tmp/it'\\''s here'")
    #expect(ShellQuote.changeDirectory(to: "/tmp/x") == "cd '/tmp/x'\n")
}
