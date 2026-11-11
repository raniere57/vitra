import Foundation
import Testing
@testable import VitraOrchestrator

private let day: TimeInterval = 86400

/// A runs root whose runs started some days before `now`.
private struct Aged {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-sweep-\(UUID().uuidString)")
    var root: URL { base.appendingPathComponent("runs") }
    let now = Date()

    func orchestrator() -> Orchestrator {
        RunCache.forget(root)
        return Orchestrator(root: root, executables: Executables(paths: [:]))
    }

    /// A finished run that started `days` ago, with a long answer whose
    /// summary keeps only the start.
    @discardableResult
    func run(_ id: String, daysAgo days: Double, longAnswer: Bool = false) throws -> String {
        try SyntheticRuns.write(id: id, index: Int(days), started: now.addingTimeInterval(-days * day), under: root)
        if longAnswer {
            let directory = root.appendingPathComponent(id)
            let text = String(repeating: "answer ", count: 1000)
            let stdout = #"{"result":"\#(text)","is_error":false}"#
            try Data(stdout.utf8).write(to: directory.appendingPathComponent("stdout"))
            try FileManager.default.removeItem(at: directory.appendingPathComponent("summary.json"))
        }
        return id
    }

    /// Changes fields of a run's record, as a spawn with them would have written it.
    func edit(_ id: String, _ fields: [String: Any]) throws {
        let url = root.appendingPathComponent("\(id)/run.json")
        var record = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        record.merge(fields) { _, new in new }
        try JSONSerialization.data(withJSONObject: record).write(to: url, options: .atomic)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    /// Every file under the base, with its size: what a sweep could change.
    func snapshot() -> [String: Int] {
        var files: [String: Int] = [:]
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            files[url.path] = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        }
        return files
    }

    func archived(_ id: String) -> URL {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: started(id))
        return base.appendingPathComponent("runs-archive")
            .appendingPathComponent(String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0))
            .appendingPathComponent(id)
    }

    func started(_ id: String) -> Date {
        let url = FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path)
            ? root.appendingPathComponent("\(id)/run.json") : archivedRecord(id)
        let record = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(RunRecord.self, from: $0) }
        return record?.started ?? .distantPast
    }

    private func archivedRecord(_ id: String) -> URL {
        let archive = base.appendingPathComponent("runs-archive")
        let months = (try? FileManager.default.contentsOfDirectory(atPath: archive.path)) ?? []
        return months.map { archive.appendingPathComponent("\($0)/\(id)/run.json") }
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? archive
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }
}

