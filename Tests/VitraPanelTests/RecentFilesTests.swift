import Foundation
import Testing
@testable import VitraPanel

@Test func aFileIsSortedIntoImageVideoOrTextByWhatItIs() {
    let kind = { (name: String) in RecentFiles.kind(of: URL(fileURLWithPath: "/x/" + name)) }
    #expect(["a.png", "b.JPG", "c.webp", "d.svg", "e.gif"].map(kind) == Array(repeating: .image, count: 5))
    #expect(["a.mp4", "b.mov", "c.webm"].map(kind) == Array(repeating: .video, count: 3))
    #expect(["a.md", "b.swift", "c.json", "d.txt", "e.ts"].map(kind) == Array(repeating: .text, count: 5))
    // Sound is not a video, and a binary is none of the three.
    #expect(["a.mp3", "b.zip", "c", "d.pdf"].map(kind) == [nil, nil, nil, nil])
}

@Test func theNewestFileOfTheKindComesFirstWhereverInTheProjectItIs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let files: [(String, TimeInterval)] = [
        ("old.png", 100), ("deep/down/new.png", 300), ("mid.jpg", 200), ("notes.md", 400),
        // What was downloaded, built or is git's own is not what was made.
        ("node_modules/pkg/logo.png", 900), (".git/thing.png", 900), ("dist/out.png", 900),
    ]
    for (path, time) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path)
    }
    let images = RecentFiles.find(in: root, kind: .image)
    #expect(images.map(\.url.lastPathComponent) == ["new.png", "mid.jpg", "old.png"])
    #expect(images.first?.modified == Date(timeIntervalSince1970: 300))
    #expect(RecentFiles.find(in: root, kind: .image, limit: 1).count == 1)
    #expect(RecentFiles.find(in: root, kind: .video).isEmpty)
}
