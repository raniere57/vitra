import Foundation
import Testing
@testable import VitraOrchestrator

/// A runs root of synthetic runs, read as a new process would read it.
private struct History {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-index-\(UUID().uuidString)/runs")

    /// An orchestrator with nothing of the root in memory.
    func fresh() -> Orchestrator {
        RunCache.forget(root)
        return Orchestrator(root: root, executables: Executables(paths: [:]))
    }

    var indexFile: URL { root.appendingPathComponent(".index") }

    /// Each run read whole, with the index out of the way.
    func fullRead(_ ids: [String]) throws -> [Run] {
        let saved = try? Data(contentsOf: indexFile)
        try? FileManager.default.removeItem(at: indexFile)
        defer {
            if let saved { try? saved.write(to: indexFile) }
            RunCache.forget(root)
        }
        let orchestrator = fresh()
        return try ids.map { try orchestrator.status($0, fullText: false) }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
}

/// A run cancelled long ago, its process gone.
private func writeCancelled(_ id: String, under root: URL, started: Date) throws {
    try SyntheticRuns.write(id: id, index: 4, started: started, under: root)
    let directory = root.appendingPathComponent(id)
    for name in ["exit", "summary.json"] { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    try Data("killed\n".utf8).write(to: directory.appendingPathComponent("stderr"))
    FileManager.default.createFile(atPath: directory.appendingPathComponent("cancelled").path, contents: nil)
}

@Test func theIndexedHistoryIsExactlyWhatReadingEveryRunGives() throws {
    let history = History()
    defer { history.cleanUp() }
    let ids = try SyntheticRuns.write(40, under: history.root)
    try writeCancelled("ffff0001", under: history.root, started: Date().addingTimeInterval(-90))

    // No index yet: the first look reads every run and writes it.
    let first = history.fresh().recent(limit: 100)
    #expect(FileManager.default.fileExists(atPath: history.indexFile.path))
    #expect(first.count == 41)
    #expect(first.map(\.started) == first.map(\.started).sorted(by: >))

    // A second look in the same process, and one in a new process from the
    // index alone, are the same runs.
    let orchestrator = history.fresh()
    let fromIndex = orchestrator.recent(limit: 100)
    #expect(fromIndex == first)
    #expect(orchestrator.recent(limit: 100) == first)
    #expect(orchestrator.recent(limit: 7) == Array(first.prefix(7)))

    // And each is the run read whole.
    #expect(try history.fullRead(first.map(\.id)) == first)
    #expect(Set(first.map(\.id)) == Set(ids + ["ffff0001"]))
}

@Test func aRunRatedOrPausedAfterItWasIndexedIsReadAgain() throws {
    let history = History()
    defer { history.cleanUp() }
    let ids = try SyntheticRuns.write(5, under: history.root)
    _ = history.fresh().recent(limit: 10)
    let unrated = try #require(ids.first { id in
        !FileManager.default.fileExists(atPath: history.root.appendingPathComponent("\(id)/rating.json").path)
    })

    // Rated by another process: this one sees it on the next look.
    let reader = history.fresh()
    _ = reader.recent(limit: 10)
    try Orchestrator(root: history.root, executables: Executables(paths: [:])).rate(unrated, score: 2, note: "wrong")
    #expect(reader.recent(limit: 10).first { $0.id == unrated }?.rating?.score == 2)
    #expect(history.fresh().recent(limit: 10).first { $0.id == unrated }?.rating?.score == 2)

    FileManager.default.createFile(atPath: history.root.appendingPathComponent("\(unrated)/paused").path, contents: nil)
    #expect(reader.recent(limit: 10).first { $0.id == unrated }?.isPaused == true)
    #expect(try history.fullRead(ids) == ids.map { id in reader.recent(limit: 10).first { $0.id == id }! })
}

@Test func aMissingOrDamagedIndexIsRebuiltAndAGoneRunLeavesIt() throws {
    let history = History()
    defer { history.cleanUp() }
    let ids = try SyntheticRuns.write(6, under: history.root)
    let expected = history.fresh().recent(limit: 10)

    try FileManager.default.removeItem(at: history.indexFile)
    #expect(history.fresh().recent(limit: 10) == expected)

    // A line cut short by a crash, and one that is not ours, are skipped.
    let handle = try FileHandle(forWritingTo: history.indexFile)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"id\":\"cut short\n not json at all\n".utf8))
    try handle.close()
    #expect(history.fresh().recent(limit: 10) == expected)

    // A run that left the root is not listed, and the next rewrite drops it.
    try FileManager.default.removeItem(at: history.root.appendingPathComponent(ids[0]))
    let orchestrator = history.fresh()
    #expect(orchestrator.recent(limit: 10).map(\.id) == expected.map(\.id).filter { $0 != ids[0] })
    orchestrator.cache.index.rewrite(keeping: Set(orchestrator.cache.runIDs()))
    let text = try String(contentsOf: history.indexFile, encoding: .utf8)
    #expect(!text.contains(ids[0]))
    #expect(text.split(separator: "\n").count == 5)
}

@Test func aRunWhoseRecordAppearsAfterItsDirectoryIsListedOnceItDoes() throws {
    let history = History()
    defer { history.cleanUp() }
    try SyntheticRuns.write(3, under: history.root)
    let orchestrator = history.fresh()
    #expect(orchestrator.recent(limit: 10).count == 3)

    // A spawn makes the directory first and writes run.json last.
    let staging = history.root.deletingLastPathComponent().appendingPathComponent("staging")
    try SyntheticRuns.write(id: "abcdef01", index: 1, started: Date().addingTimeInterval(60), under: staging)
    let record = staging.appendingPathComponent("abcdef01/run.json")
    let late = try Data(contentsOf: record)
    try FileManager.default.removeItem(at: record)
    try FileManager.default.moveItem(at: staging.appendingPathComponent("abcdef01"), to: history.root.appendingPathComponent("abcdef01"))
    #expect(orchestrator.recent(limit: 10).count == 3)
    try late.write(to: history.root.appendingPathComponent("abcdef01/run.json"), options: .atomic)
    #expect(orchestrator.recent(limit: 10).first?.id == "abcdef01")
}
