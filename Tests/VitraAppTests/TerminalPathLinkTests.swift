import Foundation
import Testing
@testable import VitraApp

private func row(_ text: String, width: Int) -> [Character] {
    Array(text) + Array(repeating: " ", count: max(0, width - text.count))
}

private func filled(_ text: String) -> [Character] {
    Array(text)
}

@Test func anAbsolutePathUnderTheClickIsFound() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vitra-path-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("shot.png")
    try Data().write(to: file)

    let line = row("wrote \(file.path) ok", width: 120)
    let hit = try #require(TerminalPathLink.match(in: line, at: 12, base: root))
    #expect(hit.url.path == file.path)
}

@Test func aTildePathExpandsToHomeWhenTheFileIsThere() throws {
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    let name = "vitra-path-link-\(UUID().uuidString).txt"
    let file = home.appendingPathComponent(name)
    try Data("x".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let line = row("see ~/\(name)", width: 80)
    let hit = try #require(TerminalPathLink.match(in: line, at: 6, base: home))
    #expect(hit.url.path == file.path)
}

@Test func aRelativePathResolvesAgainstTheBase() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vitra-rel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("src/App.swift")
    try Data().write(to: file)

    let line = row("edit src/App.swift", width: 40)
    let hit = try #require(TerminalPathLink.match(in: line, at: 8, base: root))
    #expect(hit.url.path == file.path)
}

@Test func aPathWrappedAcrossTwoRowsIsOneToken() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vitra-wrap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let name = "very-long-file-name.swift"
    let file = root.appendingPathComponent(name)
    try Data().write(to: file)
    let path = file.path
    let width = 24
    let first = filled(String(path.prefix(width)))
    let rest = String(path.dropFirst(width))
    #expect(first.count == width)
    let second = row(rest + " extra", width: width)
    let hit = try #require(TerminalPathLink.match(
        rows: [first, second],
        row: 1,
        column: 2,
        base: root
    ))
    #expect(hit.url.path == path)
}

@Test func trailingPunctuationAndALineColumnAreDropped() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vitra-loc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    let file = root.appendingPathComponent("src/App.swift")
    try Data().write(to: file)

    let line = row("src/App.swift:12:3:", width: 40)
    let hit = try #require(TerminalPathLink.match(in: line, at: 3, base: root))
    #expect(hit.url.path == file.path)
    #expect(hit.line == 12)
    #expect(hit.column == 3)
}

@Test func quotesAndBackticksAroundAPathAreStripped() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vitra-quote-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("notes.md")
    try Data().write(to: file)

    let tick = row("`\(file.path)`", width: 120)
    let hit = try #require(TerminalPathLink.match(in: tick, at: 4, base: root))
    #expect(hit.url.path == file.path)
    let quoted = row("see \"\(file.path)\"", width: 120)
    let quotedHit = try #require(TerminalPathLink.match(in: quoted, at: 10, base: root))
    #expect(quotedHit.url.path == file.path)
}

@Test func aClickOnWhitespaceIsNotAPath() {
    let line = row("/tmp/x.swift", width: 40)
    #expect(TerminalPathLink.match(in: line, at: 20, base: URL(fileURLWithPath: "/tmp")) == nil)
}

@Test func aPathThatIsNotOnDiskIsNotALink() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vitra-missing-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let line = row("open \(root.path)/nope.swift", width: 120)
    #expect(TerminalPathLink.match(in: line, at: 12, base: root) == nil)
}

@Test func aPathDoesNotRunPastASpace() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vitra-space-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("one.swift")
    try Data().write(to: file)
    try Data().write(to: root.appendingPathComponent("two.swift"))

    let line = row("one.swift two.swift", width: 40)
    #expect(TerminalPathLink.match(in: line, at: 2, base: root) == nil)
    let slashed = row("src/one.swift and more", width: 40)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("src/one.swift"))
    let hit = try #require(TerminalPathLink.match(in: slashed, at: 4, base: root))
    #expect(hit.url.lastPathComponent == "one.swift")
}

@Test func aPathWithSpacesWordWrappedOverRowsIsFoundFromAnyOfItsWords() throws {
    let path = "/Users/x/Downloads/Apresentação de resultados (versão infográfica) - outubro fechado.pptx"
    let rows = [
        row("pagaram (37%). Arquivo:", width: 60),
        row("/Users/x/Downloads/Apresentação de resultados (versão", width: 60),
        row("  infográfica) - outubro", width: 60),
        row("  fechado.pptx. Script e regra atualizados no main.", width: 60),
    ]
    let exists: (URL) -> Bool = { $0.path == path }
    for (line, column) in [(1, 3), (1, 34), (2, 5), (3, 4)] {
        let hit = try #require(TerminalPathLink.matchSpaced(rows: rows, row: line, column: column, fileExists: exists))
        #expect(hit.url.path == path)
    }
    #expect(TerminalPathLink.matchSpaced(rows: rows, row: 3, column: 20, fileExists: exists) == nil)
    #expect(TerminalPathLink.matchSpaced(rows: rows, row: 0, column: 3, fileExists: exists) == nil)
}
