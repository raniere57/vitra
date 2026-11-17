import Foundation

/// Which line of a parsed diff: file, hunk and line, by index.
struct DiffLineRef: Hashable, Sendable {
    let file: Int
    let hunk: Int
    let line: Int
}

/// One row of the review's table. The table holds thousands of these and
/// only a screenful of views, so a row is a value that says what to draw.
enum DiffRow: Equatable {
    /// The diff was cut: how many of its lines are shown, of how many.
    case truncated(shown: Int, total: Int)
    /// A file's sticky header.
    case file(Int)
    /// A file with nothing to show line by line: binary, or renamed as it was.
    case bare(file: Int)
    case hunk(file: Int, hunk: Int)
    /// `ordinal` is the line's place in the whole diff, top to bottom.
    case line(DiffLineRef, ordinal: Int)
    case comment(ReviewComment)
    /// The field under a line; `comment` is the one being rewritten, if any.
    case editor(DiffLineRef, ordinal: Int, comment: ReviewComment?)

    var lineRef: DiffLineRef? {
        switch self {
        case let .line(ref, _), let .editor(ref, _, _): ref
        default: nil
        }
    }
}

/// What is being written, and under which line.
struct DiffEditing: Equatable {
    let line: DiffLineRef
    /// The comment being rewritten; nil for a new one.
    let comment: UUID?
}

/// Lays a parsed diff out as rows, with each comment under its line.
enum DiffRows {
    /// Past this many lines a diff is cut: the table would cope, but nobody
    /// reviews a change that size line by line.
    static let lineLimit = 20_000

    static func build(
        _ files: [DiffFile],
        comments: [ReviewComment] = [],
        editing: DiffEditing? = nil,
        limit: Int = lineLimit
    ) -> [DiffRow] {
        let total = files.reduce(0) { $0 + $1.hunks.reduce(0) { $0 + $1.lines.count } }
        var rows: [DiffRow] = total > limit ? [.truncated(shown: limit, total: total)] : []
        var ordinal = 0
        for (fileIndex, file) in files.enumerated() {
            guard ordinal < limit else { break }
            rows.append(.file(fileIndex))
            if file.hunks.isEmpty { rows.append(.bare(file: fileIndex)) }
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                guard ordinal < limit else { break }
                rows.append(.hunk(file: fileIndex, hunk: hunkIndex))
                for (lineIndex, line) in hunk.lines.enumerated() {
                    guard ordinal < limit else { break }
                    let ref = DiffLineRef(file: fileIndex, hunk: hunkIndex, line: lineIndex)
                    rows.append(.line(ref, ordinal: ordinal))
                    // Only looked for when there are comments: a long diff has none.
                    let here = comments.isEmpty ? nil : ReviewAnchor(path: file.path, line: line)
                    for comment in comments where here.map(comment.anchor.isSamePlace) == true {
                        let rewriting = editing?.comment == comment.id
                        rows.append(rewriting ? .editor(ref, ordinal: ordinal, comment: comment) : .comment(comment))
                    }
                    if let editing, editing.line == ref, editing.comment == nil {
                        rows.append(.editor(ref, ordinal: ordinal, comment: nil))
                    }
                    ordinal += 1
                }
            }
        }
        return rows
    }

    /// Lines added and removed, and files touched.
    static func totals(_ files: [DiffFile]) -> (added: Int, removed: Int, files: Int) {
        (files.reduce(0) { $0 + $1.added }, files.reduce(0) { $0 + $1.removed }, files.count)
    }

    /// "+12 −3 · 2 arquivos".
    static func summary(added: Int, removed: Int, files: Int) -> String {
        "+\(added) −\(removed) · \(files) \(files == 1 ? "arquivo" : "arquivos")"
    }
}
