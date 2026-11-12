import AppKit

/// A row of the reading list: an item of the transcript, or the live line
/// while the maestro works.
enum LeituraRow: Equatable {
    case item(TranscriptItem)
    case live(LiveState)

    var id: String {
        switch self {
        case let .item(item): item.id
        case .live: "live"
        }
    }
}

/// "trabalhando · <what it is doing> · 1:12".
struct LiveState: Equatable {
    var since: Date
    /// The one-liner of the call running now, when there is one.
    var current: String?
}

/// What every row view reads besides its own row: the caches that make
/// heights cheap, which rows the user opened, the find's matches, and where
/// clicks go. One per Leitura, owned by its list.
@MainActor
final class LeituraContext {
    // MARK: Where clicks go

    var openLink: ((URL) -> Void)?
    var openWorker: ((String) -> Void)?
    var openImage: ((ImageRef) -> Void)?
    /// "enviar agora" on a prompt waiting in Claude Code's queue.
    var sendQueuedNow: (() -> Void)?
    /// A row changed its own height (opened, closed): the list re-measures it.
    var rowChanged: ((String) -> Void)?

    /// The clock the live row reads; fixed by the snapshot tool.
    var now: () -> Date = Date.init

    // MARK: State the user set

    private(set) var openActivities: Set<String> = []
    private(set) var openCalls: Set<String> = []
    private(set) var fullOutputs: Set<String> = []

    // The set is changed first and the list told after: telling it from
    // inside the change makes the table ask for the row's height, which reads
    // the very set being written — an overlapping access, and Swift aborts.
    func toggleActivity(_ id: String) {
        Self.flip(id, in: &openActivities)
        rowChanged?(id)
    }

    func toggleCall(_ id: String, in row: String) {
        Self.flip(id, in: &openCalls)
        rowChanged?(row)
    }
    func showFullOutput(_ id: String, in row: String) {
        fullOutputs.insert(id)
        rowChanged?(row)
    }

    func isOpen(activity id: String) -> Bool { openActivities.contains(id) }
    func isOpen(call id: String) -> Bool { openCalls.contains(id) }
    func showsFull(call id: String) -> Bool { fullOutputs.contains(id) }

    private static func flip(_ id: String, in set: inout Set<String>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    /// For the snapshot tool: rows shown opened.
    func open(activity: String? = nil, call: String? = nil) {
        if let activity {
            openActivities.insert(activity)
            rowChanged?(activity)
        }
        if let call, let activity {
            openCalls.insert(call)
            rowChanged?(activity)
        }
    }

    // MARK: Find

    var query = ""
    /// The match stepped to: the row's id and which of its matches.
    var currentMatch: (row: String, index: Int)?

    func currentIndex(in row: String) -> Int? {
        currentMatch?.row == row ? currentMatch?.index : nil
    }

    // MARK: Files

    /// The project, against which relative paths in answers are resolved.
    var base: URL?

    /// The file an inline code span names, when it is one that exists.
    func resolveFile(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 2, trimmed.count < 400, !trimmed.contains(" "),
              trimmed.contains("/") || trimmed.range(of: #"\.[A-Za-z]{1,6}(:\d+)?$"#, options: .regularExpression) != nil
        else { return nil }
        let path = trimmed.replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "", options: .regularExpression)
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base?.appendingPathComponent(expanded)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: Caches

    private var documents: [String: (markdown: String, segments: [Segment])] = [:]
    private var heights: [String: (signature: Int, width: CGFloat, height: CGFloat)] = [:]
    /// Beyond this many rows remembered, the caches start again: a long
    /// session read for hours must not hold every row it ever measured.
    private static let cacheLimit = 1500

    /// A segment of an answer, made once: the attributed text or the code.
    enum Segment {
        case text(NSAttributedString, plain: String)
        case code(language: String?, text: String)
    }

    func segments(for answer: Answer) -> [Segment] {
        if let cached = documents[answer.id], cached.markdown == answer.markdown { return cached.segments }
        if documents.count > Self.cacheLimit { documents = [:] }
        let segments = ReadingDocument.make(markdown: answer.markdown).segments.map { segment -> Segment in
            switch segment {
            case let .text(styled): .text(ReadingRenderer.attributed(styled, resolveFile: { [weak self] in self?.resolveFile($0) }), plain: styled.string)
            case let .code(language, text): .code(language: language, text: text)
            }
        }
        documents[answer.id] = (answer.markdown, segments)
        return segments
    }

    /// The row's height at `width`, measured once per look of the row.
    func height(of row: LeituraRow, width: CGFloat, signature: Int, measure: () -> CGFloat) -> CGFloat {
        if let cached = heights[row.id], cached.signature == signature, cached.width == width { return cached.height }
        if heights.count > Self.cacheLimit { heights = [:] }
        let height = measure()
        heights[row.id] = (signature, width, height)
        return height
    }

    /// Everything that changes a row's height, hashed.
    func signature(of row: LeituraRow) -> Int {
        var hasher = Hasher()
        switch row {
        // What the height depends on — not the image bytes, which are
        // megabytes to hash and change nothing about the row's height.
        case let .item(.user(message)):
            hasher.combine(message.text)
            hasher.combine(message.images.count)
        case let .item(.answer(answer)):
            hasher.combine(answer.markdown)
        case let .item(.activity(activity)):
            hasher.combine(isOpen(activity: activity.id))
            hasher.combine(activity.steps.count)
            hasher.combine(activity.failures)
            for call in activity.calls {
                hasher.combine(call.status == .running)
                hasher.combine(isOpen(call: call.id))
                if isOpen(call: call.id) {
                    hasher.combine(showsFull(call: call.id))
                    hasher.combine(call.output)
                }
            }
        case let .item(item):
            hasher.combine(item.id)
            hasher.combine(String(describing: item))
        case .live:
            hasher.combine("live")
        }
        return hasher.finalize()
    }
}
