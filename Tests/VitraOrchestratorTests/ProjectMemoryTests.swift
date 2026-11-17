import Foundation
import Testing
@testable import VitraOrchestrator

/// A memory root in a scratch directory, removed with the test.
private struct Scratch {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-memory-\(UUID().uuidString)")
    }

    var memory: ProjectMemory { ProjectMemory(root: root) }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// Noon UTC on 2026-11-10: the same calendar day in every zone from UTC-11 to UTC+12.
private let noon: Date = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
}()

@Test func aNoteAddedIsReadBack() throws {
    let scratch = Scratch()
    defer { scratch.cleanUp() }

    try scratch.memory.add("Build with bun test", author: "maestro", project: "/work/app", now: noon)
    try scratch.memory.add("The sidebar lives in Shell/Sidebar.swift", author: "abc12345", project: "/work/app", now: noon)

    let lines = scratch.memory.read(project: "/work/app").split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines.first == "- 2026-11-10 [maestro] Build with bun test")
    #expect(lines.last == "- 2026-11-10 [abc12345] The sidebar lives in Shell/Sidebar.swift")
}

@Test func aProjectWithNoNotesReadsAsEmpty() {
    let scratch = Scratch()
    defer { scratch.cleanUp() }

    #expect(scratch.memory.read(project: "/work/none") == "")
}

@Test func theNoteIsTrimmedBeforeItIsWritten() throws {
    let scratch = Scratch()
    defer { scratch.cleanUp() }

    try scratch.memory.add("  run the linter first \n", author: "maestro", project: "/work/app", now: noon)

    #expect(scratch.memory.read(project: "/work/app") == "- 2026-11-10 [maestro] run the linter first")
}

@Test func aNoteThatIsEmptyOrHasTwoLinesOrIsTooLongIsRefused() throws {
    let scratch = Scratch()
    defer { scratch.cleanUp() }
    let memory = scratch.memory

    #expect(throws: ProjectMemoryError.empty) {
        try memory.add("   \n ", author: "maestro", project: "/work/app", now: noon)
    }
    #expect(throws: ProjectMemoryError.multiline) {
        try memory.add("first line\nsecond line", author: "maestro", project: "/work/app", now: noon)
    }
    #expect(throws: ProjectMemoryError.tooLong(301)) {
        try memory.add(String(repeating: "x", count: 301), author: "maestro", project: "/work/app", now: noon)
    }
    // Nothing was written by any of them.
    #expect(memory.read(project: "/work/app") == "")
}

@Test func aNoteOfExactlyTheLimitIsAccepted() throws {
    let scratch = Scratch()
    defer { scratch.cleanUp() }
    let note = String(repeating: "x", count: 300)

    try scratch.memory.add(note, author: "maestro", project: "/work/app", now: noon)

    #expect(scratch.memory.read(project: "/work/app").hasSuffix(note))
}

@Test func onlyTheLast200NotesAreKept() throws {
    let scratch = Scratch()
    defer { scratch.cleanUp() }

    for index in 1...205 {
        try scratch.memory.add("note \(index)", author: "maestro", project: "/work/app", now: noon)
    }

    let lines = scratch.memory.read(project: "/work/app").split(separator: "\n")
    #expect(lines.count == 200)
    #expect(lines.first?.hasSuffix("note 6") == true)
    #expect(lines.last?.hasSuffix("note 205") == true)
}

@Test func notesAddedFromManyThreadsAtOnceAreNoneLost() {
    let scratch = Scratch()
    defer { scratch.cleanUp() }
    let memory = scratch.memory
    let writers = 8
    let notesEach = 25

    DispatchQueue.concurrentPerform(iterations: writers) { writer in
        for index in 1...notesEach {
            try? memory.add("writer \(writer) note \(index)", author: "maestro", project: "/work/busy", now: noon)
        }
    }

    let lines = memory.read(project: "/work/busy").split(separator: "\n")
    #expect(lines.count == writers * notesEach)
    for writer in 0..<writers {
        for index in 1...notesEach {
            #expect(lines.contains { $0.hasSuffix("writer \(writer) note \(index)") })
        }
    }
}

@Test func anAuthorIsReducedToASafeToken() throws {
    let scratch = Scratch()
    defer { scratch.cleanUp() }

    try scratch.memory.add("note", author: "evil] injected\n- 2026-01-01 [x", project: "/work/app", now: noon)
    try scratch.memory.add("note", author: "  ", project: "/work/app", now: noon)
    try scratch.memory.add("note", author: "ok-name_1.2", project: "/work/app", now: noon)
    try scratch.memory.add("note", author: String(repeating: "a", count: 60), project: "/work/app", now: noon)

    let lines = scratch.memory.read(project: "/work/app").split(separator: "\n")
    #expect(lines.count == 4)
    #expect(lines[0] == "- 2026-11-10 [evilinjected-2026-01-01x] note")
    #expect(lines[1] == "- 2026-11-10 [agent] note")
    #expect(lines[2] == "- 2026-11-10 [ok-name_1.2] note")
    #expect(lines[3] == "- 2026-11-10 [\(String(repeating: "a", count: 40))] note")
}

@Test func eachProjectKeepsItsOwnNotes() throws {
    let scratch = Scratch()
    defer { scratch.cleanUp() }

    try scratch.memory.add("app note", author: "maestro", project: "/work/app", now: noon)
    try scratch.memory.add("site note", author: "maestro", project: "/work/site", now: noon)

    #expect(scratch.memory.read(project: "/work/app").hasSuffix("app note"))
    #expect(scratch.memory.read(project: "/work/site").hasSuffix("site note"))
    #expect(!scratch.memory.read(project: "/work/app").contains("site note"))
}
