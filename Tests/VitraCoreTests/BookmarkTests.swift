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

@Test("a remote favourite opens an ssh session in its directory")
func remoteBookmarkRunsSSH() throws {
    let path = "/home/darlan/it's here"
    let bookmark = Bookmark(name: "Vannak", path: path, host: "VANNAK")
    #expect(bookmark.isRemote)
    #expect(bookmark.exists == false)
    #expect(bookmark.displayPath == "VANNAK:\(path)")

    // What ssh is handed is one word, whatever the path holds: the local shell
    // is asked to print it in ssh's place.
    let command = try #require(bookmark.remoteCommand)
    #expect(command.hasPrefix("ssh -t VANNAK "))
    let script = command
        .replacingOccurrences(of: "ssh -t VANNAK ", with: "printf %s ")
        .trimmingCharacters(in: .newlines)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let printed = String(
        data: pipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    )
    process.waitUntilExit()
    #expect(printed == "cd \"\(path)\" && exec \"$SHELL\" -l")
}

@Test("a command on a remote favourite runs in a login shell, then hands one back")
func remoteBookmarkRunsCommand() throws {
    let bookmark = Bookmark(name: "Vannak", path: "/srv/app", host: "VANNAK", command: "claude")
    #expect(
        bookmark.remoteCommand
            == "ssh -t VANNAK 'cd \"/srv/app\" && exec \"$SHELL\" -lic \"claude; exec \\\"\\$SHELL\\\" -l\"'\n"
    )
    #expect(
        Bookmark(name: "Box", path: "", host: "box", command: "claude").remoteCommand
            == "ssh -t box 'exec \"$SHELL\" -lic \"claude; exec \\\"\\$SHELL\\\" -l\"'\n"
    )
}

@Test("a command on a local favourite is typed as it stands")
func localBookmarkRunsCommand() throws {
    #expect(Bookmark(name: "Dev", path: "~/Dev", command: " claude ").launchCommand == "claude\n")
    #expect(Bookmark(name: "Dev", path: "~/Dev", command: "  ").launchCommand == nil)
}

@Test("a remote favourite without a directory is a bare login")
func remoteBookmarkWithoutDirectory() throws {
    #expect(Bookmark(name: "Box", path: "", host: "box").remoteCommand == "ssh box\n")
}

@Test("a local favourite has no command")
func localBookmarkHasNoCommand() throws {
    #expect(Bookmark(name: "Dev", path: "~/Dev").remoteCommand == nil)
}
