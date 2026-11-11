import Foundation
import os

/// Reads one transcript file for Leitura: its tail first, older stretches on
/// demand, and the bytes the maestro appends while it is being watched.
///
/// A transcript is append-only and can pass 100 MB, most of it tool output
/// nobody will scroll back to. So nothing reads it from the start: the tail
/// is found by seeking from the end to line starts, older stretches are read
/// backwards a block at a time, and appends are read from the last offset
/// with a partial last line held back until its newline arrives.
///
/// Every piece of state is confined to `queue`; that is what makes the class
/// safe to share (`@unchecked Sendable`). Results go to `onUpdate`, called on
/// the main queue.
final class TranscriptReader: @unchecked Sendable {
    struct Update: Sendable, Equatable {
        var items: [TranscriptItem]
        /// There is more of the conversation before the first item.
        var hasOlder: Bool
        /// The file is not there (yet): the session never wrote it.
        var isMissing: Bool
    }

    /// Counts for the tests and the reality check: what was really read.
    struct Stats: Sendable, Equatable {
        var bytesRead = 0
        var linesParsed = 0
    }

    let url: URL
    /// How many display items each read aims for.
    let itemsPerRead: Int
    private let blockSize: Int
    private let queue = DispatchQueue(label: "dev.vitra.leitura.reader", qos: .userInitiated)
    private let onUpdate: @MainActor @Sendable (Update) -> Void
    private static let log = Logger(subsystem: "dev.vitra", category: "leitura")

    // Confined to `queue`.
    private var chunk = TranscriptChunk()
    /// Where the read part begins and where complete lines end.
    private var start: UInt64 = 0
    private var end: UInt64 = 0
    private var hasLoaded = false
    private var watch: DispatchSourceFileSystemObject?
    private var stats = Stats()

    init(url: URL, itemsPerRead: Int = 80, blockSize: Int = 256 * 1024, onUpdate: @escaping @MainActor @Sendable (Update) -> Void) {
        self.url = url
        self.itemsPerRead = itemsPerRead
        self.blockSize = blockSize
        self.onUpdate = onUpdate
    }

    deinit { watch?.cancel() }

    /// Reads the tail, once; later calls only publish what is held.
    func open() {
        queue.async { [self] in
            // Again when the file was missing: a new session writes it late.
            if !hasLoaded || end == 0 { loadTail() }
            publish()
        }
    }

    /// One more stretch before what is shown.
    func loadOlder() {
        queue.async { [self] in
            guard start > 0 else { return }
            readBackward(target: chunk.items.count + itemsPerRead)
            publish()
        }
    }

    /// Follows appends while `following`; a hidden Leitura watches nothing.
    func follow(_ following: Bool) {
        queue.async { [self] in
            if following { startWatching() } else { stopWatching() }
        }
    }

    /// Reads whatever was appended since the last read, now.
    func refresh() {
        queue.async { [self] in readAppended() }
    }

    /// Waits for every queued read, then reports what was read: for tests.
    func currentStats() -> Stats { queue.sync { stats } }

    // MARK: - Reading

    private func loadTail() {
        hasLoaded = true
        chunk = TranscriptChunk()
        guard let size = fileSize() else {
            (start, end) = (0, 0)
            return
        }
        // The last line may still be being written: complete lines end at the
        // last newline, and what follows waits for its own.
        end = lastLineEnd(before: size)
        start = end
        readBackward(target: itemsPerRead)
    }

    private func readBackward(target: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var block = UInt64(blockSize)
        while start > 0, chunk.items.count < target {
            let from = start > block ? start - block : 0
            guard let data = read(handle, from: from, to: start) else { return }
            var lineStart = from
            var body = data[...]
            if from > 0 {
                // The block begins mid-line: that line is the next block's.
                // A block holding no line start but `start`'s own (one line
                // longer than the block: a pasted image, a big tool output)
                // is read again twice as long.
                guard let newline = Self.newline(in: data[...], from: data.startIndex),
                      newline < data.endIndex - 1 else {
                    block *= 2
                    continue
                }
                lineStart = from + UInt64(newline - data.startIndex) + 1
                body = data[(newline + 1)...]
            }
            let older = TranscriptChunk(events: parse(body))
            chunk = older.joined(chunk)
            start = lineStart
            block = UInt64(blockSize)
        }
    }

