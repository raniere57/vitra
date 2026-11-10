import Foundation

/// What a project asks for when a worktree is made for one of its editing
/// workers, read from `.vitra/worktree` at the top of the repository.
///
/// A worktree holds only what git tracks. Anything a project needs and git
/// ignores, such as a vendored library, is missing from it, and the worker
/// cannot build. Each line of the file names one such path:
///
///     link <path>    symlink it from the checkout into the worktree
///     copy <path>    copy it into the worktree
///
/// Blank lines and lines starting with `#` are ignored. A line that cannot be
/// applied is skipped and reported, never fatal: the worker still runs.
enum WorktreeSetup {
    static let fileName = ".vitra/worktree"

    struct Entry: Equatable {
        enum Kind: String {
            case link
            case copy
        }

        let kind: Kind
        /// Relative to the top of the repository, and the same in both trees.
        let path: String

        var line: String { "\(kind.rawValue) \(path)" }
    }

    struct Parsed: Equatable {
        var entries: [Entry] = []
        /// Each line that was refused, with why.
        var skipped: [String] = []
    }

    /// Pure: the text in, what it asks for out. Whether a source exists is
    /// only known to `apply`, which looks at the disk.
    static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let verb = String(line.prefix { !$0.isWhitespace })
            let path = line.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
            guard let kind = Entry.Kind(rawValue: verb) else {
                parsed.skipped.append("\(line): unknown entry")
                continue
            }
            if let refusal = refusal(for: path) {
                parsed.skipped.append("\(line): \(refusal)")
                continue
            }
            parsed.entries.append(Entry(kind: kind, path: path))
        }
        return parsed
    }

    /// Makes what `.vitra/worktree` asks for appear in `tree`, from the
    /// repository at `repository`. Returns the lines that were skipped, each
    /// with why; empty when everything applied or there is no file.
    ///
    /// A path already in the tree is left alone: the worktree is the worker's,
    /// and whatever git checked out there is what the worker was given.
    static func apply(repository: URL, to tree: URL) -> [String] {
        guard let text = try? String(contentsOf: repository.appendingPathComponent(fileName), encoding: .utf8) else {
            return []
        }
        let parsed = parse(text)
        var skipped = parsed.skipped
        let manager = FileManager.default
        for entry in parsed.entries {
            let source = repository.appendingPathComponent(entry.path)
            let target = tree.appendingPathComponent(entry.path)
            guard manager.fileExists(atPath: source.path) else {
                skipped.append("\(entry.line): missing in the checkout")
                continue
            }
            // Checked with attributes, not `fileExists`, which is false for a
            // symlink that points nowhere: that is still something in the way.
            guard (try? manager.attributesOfItem(atPath: target.path)) == nil else {
                skipped.append("\(entry.line): already in the worktree")
                continue
            }
            do {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch entry.kind {
                case .link: try manager.createSymbolicLink(at: target, withDestinationURL: source)
                // copyItem clones on APFS where it can, so a large tree is cheap.
                case .copy: try manager.copyItem(at: source, to: target)
                }
            } catch {
                skipped.append("\(entry.line): \(error.localizedDescription)")
            }
        }
        return skipped
    }

    /// Why a path cannot be used, or nil when it can. The path is what
    /// follows the verb, so an empty one is a line with nothing to act on.
    private static func refusal(for path: String) -> String? {
        if path.isEmpty { return "no path" }
        if path.hasPrefix("/") || path.hasPrefix("~") { return "path must be relative" }
        if path.split(separator: "/").contains("..") { return "path must not contain .." }
        return nil
    }
}
