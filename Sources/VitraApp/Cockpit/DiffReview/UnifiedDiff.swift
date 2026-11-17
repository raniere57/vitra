import Foundation

/// One line of a hunk, with where it sits on each side of the change.
struct DiffLine: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case context
        case added
        case removed
    }

    let kind: Kind
    /// The line's text, without the leading `+`, `-` or space.
    let text: String
    /// Its number in the old file; nil for an added line.
    let old: Int?
    /// Its number in the new file; nil for a removed line.
    let new: Int?
    /// Followed in the diff by "\ No newline at end of file": the file ends
    /// here without one, on this line's side.
    var missingNewline = false
}

/// A `@@` block: where it starts on each side, the function git names after
/// it, and its lines.
struct DiffHunk: Equatable, Sendable {
    /// The whole `@@ -a,b +c,d @@ context` line, shown as the hunk's separator.
    let header: String
    var lines: [DiffLine] = []
}

/// One file of a diff.
struct DiffFile: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case modified
        case added
        case deleted
        case renamed(from: String)
    }

    /// The path on the new side, or the old one for a deleted file: where a
    /// comment about it points.
    var path: String
    var status: Status = .modified
    var isBinary = false
    var hunks: [DiffHunk] = []

    var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
}

/// Reads the output of `git diff --no-color` into files, hunks and numbered
/// lines. Pure, so every shape git prints is pinned by a test rather than
/// found out in front of a delivery.
enum UnifiedDiff {
    static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        // The file being read; `reading` says whether there is one yet. Not
        // an optional: a line appended through one would copy every line so far.
        var file = DiffFile(path: "")
        var reading = false
        // Lines still owed by the hunk being read, per side. A hunk is read by
        // count, not by the look of its lines: a removed "-- x" prints as
        // "--- x", which would otherwise pass for the next file's header.
        var owed = (old: 0, new: 0)
        var next = (old: 0, new: 0)

        func finish() {
            if reading { files.append(file) }
            reading = false
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if owed.old > 0 || owed.new > 0, reading, !file.hunks.isEmpty {
                if let parsed = contentLine(line, at: next) {
                    let last = file.hunks.count - 1
                    file.hunks[last].lines.append(parsed)
                    if parsed.kind != .added { owed.old -= 1; next.old += 1 }
                    if parsed.kind != .removed { owed.new -= 1; next.new += 1 }
                    continue
                }
            }
            if line.hasPrefix("\\") {
                // "\ No newline at end of file", for the line just read.
                if reading, let hunk = file.hunks.indices.last, let last = file.hunks[hunk].lines.indices.last {
                    file.hunks[hunk].lines[last].missingNewline = true
                }
                continue
            }
            if line.hasPrefix("diff --git ") {
                finish()
                owed = (0, 0)
                file = DiffFile(path: gitHeaderPath(line))
                reading = true
                continue
            }
            guard reading else { continue }
            if line.hasPrefix("@@"), let start = hunkStart(line) {
                file.hunks.append(DiffHunk(header: line))
                owed = (start.oldCount, start.newCount)
                next = (start.old, start.new)
            } else if line.hasPrefix("new file mode") {
                file.status = .added
            } else if line.hasPrefix("deleted file mode") {
                file.status = .deleted
            } else if line.hasPrefix("rename from ") {
                file.status = .renamed(from: unquote(String(line.dropFirst("rename from ".count))))
            } else if line.hasPrefix("rename to ") {
                file.path = unquote(String(line.dropFirst("rename to ".count)))
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                file.isBinary = true
            } else if line.hasPrefix("+++ "), let path = sidePath(line), file.status != .deleted {
                file.path = path
            } else if line.hasPrefix("--- "), let path = sidePath(line), file.status == .deleted {
                file.path = path
            }
        }
        finish()
        return files
    }

    private static func contentLine(_ line: String, at next: (old: Int, new: Int)) -> DiffLine? {
        guard let marker = line.first else {
            // An empty context line whose space an editor trimmed away.
            return DiffLine(kind: .context, text: "", old: next.old, new: next.new)
        }
        let text = String(line.dropFirst())
        switch marker {
        case " ": return DiffLine(kind: .context, text: text, old: next.old, new: next.new)
        case "+": return DiffLine(kind: .added, text: text, old: nil, new: next.new)
        case "-": return DiffLine(kind: .removed, text: text, old: next.old, new: nil)
        default: return nil
        }
    }

    /// `@@ -12,7 +12,9 @@ func x()` → where each side starts and how long
    /// it runs. A count left out is 1, as git writes a one-line side.
    static func hunkStart(_ line: String) -> (old: Int, oldCount: Int, new: Int, newCount: Int)? {
        let fields = line.split(separator: " ")
        guard fields.count >= 3, fields[1].hasPrefix("-"), fields[2].hasPrefix("+") else { return nil }
        func range(_ field: Substring) -> (Int, Int)? {
            let parts = field.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
            return (start, parts.count > 1 ? Int(parts[1]) ?? 1 : 1)
        }
        guard let old = range(fields[1]), let new = range(fields[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    /// The path out of a `--- a/x` or `+++ b/x` line; nil for /dev/null.
    private static func sidePath(_ line: String) -> String? {
        let path = unquote(String(line.dropFirst(4)))
        guard path != "/dev/null" else { return nil }
        return path.hasPrefix("a/") || path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
    }

    /// The path from `diff --git a/x b/x`, for a file that has no `---`/`+++`
    /// lines (binary, or a pure rename). Both halves are the same path then,
    /// so the line is cut in the middle rather than at a " b/" that a path
    /// with spaces could also contain.
    private static func gitHeaderPath(_ line: String) -> String {
        let rest = String(line.dropFirst("diff --git ".count))
        let half = rest.count / 2
        let second = unquote(String(rest.suffix(rest.count - half)).trimmingCharacters(in: .whitespaces))
        return second.hasPrefix("b/") ? String(second.dropFirst(2)) : second
    }

    /// git quotes a path with unusual characters; the quotes are dropped.
    /// ponytail: octal escapes inside them are left as git wrote them.
    private static func unquote(_ path: String) -> String {
        path.count >= 2 && path.hasPrefix("\"") && path.hasSuffix("\"") ? String(path.dropFirst().dropLast()) : path
    }
}
