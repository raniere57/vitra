import Darwin
import Foundation

/// `VITRA_LEITURA_CHECK=1 Vitra leitura-check <file.jsonl>…`: the reader run
/// over real transcripts, read-only, printing only numbers — time, memory,
/// items by kind, entry kinds skipped — never their content. A developer's
/// check that the parser holds on what Claude Code really writes.
@MainActor
enum LeituraCheck {
    static func run(_ paths: [String]) {
        for path in paths { check(URL(fileURLWithPath: path)) }
    }

    private static func check(_ url: URL) {
        var updates: [TranscriptReader.Update] = []
        let before = residentMB()
        let reader = TranscriptReader(url: url) { updates.append($0) }
        let started = Date()
        reader.open()
        wait { !updates.isEmpty }
        let tail = Date().timeIntervalSince(started)
        let stats = reader.currentStats()
        print(String(format: "%@ · %.1f MB", url.lastPathComponent, Double(size(url)) / 1_048_576))
        print(String(format: "  tail: %.0f ms · read %.1f MB · %d lines parsed · resident +%d MB · %@",
                     tail * 1000, Double(stats.bytesRead) / 1_048_576, stats.linesParsed, residentMB() - before, counts(updates[0].items)))

        let wholeStart = Date()
        while let last = updates.last, last.hasOlder {
            let seen = updates.count
            reader.loadOlder()
            wait { updates.count > seen }
        }
        let items = updates.last?.items ?? []
        let calls = items.flatMap { item -> [ToolCall] in if case let .activity(activity) = item { activity.calls } else { [] } }
        print(String(format: "  whole: %.0f ms · %@ · %d calls (%d failed, %d without result) · resident %d MB",
                     Date().timeIntervalSince(wholeStart) * 1000, counts(items), calls.count,
                     calls.filter(\.isError).count, calls.filter { $0.status == .running }.count, residentMB()))
        // Read in stretches, it must read the same as all at once — up to
        // what was appended between the two reads of a live transcript.
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            var events: [TranscriptLine.Event] = []
            var start = data.startIndex
            while let end = TranscriptReader.newline(in: data[...], from: start) {
                events += TranscriptLine.events(from: Data(data[start ..< end]))
                start = end + 1
            }
            let whole = TranscriptChunk(events: events).items
            let agrees = Array(whole.prefix(items.count).dropLast()) == Array(items.dropLast())
            let first = zip(whole, items).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            print("  stretched read agrees with a whole read: \(agrees ? "yes" : "NO") (\(items.count) vs \(whole.count) items; first difference at \(first.map(String.init) ?? "none"))")
        }
        let renderStart = Date()
        for item in items { if case let .answer(answer) = item { _ = ReadingDocument.make(markdown: answer.markdown) } }
        print(String(format: "  markdown of every answer: %.0f ms", Date().timeIntervalSince(renderStart) * 1000))
        print("  skipped entry kinds: " + skippedKinds(url))
    }

    /// Entry types and subtypes that produced no event, with their counts.
    private static func skippedKinds(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "?" }
        var skipped: [String: Int] = [:]
        var start = data.startIndex
        while start < data.endIndex {
            let end = TranscriptReader.newline(in: data[...], from: start) ?? data.endIndex
            let line = data[start ..< end]
            start = end + 1
            guard TranscriptLine.events(from: Data(line)).isEmpty else { continue }
            guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                skipped["(not JSON)", default: 0] += 1
                continue
            }
            var kind = entry["type"] as? String ?? "?"
            if let subtype = entry["subtype"] as? String { kind += "/" + subtype }
            if let attachment = (entry["attachment"] as? [String: Any])?["type"] as? String { kind += "/" + attachment }
            if entry["isSidechain"] as? Bool == true { kind = "sidechain" }
            if entry["isMeta"] as? Bool == true { kind += " (meta)" }
            skipped[kind, default: 0] += 1
        }
        return skipped.sorted { $0.value > $1.value }.prefix(14).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    private static func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(120)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    }

    private static func counts(_ items: [TranscriptItem]) -> String {
        var counts: [String: Int] = [:]
        for item in items {
            let kind = switch item {
            case .user: "user"
            case .answer: "answer"
            case .activity: "activity"
            case .divider: "divider"
            case .note: "note"
            case .worked: "worked"
            }
            counts[kind, default: 0] += 1
        }
        return "\(items.count) items (" + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")"
    }

    private static func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) / 1_048_576 : 0
    }
}
