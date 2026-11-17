import Foundation

/// Where a review comment points: a file, a side of the change and a line
/// number on that side, with the line's text so the worker sees what was
/// meant even if numbers have moved.
struct ReviewAnchor: Equatable, Sendable {
    enum Side: String, Sendable {
        case old
        case new
    }

    let path: String
    let side: Side
    let line: Int
    let code: String

    /// A removed line exists only in the old file, so it is pointed at there;
    /// every other line by its number in the new file, which is what the
    /// worker has in front of it.
    init?(path: String, line: DiffLine) {
        switch line.kind {
        case .removed:
            guard let old = line.old else { return nil }
            self.init(path: path, side: .old, line: old, code: line.text)
        case .added, .context:
            guard let new = line.new else { return nil }
            self.init(path: path, side: .new, line: new, code: line.text)
        }
    }

    init(path: String, side: Side, line: Int, code: String) {
        self.path = path
        self.side = side
        self.line = line
        self.code = code
    }

    /// Two anchors are the same place when file, side and number agree.
    func isSamePlace(as other: ReviewAnchor) -> Bool {
        path == other.path && side == other.side && line == other.line
    }
}

struct ReviewComment: Equatable, Sendable, Identifiable {
    let id: UUID
    let anchor: ReviewAnchor
    let text: String
    /// Where the line sits in the diff, top to bottom: the order the comments
    /// are read in, whatever order they were written in.
    let order: Int
}

/// The comments of a review, per run, for as long as the app runs.
///
/// Kept by the project, not by the review view: the view is made afresh each
/// time a diff is opened, and a half-written review must survive a look at
/// another tab. Each change replaces a run's list instead of editing it.
final class ReviewCommentBook {
    private var byRun: [String: [ReviewComment]] = [:]

    func comments(for run: String) -> [ReviewComment] {
        byRun[run] ?? []
    }

    @discardableResult
    func add(_ text: String, at anchor: ReviewAnchor, order: Int, run: String) -> ReviewComment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let comment = ReviewComment(id: UUID(), anchor: anchor, text: trimmed, order: order)
        byRun[run] = (comments(for: run) + [comment]).sorted { $0.order < $1.order }
        return comment
    }

    /// Rewrites a comment; emptied, it is removed.
    func edit(_ id: UUID, text: String, run: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(id, run: run) }
        byRun[run] = comments(for: run).map { comment in
            comment.id == id ? ReviewComment(id: id, anchor: comment.anchor, text: trimmed, order: comment.order) : comment
        }
    }

    func remove(_ id: UUID, run: String) {
        byRun[run] = comments(for: run).filter { $0.id != id }
    }

    func clear(run: String) {
        byRun[run] = nil
    }
}

/// The comments as the worker reads them, in its redo notes.
enum ReviewNotes {
    static let preamble = "Review comments on your delivery; fix exactly these:"

    static func format(_ comments: [ReviewComment]) -> String {
        let blocks = comments.sorted { $0.order < $1.order }.map { comment in
            let anchor = comment.anchor
            let path = anchor.path.replacingOccurrences(of: "\"", with: "&quot;")
            return """
            <comment file="\(path)" line="\(anchor.line)" side="\(anchor.side.rawValue)">
            <code>\(anchor.code)</code>
            \(comment.text)
            </comment>
            """
        }
        return ([preamble, "<review_comments>"] + blocks + ["</review_comments>"]).joined(separator: "\n")
    }

    /// "1 comentário", "3 comentários".
    static func count(_ count: Int) -> String {
        count == 1 ? "1 comentário" : "\(count) comentários"
    }
}