private func git(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test func nothingInUseOrRecentIsTouched() throws {
    let aged = Aged()
    defer { aged.cleanUp() }
    try aged.run("aaaa0001", daysAgo: 10)
    // Running: its process group is this test's own, which is alive.
    try aged.run("aaaa0002", daysAgo: 300)
    try aged.edit("aaaa0002", ["pid": Int(getpgrp())])
    for name in ["exit", "summary.json"] { try FileManager.default.removeItem(at: aged.root.appendingPathComponent("aaaa0002/\(name)")) }
    try aged.run("aaaa0003", daysAgo: 300)
    FileManager.default.createFile(atPath: aged.root.appendingPathComponent("aaaa0003/paused").path, contents: nil)
    // A worktree still on disk.
    try aged.run("aaaa0004", daysAgo: 300)
    try aged.edit("aaaa0004", ["worktree": aged.base.path])
    // Audited by a run that is still going.
    try aged.run("aaaa0005", daysAgo: 300)
    try Data("aaaa0002".utf8).write(to: aged.root.appendingPathComponent("aaaa0005/audit"))
    // A branch nobody merged or discarded.
    let repository = aged.base.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try git(["init", "-q"], in: repository)
    try git(["commit", "-q", "--allow-empty", "-m", "base"], in: repository)
    try git(["branch", "vitra/aaaa0006"], in: repository)
    try aged.run("aaaa0006", daysAgo: 300)
    try aged.edit("aaaa0006", ["repository": repository.path, "branch": "vitra/aaaa0006"])

    let before = aged.snapshot()
    let result = aged.orchestrator().sweep(dryRun: false, now: aged.now, maxSteps: .max, keep: 0)
    #expect(result.compacted.isEmpty)
    #expect(result.archived.isEmpty)
    #expect(aged.snapshot().filter { !$0.key.contains("/.") } == before.filter { !$0.key.contains("/.") })

    // Once the branch is closed, that run is old news like any other.
    FileManager.default.createFile(atPath: aged.root.appendingPathComponent("aaaa0006/closed").path, contents: nil)
    #expect(aged.orchestrator().sweep(dryRun: true, now: aged.now, maxSteps: .max, keep: 0).archived == ["aaaa0006"])
}

@Test func aCompactedRunStillReportsItsAnswerFromItsSummary() throws {
    let aged = Aged()
    defer { aged.cleanUp() }
    let id = try aged.run("bbbb0001", daysAgo: 40, longAnswer: true)
    let orchestrator = aged.orchestrator()
    let whole = try orchestrator.status(id)
    let cut = try orchestrator.status(id, fullText: false)
    #expect(whole.output?.text.count == 7000)
    #expect(cut.output?.text.count == RunSummary.textLimit)

    let result = orchestrator.sweep(dryRun: false, now: aged.now)
    #expect(result.compacted == [id])
    #expect(result.archived.isEmpty)
    #expect(!aged.exists("\(id)/stdout") && !aged.exists("\(id)/stderr") && !aged.exists("\(id)/prompt"))
    #expect(aged.exists("\(id)/summary.json") && aged.exists("\(id)/run.json"))

    // What agent_wait prints comes from status: the answer, cut as before.
    for reader in [orchestrator, aged.orchestrator()] {
        #expect(try reader.status(id) == cut)
        #expect(try reader.status(id, fullText: false) == cut)
        #expect(reader.recent(limit: 5) == [cut])
    }
}

@Test func anArchivedRunLeavesTheRootAndTheIndexWhole() throws {
    let aged = Aged()
    defer { aged.cleanUp() }
    try aged.run("cccc0001", daysAgo: 400)
    try aged.run("cccc0002", daysAgo: 200)
    try aged.run("cccc0003", daysAgo: 190)
    try aged.run("cccc0004", daysAgo: 5)
    let orchestrator = aged.orchestrator()
    let before = Dictionary(uniqueKeysWithValues: orchestrator.recent(limit: 10).map { ($0.id, $0) })

    // The newest two are the window the ranking reads, and stay.
    let result = orchestrator.sweep(dryRun: false, now: aged.now, maxSteps: .max, keep: 2)
    #expect(Set(result.archived) == ["cccc0001", "cccc0002"])
    #expect(Set(result.compacted) == ["cccc0001", "cccc0002", "cccc0003"])
    for id in ["cccc0001", "cccc0002"] {
        #expect(!aged.exists(id))
        for name in ["run.json", "summary.json"] {
            #expect(FileManager.default.fileExists(atPath: aged.archived(id).appendingPathComponent(name).path))
        }
    }
    let after = aged.orchestrator().recent(limit: 10)
    #expect(after.map(\.id) == ["cccc0004", "cccc0003"])
    #expect(after.allSatisfy { before[$0.id] == $0 })
    let index = try String(contentsOf: aged.root.appendingPathComponent(".index"), encoding: .utf8)
    #expect(!index.contains("cccc0001") && !index.contains("cccc0002"))
}

@Test func aDryRunChangesNothingAndSaysWhatTheSweepThenDoes() throws {
    let aged = Aged()
    defer { aged.cleanUp() }
    for (index, days) in [400.0, 250, 100, 45, 3].enumerated() {
        try aged.run(String(format: "dddd%04d", index), daysAgo: days, longAnswer: index == 2)
    }
    let orchestrator = aged.orchestrator()
    _ = orchestrator.recent(limit: 10)
    let before = aged.snapshot()

    let dry = orchestrator.sweep(dryRun: true, now: aged.now, maxSteps: .max, keep: 2)
    #expect(aged.snapshot() == before)
    #expect(dry.isDryRun && dry.freedBytes > 0 && dry.archivedBytes > 0)
    #expect(dry.text(archive: orchestrator.archiveRoot).hasPrefix("dry run — would compact 4 run(s)"))

    var real = orchestrator.sweep(dryRun: false, now: aged.now, maxSteps: .max, keep: 2)
    #expect(!real.isDryRun)
    real.isDryRun = true
    #expect(real == dry)
}

@Test func aSweepKilledAtAnyStepLeavesEveryRunWholeAndTheNextFinishesIt() throws {
    for stop in 0...6 {
        let aged = Aged()
        defer { aged.cleanUp() }
        for (index, days) in [400.0, 300, 200, 40, 2].enumerated() {
            try aged.run(String(format: "eeee%04d", index), daysAgo: days)
        }
        let ids = (0..<5).map { String(format: "eeee%04d", $0) }
        let orchestrator = aged.orchestrator()
        let before = Dictionary(uniqueKeysWithValues: orchestrator.recent(limit: 10).map { ($0.id, $0) })

        _ = orchestrator.sweep(dryRun: false, now: aged.now, maxSteps: stop, keep: 1)
        // Every run is in exactly one place, and reads as it did.
        for id in ids {
            let live = aged.exists(id)
            #expect(live != FileManager.default.fileExists(atPath: aged.archived(id).path), "step \(stop) \(id)")
            if live { #expect(try aged.orchestrator().status(id, fullText: false) == before[id]) }
        }
        let listed = aged.orchestrator().recent(limit: 10)
        #expect(listed.allSatisfy { before[$0.id] == $0 })

        // The next sweep ends where an uninterrupted one would have.
        _ = aged.orchestrator().sweep(dryRun: false, now: aged.now, maxSteps: .max, keep: 1)
        #expect(aged.orchestrator().recent(limit: 10).map(\.id) == ["eeee0004", "eeee0003"])
        #expect(!aged.exists("eeee0003/stdout") && aged.exists("eeee0004/stdout"))
    }
}

@Test func theDailySweepRunsOnceADay() throws {
    let aged = Aged()
    defer { aged.cleanUp() }
    try aged.run("ffff0001", daysAgo: 40)
    let orchestrator = aged.orchestrator()
    #expect(orchestrator.sweepIfDue(now: aged.now)?.compacted == ["ffff0001"])
    #expect(aged.exists(".last-sweep"))
    #expect(orchestrator.sweepIfDue(now: aged.now) == nil)
    #expect(orchestrator.sweepIfDue(now: aged.now.addingTimeInterval(day + 60)) != nil)
}
