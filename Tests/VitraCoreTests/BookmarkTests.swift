import Foundation
import Testing
@testable import VitraCore

@Test func aQueryMatchesNamePathAndTags() {
    let bookmark = Bookmark(
        name: "Vitra",
        path: "~/Dev/vitra",
        emoji: "🧪",
        tags: ["work", "swift"]
    )

    #expect(bookmark.matches(""))
    #expect(bookmark.matches("vit"))
    #expect(bookmark.matches("dev"))
    #expect(bookmark.matches("SWIFT"))
    #expect(!bookmark.matches("python"))
}

@Test func everyTermHasToMatch() {
    let bookmark = Bookmark(name: "API", path: "~/Dev/api", tags: ["work"])

    #expect(bookmark.matches("api work"))
    #expect(!bookmark.matches("api personal"))
}

@Test func theHomeDirectoryIsShownAsTilde() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let bookmark = Bookmark(name: "Docs", path: "\(home)/Documents")

    #expect(bookmark.displayPath == "~/Documents")
}

@Test func aMissingDirectoryIsReported() {
    let bookmark = Bookmark(name: "Gone", path: "/nonexistent-\(UUID().uuidString)")

    #expect(!bookmark.exists)
}

@Test func bookmarksSurviveARoundTrip() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vitra-bookmarks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = BookmarkStore(path: directory.appendingPathComponent("bookmarks.json"))
    let written = [
        Bookmark(name: "Vitra", path: "~/Dev/vitra", emoji: "🧪", colorHex: "#5aa5e0", theme: "dark", tags: ["work"]),
        Bookmark(name: "Notes", path: "~/Notes"),
    ]

    try store.save(written)
    #expect(store.load() == written)
}

@Test func aMissingFileLoadsAsNoBookmarks() {
    let store = BookmarkStore(path: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/bookmarks.json"))

    #expect(store.load().isEmpty)
}

@Test func aCorruptFileDoesNotThrow() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vitra-bookmarks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appendingPathComponent("bookmarks.json")
    try "{ not json".write(to: path, atomically: true, encoding: .utf8)

    #expect(BookmarkStore(path: path).load().isEmpty)
}
