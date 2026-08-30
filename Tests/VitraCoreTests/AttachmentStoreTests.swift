import Foundation
import Testing
@testable import VitraCore

private func temporaryStore() -> AttachmentStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vitra-tests-\(UUID().uuidString)", isDirectory: true)
    return AttachmentStore(directory: directory)
}

@Test func storingWritesTheDataAndReturnsItsPath() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let url = try store.store(Data("hello".utf8), extension: "png")
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try Data(contentsOf: url) == Data("hello".utf8))
    #expect(url.pathExtension == "png")
}

@Test func storedNamesNeverNeedQuoting() throws {
    // The whole point of generating the name is that it comes back clean.
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let url = try store.store(Data("x".utf8), extension: "png")
    #expect(ShellQuoting.quote(url.lastPathComponent) == url.lastPathComponent)
}

@Test func consecutiveStoresDoNotCollide() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let first = try store.store(Data("a".utf8), extension: "png")
    let second = try store.store(Data("b".utf8), extension: "png")
    #expect(first != second)
    #expect(try Data(contentsOf: first) == Data("a".utf8))
    #expect(try Data(contentsOf: second) == Data("b".utf8))
}

@Test func purgeRemovesOnlyExpiredFiles() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let old = try store.store(Data("old".utf8), extension: "png")
    let fresh = try store.store(Data("new".utf8), extension: "png")

    // Backdate one file past the retention window.
    let longAgo = Date().addingTimeInterval(-AttachmentStore.retention - 60)
    try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)

    store.purgeExpired()

    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
}

@Test func purgeOnAMissingDirectoryIsHarmless() {
    // Runs at launch, before anything has ever been attached.
    let store = temporaryStore()
    store.purgeExpired()
}

@Test func attachmentReportsAnAbsolutePath() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let url = try store.store(Data("x".utf8), extension: "png")
    let attachment = Attachment(url: url, isTemporary: true)
    #expect(attachment.path.hasPrefix("/"))
    #expect(attachment.displayName == url.lastPathComponent)
}
