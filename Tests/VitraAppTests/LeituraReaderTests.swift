import Foundation
import Testing
@testable import VitraApp

/// The reader against real files in a temp folder: the tail of a big one,
/// appends that end mid-line, truncation, a session switch.
@MainActor
struct LeituraReaderTests {
    final class Collector {
        var updates: [TranscriptReader.Update] = []
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-leitura-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func reader(_ url: URL, _ collector: Collector, items: Int = 80) -> TranscriptReader {
        TranscriptReader(url: url, itemsPerRead: items) { collector.updates.append($0) }
    }

    /// Waits until `count` updates arrived, or fails after a few seconds.
    private func waitFor(_ count: Int, _ collector: Collector) async throws -> TranscriptReader.Update {
        for _ in 0 ..< 500 where collector.updates.count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(collector.updates.count >= count ? collector.updates.last : nil, "no update \(count)")
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func readsAppendsAndHoldsBackAPartialLine() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        let first = JSONL.user("olá", "u1", at: 0) + "\n"
        let answer = JSONL.text("Oi! Tudo certo.", "a1", at: 2)
        // The answer is cut mid-line: it must not show until its newline.
        try (first + answer.prefix(20)).write(to: file, atomically: true, encoding: .utf8)
        let collector = Collector()
        let reader = reader(file, collector)
        reader.open()
        var update = try await waitFor(1, collector)
        #expect(update.items.count == 1)
        #expect(!update.hasOlder)

        try append(String(answer.dropFirst(20)) + "\n", to: file)
        reader.refresh()
        update = try await waitFor(2, collector)
        #expect(update.items.count == 2)
        guard case let .answer(text) = update.items.last else { Issue.record("no answer"); return }
        #expect(text.markdown == "Oi! Tudo certo.")
    }

    @Test func aTruncatedFileIsReadAgain() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        try (JSONL.conversation.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let collector = Collector()
        let reader = reader(file, collector)
        reader.open()
        #expect(try await waitFor(1, collector).items.count == 4)
        try (JSONL.user("recomeço", "x1", at: 0) + "\n").write(to: file, atomically: false, encoding: .utf8)
        reader.refresh()
        let update = try await waitFor(2, collector)
        #expect(update.items.count == 1)
    }

    @Test func aMissingFileSaysSo() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let collector = Collector()
        let reader = reader(dir.appendingPathComponent("none.jsonl"), collector)
        reader.open()
        let update = try await waitFor(1, collector)
        #expect(update.isMissing && update.items.isEmpty)
    }

    /// 50 MB of transcript: the tail is read in well under a second, and only
    /// a sliver of the file is read or parsed. Older stretches come on demand.
    @Test func readsOnlyTheTailOfABigFile() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        let filler = String(repeating: "saída de teste ", count: 1500)
        var turn = 0
        var written = 0
        while written < 50 * 1024 * 1024 {
            let at = TimeInterval(turn * 10)
            let lines = [
                JSONL.user("pergunta \(turn)", "u\(turn)", at: at),
                JSONL.tool("t\(turn)", "Bash", ["command": "ls", "description": "Listar"], "a\(turn)", at: at + 1),
                JSONL.result("t\(turn)", filler, "r\(turn)", at: at + 2),
                JSONL.text("resposta \(turn)", "b\(turn)", at: at + 3),
            ].joined(separator: "\n") + "\n"
            let data = Data(lines.utf8)
            try handle.write(contentsOf: data)
            written += data.count
            turn += 1
        }
        try handle.close()

        let collector = Collector()
        let reader = reader(file, collector)
        let clock = ContinuousClock()
        let started = clock.now
        reader.open()
        let update = try await waitFor(1, collector)
        let elapsed = clock.now - started
        let stats = reader.currentStats()
        #expect(elapsed < .seconds(1), "tail took \(elapsed)")
        #expect(update.items.count >= 80 && update.items.count < 200)
        #expect(update.hasOlder)
        #expect(stats.bytesRead < 4 * 1024 * 1024, "read \(stats.bytesRead) bytes")
        #expect(stats.linesParsed < 400, "parsed \(stats.linesParsed) lines")
        guard case let .answer(last) = update.items.last else { Issue.record("no answer at the end"); return }
        #expect(last.markdown == "resposta \(turn - 1)")

        reader.loadOlder()
        let older = try await waitFor(2, collector)
        #expect(older.items.count >= update.items.count + 80)
        #expect(Array(older.items.suffix(update.items.count)) == update.items)
    }

    /// A new session is a new file and a new reader: nothing of the old one stays.
    @Test func aSessionSwitchReadsTheOtherFile() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = "/Users/x/Dev/vitra.app"
        let slug = TranscriptLocator.slug(for: project)
        #expect(slug == "-Users-x-Dev-vitra-app")
        let one = TranscriptLocator.url(project: project, session: "one", root: dir)
        let two = TranscriptLocator.url(project: project, session: "two", root: dir)
        try FileManager.default.createDirectory(at: one.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (JSONL.user("na primeira", "u1", at: 0) + "\n").write(to: one, atomically: true, encoding: .utf8)
        try (JSONL.user("na segunda", "u2", at: 0) + "\n").write(to: two, atomically: true, encoding: .utf8)
        let collector = Collector()
        reader(two, collector).open()
        let update = try await waitFor(1, collector)
        guard case let .user(message) = update.items.first else { Issue.record("no message"); return }
        #expect(message.text == "na segunda")
    }
}