    private func readAppended() {
        guard hasLoaded else { return }
        guard let size = fileSize() else { return }
        if size < end {
            // Truncated or replaced: what was read no longer describes it.
            Self.log.info("transcript shrank; reading it again")
            loadTail()
            publish()
            return
        }
        let complete = lastLineEnd(before: size, after: end)
        guard complete > end, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let data = read(handle, from: end, to: complete) else { return }
        end = complete
        chunk = chunk.joined(TranscriptChunk(events: parse(data[...])))
        publish()
    }

    private func parse(_ data: Data.SubSequence) -> [TranscriptLine.Event] {
        var events: [TranscriptLine.Event] = []
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = Self.newline(in: data, from: lineStart) ?? data.endIndex
            if lineEnd > lineStart {
                stats.linesParsed += 1
                events += TranscriptLine.events(from: Data(data[lineStart ..< lineEnd]))
            }
            lineStart = lineEnd + 1
        }
        return events
    }

    private func read(_ handle: FileHandle, from: UInt64, to: UInt64) -> Data? {
        guard to > from else { return Data() }
        do {
            try handle.seek(toOffset: from)
            let data = try handle.read(upToCount: Int(to - from)) ?? Data()
            stats.bytesRead += data.count
            return data
        } catch {
            Self.log.error("could not read the transcript: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func fileSize() -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    /// The offset just past the last newline before `size`, looking back no
    /// further than `floor`; `floor` when there is none.
    private func lastLineEnd(before size: UInt64, after floor: UInt64 = 0) -> UInt64 {
        guard size > floor, let handle = try? FileHandle(forReadingFrom: url) else { return floor }
        defer { try? handle.close() }
        var probeEnd = size
        while probeEnd > floor {
            let from = max(floor, probeEnd > UInt64(blockSize) ? probeEnd - UInt64(blockSize) : 0)
            guard let data = read(handle, from: from, to: probeEnd) else { return floor }
            if let newline = Self.lastNewline(in: data) {
                return from + UInt64(newline - data.startIndex) + 1
            }
            probeEnd = from
        }
        return floor
    }

    private func publish() {
        let update = Update(items: chunk.items, hasOlder: start > 0, isMissing: fileSize() == nil)
        let onUpdate = onUpdate
        DispatchQueue.main.async { MainActor.assumeIsolated { onUpdate(update) } }
    }

    // MARK: - Following

    private func startWatching() {
        guard watch == nil else { return }
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                // The file was replaced: watch the new one, read it afresh.
                self.stopWatching()
                self.loadTail()
                self.publish()
                self.startWatching()
                return
            }
            self.readAppended()
        }
        source.setCancelHandler { close(descriptor) }
        watch = source
        source.resume()
        // Whatever arrived while nobody watched.
        readAppended()
    }

    private func stopWatching() {
        watch?.cancel()
        watch = nil
    }
}

extension TranscriptReader {
    /// The first newline at or after `start`: memchr, not a generic
    /// `firstIndex`, which walks a 74 MB file a byte at a time through Data's
    /// subscript.
    static func newline(in data: Data.SubSequence, from start: Data.Index) -> Data.Index? {
        guard start < data.endIndex else { return nil }
        return data.withUnsafeBytes { buffer -> Data.Index? in
            guard let base = buffer.baseAddress else { return nil }
            let offset = start - data.startIndex
            guard let found = memchr(base + offset, 0x0A, buffer.count - offset) else { return nil }
            return data.startIndex + (UnsafeRawPointer(found) - base)
        }
    }

    static func lastNewline(in data: Data) -> Data.Index? {
        data.withUnsafeBytes { buffer -> Data.Index? in
            guard let bytes = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var index = buffer.count - 1
            while index >= 0, bytes[index] != 0x0A { index -= 1 }
            return index >= 0 ? data.startIndex + index : nil
        }
    }
}
