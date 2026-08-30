import Foundation
import Testing
@testable import VitraCore

private func makeTemporaryDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vitra-preview-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func anExistingFileResolves() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("note.txt")
    try "hi".write(to: file, atomically: true, encoding: .utf8)

    let target = PreviewTarget.resolve(path: file.path)
    #expect(target?.url.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL)
    #expect(target?.displayName == "note.txt")
}

@Test func aMissingFileDoesNotResolve() {
    #expect(PreviewTarget.resolve(path: "/tmp/vitra-does-not-exist-\(UUID().uuidString)") == nil)
}

@Test func aDirectoryDoesNotResolve() {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(PreviewTarget.resolve(path: directory.path) == nil)
}

@Test func aDeviceDoesNotResolve() {
    // The panel shows files. /dev/null is readable and would otherwise open.
    #expect(PreviewTarget.resolve(path: "/dev/null") == nil)
}

@Test func anEmptyPathDoesNotResolve() {
    #expect(PreviewTarget.resolve(path: "   ") == nil)
}

@Test func aRelativePathResolvesAgainstTheGivenDirectory() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("shot.png")
    try Data([0x89]).write(to: file)

    let target = PreviewTarget.resolve(path: "shot.png", relativeTo: directory)
    #expect(target?.displayName == "shot.png")
}

@Test func aRelativePathWithoutABaseDoesNotResolve() {
    #expect(PreviewTarget.resolve(path: "shot.png", relativeTo: nil) == nil)
}

@Test func aSymlinkIsFollowedToItsTarget() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("real.txt")
    try "hi".write(to: file, atomically: true, encoding: .utf8)
    let link = directory.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

    #expect(PreviewTarget.resolve(path: link.path)?.displayName == "real.txt")
}

@Test func tildeIsExpanded() throws {
    let name = "vitra-tilde-\(UUID().uuidString).txt"
    let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
    try "hi".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(PreviewTarget.resolve(path: "~/\(name)") != nil)
}

@Test func theFileFieldIsReadFromThePayload() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("a.pdf")
    try Data([0x25]).write(to: file)

    #expect(PreviewTarget.parse(payload: "file=\(file.path)")?.displayName == "a.pdf")
    // Unknown fields are skipped, not treated as an error.
    #expect(PreviewTarget.parse(payload: "kind=image;file=\(file.path)")?.displayName == "a.pdf")
    #expect(PreviewTarget.parse(payload: "kind=image") == nil)
    #expect(PreviewTarget.parse(payload: "") == nil)
}
