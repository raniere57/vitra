import Foundation
import VitraOrchestrator

/// One thing that happened in a project's repository.
struct GitEvent: Equatable, Sendable {
    enum Kind: Sendable { case commit, push, pullRequest }

    let kind: Kind
    let title: String
    let detail: String
    let date: Date
    /// Where to read more, for the events that live on a website.
    let url: String?
}

/// The recent history of a repository: commits, pushes and pull requests.
///
/// The parsing is apart from the running so it can be tested against what git
/// really prints. Fields are separated by the unit separator (0x1F), which a
/// commit subject cannot reasonably contain.
enum GitHistory {
    private static let separator: Character = "\u{1f}"
    private static let mostCommits = 40
    private static let mostPulls = 15

    /// Commits of every branch, newest first.
    static let logArguments = ["log", "--all", "--date-order", "-n", "\(mostCommits)", "--format=%h%x1f%an%x1f%ct%x1f%s"]

    /// The moments a remote branch was moved by a push from this machine,
    /// which only the reflog remembers.
    static let pushArguments = [
        "log", "-g", "--all", "-n", "\(mostCommits)", "--date=unix",
        "--grep-reflog=update by push", "--format=%gD%x1f%gs%x1f%h%x1f%s",
    ]

    static let pullArguments = [
        "pr", "list", "--state", "all", "--limit", "\(mostPulls)",
        "--json", "number,title,state,updatedAt,url,headRefName",
    ]

    static func commits(fromLog log: String) -> [GitEvent] {
        fields(of: log, count: 4).compactMap { field in
            guard let seconds = TimeInterval(field[2]) else { return nil }
            return GitEvent(
                kind: .commit, title: field[3], detail: "\(field[0]) · \(field[1])",
                date: Date(timeIntervalSince1970: seconds), url: nil
            )
        }
    }

    static func pushes(fromReflog reflog: String) -> [GitEvent] {
        fields(of: reflog, count: 4).compactMap { field in
            // refs/remotes/origin/main@{1794274272}
            let parts = field[0].components(separatedBy: "@{")
            guard parts.count == 2, let seconds = TimeInterval(parts[1].dropLast()) else { return nil }
            let branch = parts[0].replacingOccurrences(of: "refs/remotes/", with: "")
            return GitEvent(
                kind: .push, title: "push → \(branch)", detail: "\(field[2]) · \(field[3])",
                date: Date(timeIntervalSince1970: seconds), url: nil
            )
        }
    }

    static func pullRequests(fromJSON json: Data) -> [GitEvent] {
        struct Pull: Decodable {
            let number: Int
            let title: String
            let state: String
            let updatedAt: Date
            let url: String
            let headRefName: String
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let pulls = try? decoder.decode([Pull].self, from: json) else { return [] }
        let states = ["OPEN": "aberto", "MERGED": "mesclado", "CLOSED": "fechado"]
        return pulls.map { pull in
            GitEvent(
                kind: .pullRequest, title: "PR #\(pull.number) · \(pull.title)",
                detail: "\(states[pull.state] ?? pull.state.lowercased()) · \(pull.headRefName)",
                date: pull.updatedAt, url: pull.url
            )
        }
    }

    static func timeline(_ lists: [GitEvent]...) -> [GitEvent] {
        lists.flatMap { $0 }.sorted { $0.date > $1.date }
    }

    /// When an event happened: the date and hour, then how long ago that was.
    static func stamp(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let exact = DateFormatter()
        exact.locale = Locale(identifier: "pt_BR")
        exact.timeZone = timeZone
        exact.dateFormat = sameYear ? "dd/MM HH:mm" : "dd/MM/yyyy HH:mm"
        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale(identifier: "pt_BR")
        relative.unitsStyle = .abbreviated
        // A clock a little ahead must not read as "in 2 seconds".
        return exact.string(from: date) + " · " + relative.localizedString(for: min(date, now), relativeTo: now)
    }

    /// The lines of `output` that have exactly the fields asked for.
    private static func fields(of output: String, count: Int) -> [[String]] {
        output.split(separator: "\n")
            .map { $0.split(separator: separator, maxSplits: count - 1, omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count == count }
    }

    // MARK: - Running

    /// The shared git directory of `path`, even when `path` is a worktree.
    ///
    /// `HEAD` and the reflog live there, so a watch on the checkout's `.git`
    /// file would miss every commit. Resolved once; relative paths are made
    /// absolute against the repository.
    static func gitCommonDirectory(in path: String) -> String? {
        guard let data = run("/usr/bin/git", ["rev-parse", "--git-common-dir"], in: path) else { return nil }
        let dir = text(data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return nil }
        if dir.hasPrefix("/") { return dir }
        return URL(fileURLWithPath: path).appendingPathComponent(dir).standardizedFileURL.path
    }

    /// Commits and pushes of the repository at `path`; nil when it is not one.
    static func loadLocal(in path: String, done: @escaping @MainActor @Sendable ([GitEvent]?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let log = run("/usr/bin/git", logArguments, in: path)
            let reflog = run("/usr/bin/git", pushArguments, in: path)
            let events = log.map { timeline(commits(fromLog: text($0)), pushes(fromReflog: text(reflog ?? Data()))) }
            Task { @MainActor in done(events) }
        }
    }

    /// The repository's pull requests, as `gh` knows them. Empty when there is
    /// no gh, no login or no remote: a history without them is still a history.
    static func loadPulls(in path: String, done: @escaping @MainActor @Sendable ([GitEvent]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let json = run("/usr/bin/env", ["gh"] + pullArguments, in: path)
            let events = pullRequests(fromJSON: json ?? Data())
            Task { @MainActor in done(events) }
        }
    }

    private static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private static func run(_ executable: String, _ arguments: [String], in directory: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        // The app's PATH is thinner than the shell's, and gh lives in Homebrew.
        environment["PATH"] = Executables.defaultSearchPath
        // Looking must never take the lock a commit in the terminal needs.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GH_PROMPT_DISABLED"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
