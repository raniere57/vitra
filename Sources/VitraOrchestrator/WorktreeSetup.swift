import Darwin
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

    struct Outcome: Equatable {
        /// Paths now in the tree, relative to the top of the repository. The
        /// worker's shell leaves these out of its commits.
        var applied: [String] = []
        /// Each entry that was refused or could not be made, with why.
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
    /// repository at `repository`. Empty when there is no file.
    static func apply(repository: URL, to tree: URL) -> Outcome {
        apply(listIn: repository, sourcesIn: repository, to: tree)
    }

    /// Like `apply(repository:to:)`, but the list is read from `listRoot`, the
    /// tree the worker was given, which holds the list as of its commit. Only
    /// the sources are read from `repository`, the main working tree, where
    /// the ignored files are.
    static func apply(listIn listRoot: URL, sourcesIn repository: URL, to tree: URL) -> Outcome {
        guard let text = try? String(contentsOf: listRoot.appendingPathComponent(fileName), encoding: .utf8) else {
            return Outcome()
        }
        let parsed = parse(text)
        var outcome = apply(parsed.entries, repository: repository, to: tree)
        outcome.skipped.insert(contentsOf: parsed.skipped, at: 0)
        return outcome
    }

    /// Applies entries directly. Each one is checked again here, so a caller
    /// that did not come through `parse` gets the same refusals.
    ///
    /// A path already in the tree is left alone: the worktree is the worker's,
    /// and whatever git checked out there is what the worker was given.
    static func apply(_ entries: [Entry], repository: URL, to tree: URL) -> Outcome {
        var outcome = Outcome()
        for entry in entries {
            if let problem = problem(with: entry, repository: repository, tree: tree) {
                outcome.skipped.append("\(entry.line): \(problem)")
                continue
            }
            let source = repository.appendingPathComponent(entry.path)
            let target = tree.appendingPathComponent(entry.path)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch entry.kind {
                case .link: try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
                case .copy: try cloneOrCopy(source.resolvingSymlinksInPath().path, to: target.path)
                }
                outcome.applied.append(entry.path)
            } catch {
                outcome.skipped.append("\(entry.line): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// Why a path cannot be used, or nil when it can. The path is what
    /// follows the verb, so an empty one is a line with nothing to act on.
    static func refusal(for path: String) -> String? {
        if path.isEmpty { return "no path" }
        if path.hasPrefix("/") { return "path must be relative" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.first?.hasPrefix("~") == true { return "path must not start with ~" }
        if parts.contains("..") { return "path must not contain .." }
        if parts.contains(".") { return "path must not contain ." }
        return nil
    }

    /// Why an entry cannot be applied to this tree, or nil when it can. The
    /// source must resolve inside the repository, and no folder on the way to
    /// the target may be a symlink, so nothing is written outside the tree.
    private static func problem(with entry: Entry, repository: URL, tree: URL) -> String? {
        if let refusal = refusal(for: entry.path) { return refusal }

        let source = repository.appendingPathComponent(entry.path)
        guard FileManager.default.fileExists(atPath: source.path) else { return "missing in the checkout" }
        let root = repository.resolvingSymlinksInPath().path + "/"
        guard source.resolvingSymlinksInPath().path.hasPrefix(root) else {
            return "resolves outside the repository"
        }

        // Every folder between the tree and the target, checked with lstat:
        // createDirectory would follow a symlink and write through it.
        let parts = entry.path.split(separator: "/")
        var folder = tree
        for part in parts.dropLast() {
            folder = folder.appendingPathComponent(String(part))
            if isSymlink(folder.path) { return "passes through a symlink in the worktree" }
        }

        // Checked with lstat, not `fileExists`, which is false for a symlink
        // that points nowhere: that is still something in the way.
        if exists(tree.appendingPathComponent(entry.path).path) { return "already in the worktree" }
        return nil
    }

    /// Clones `source` to `target` where the volume can (APFS: no disk is
    /// used until either side changes), and copies it otherwise.
    private static func cloneOrCopy(_ source: String, to target: String) throws {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        guard copyfile(source, target, state, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }
}
