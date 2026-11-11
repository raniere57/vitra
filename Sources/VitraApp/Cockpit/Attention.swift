import Foundation
import VitraCore

/// What a project's maestro is doing, as far as the user is concerned.
enum AttentionState: String, Codable, Equatable {
    /// A turn is running: nothing is asked of the user.
    case working
    /// The turn ended, or claude has been idle: the maestro awaits the next instruction.
    case waiting
    /// claude stopped for a permission.
    case needsPermission
}

/// One project's attention state, as `Vitra hook` leaves it on disk.
struct AttentionRecord: Codable, Equatable {
    let state: AttentionState
    let message: String?
    /// When the maestro entered this state.
    let since: Date
    /// The project's folder, so a file is never taken for another project's.
    let path: String

    static func encode(_ record: AttentionRecord) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(record)
    }

    static func decode(_ data: Data) -> AttentionRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AttentionRecord.self, from: data)
    }
}

/// What a claude hook event does to a project's state file.
enum AttentionUpdate: Equatable {
    case write(AttentionRecord)
    /// The maestro is gone: nothing is waiting.
    case remove
    case ignore
}

/// The hook side: payload in, state out. Pure; `Attention` does the files.
enum AttentionHook {
    /// The events `Vitra hook` is registered for in the maestro's settings.
    static let events = ["Notification", "Stop", "UserPromptSubmit", "SessionEnd"]
    private static let messageLimit = 200

    /// What `event` with this hook `input` does to the project's state.
    ///
    /// `previous` keeps `since` honest: claude's idle notification arrives a
    /// minute after the Stop that already put the maestro in `waiting`, and the
    /// clock must not start over.
    static func update(event: String, input: Data, project: String, now: Date, previous: AttentionRecord?) -> AttentionUpdate {
        let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        let state: AttentionState
        var message: String?
        switch event {
        case "Stop":
            state = .waiting
        case "UserPromptSubmit":
            state = .working
        case "SessionEnd":
            return .remove
        case "Notification":
            let text = payload["message"] as? String
            switch payload["notification_type"] as? String {
            case "permission_prompt": state = .needsPermission
            case "idle_prompt", "elicitation_dialog": state = .waiting
            // Anything else (a sign-in that worked, say) asks nothing of the user.
            case .some: return .ignore
            // Older claude: no type, only the words.
            case nil: state = text?.lowercased().contains("permission") == true ? .needsPermission : .waiting
            }
            message = text.map { String($0.prefix(messageLimit)) }.flatMap { $0.isEmpty ? nil : $0 }
        default:
            return .ignore
        }
        let since = previous?.state == state && previous?.path == project ? previous?.since ?? now : now
        // A repeat keeps the message it had when the new one has none.
        let kept = previous?.state == state ? previous?.message : nil
        return .write(AttentionRecord(state: state, message: message ?? kept, since: since, path: project))
    }

    /// The project a hook belongs to: the one the cockpit named in the shell's
    /// environment, else the folder claude was in.
    static func project(input: Data, environment: String?) -> String? {
        if let environment, !environment.isEmpty { return CockpitProject(path: environment).path }
        let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        return (payload?["cwd"] as? String).map { CockpitProject(path: $0).path }
    }

    /// The `hooks` entries for the maestro's settings: one command per event.
    static func settingsHooks(binary: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in events {
            let command = ["type": "command", "command": ShellQuote.quote(binary) + " hook " + event]
            hooks[event] = [["hooks": [command]]]
        }
        return hooks
    }
}

/// The state files, one per project, in the folder the window already watches.
enum Attention {
    static func file(for project: String, in directory: URL = Maestro.supportDirectory) -> URL {
        let name = Maestro.sessionFile(for: project, in: directory).lastPathComponent
        return directory.appendingPathComponent("attention-" + name)
    }

    static func load(for project: String, in directory: URL = Maestro.supportDirectory) -> AttentionRecord? {
        guard let record = (try? Data(contentsOf: file(for: project, in: directory))).flatMap(AttentionRecord.decode),
              record.path == CockpitProject(path: project).path
        else { return nil }
        return record
    }

    static func remove(for project: String, in directory: URL = Maestro.supportDirectory) {
        try? FileManager.default.removeItem(at: file(for: project, in: directory))
    }

    /// What `Vitra hook <event>` does. Never throws and never prints: a hook's
    /// output goes into the conversation and its failure into the user's face.
    static func run(event: String?, input: Data, environmentProject: String?, now: Date = Date(), in directory: URL = Maestro.supportDirectory) {
        let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        guard let event = event ?? payload?["hook_event_name"] as? String,
              let project = AttentionHook.project(input: input, environment: environmentProject)
        else { return }
        let previous = load(for: project, in: directory)
        switch AttentionHook.update(event: event, input: input, project: project, now: now, previous: previous) {
        case .ignore:
            return
        case .remove:
            remove(for: project, in: directory)
        case let .write(record):
            guard let data = AttentionRecord.encode(record) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file(for: project, in: directory), options: .atomic)
        }
    }

    // MARK: Interrupted work

    /// How long a note that a maestro was cut off stays worth acting on: a
    /// restart is back in seconds, and a note from yesterday is not news.
    static let interruptionLasts: TimeInterval = 15 * 60

    static func interruptedFile(for project: String, in directory: URL = Maestro.supportDirectory) -> URL {
        directory.appendingPathComponent("interrupted-" + Maestro.sessionFile(for: project, in: directory).lastPathComponent)
    }

    /// Notes, as the app goes away, which of `projects` had a maestro in the
    /// middle of a turn. Quitting kills them, and reinstalling Vitra quits it:
    /// without the note the work would sit there until the user said "go on".
    static func markInterrupted(projects: [String], now: Date = Date(), in directory: URL = Maestro.supportDirectory) {
        for project in projects where load(for: project, in: directory)?.state == .working {
            try? Data(ISO8601DateFormatter().string(from: now).utf8)
                .write(to: interruptedFile(for: project, in: directory), options: .atomic)
        }
    }

    /// Whether `project`'s maestro was cut off mid-turn a moment ago. Asked
    /// once: the note is taken away with the answer.
    static func takeInterrupted(for project: String, now: Date = Date(), in directory: URL = Maestro.supportDirectory) -> Bool {
        let file = interruptedFile(for: project, in: directory)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let noted = ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return now.timeIntervalSince(noted) < interruptionLasts
    }

    /// How long after a permission was asked for a sign of work means it was
    /// given: the status line also runs as the prompt itself is drawn.
    static let permissionSettles: TimeInterval = 2

    /// claude is at work again: its status line was redrawn. No hook fires
    /// when the user answers a permission prompt, so without this the project
    /// would go on saying "pede permissão" until the turn ended.
    static func resumed(project: String?, now: Date = Date(), in directory: URL = Maestro.supportDirectory) {
        guard let project, let record = load(for: project, in: directory),
              record.state == .needsPermission,
              now.timeIntervalSince(record.since) > permissionSettles,
              let data = AttentionRecord.encode(
                  AttentionRecord(state: .working, message: nil, since: now, path: record.path)
              )
        else { return }
        try? data.write(to: file(for: project, in: directory), options: .atomic)
    }
}

/// What the cockpit makes of a state.
enum AttentionPolicy {
    /// A turn that just ended is not yet worth an amber dot: the user is very
    /// likely looking at it. Past this, the maestro is idle on them.
    static let quietPeriod: TimeInterval = 5

    /// Whether the project's tab should call for the user.
    static func isCalling(_ record: AttentionRecord?, now: Date) -> Bool {
        switch record?.state {
        case .needsPermission: return true
        case .waiting: return now.timeIntervalSince(record?.since ?? now) >= quietPeriod
        case .working, nil: return false
        }
    }

    /// Whether a turn ended that the user has not looked at: the maestro is
    /// waiting, has been for the quiet period, and the project has not been
    /// in front of the user since it stopped.
    static func isUnseen(_ record: AttentionRecord?, seen: Date?, now: Date) -> Bool {
        guard let record, record.state == .waiting,
              now.timeIntervalSince(record.since) >= quietPeriod
        else { return false }
        return seen.map { $0 < record.since } ?? true
    }

    /// Seconds until a `waiting` record starts calling, or nil when it never will.
    static func untilCalling(_ record: AttentionRecord?, now: Date) -> TimeInterval? {
        guard record?.state == .waiting, let since = record?.since else { return nil }
        let left = quietPeriod - now.timeIntervalSince(since)
        return left > 0 ? left : nil
    }

    /// The header pill's text, or nil while nothing is asked.
    static func label(_ record: AttentionRecord?, now: Date) -> String? {
        guard let record, isCalling(record, now: now) else { return nil }
        let what = record.state == .needsPermission ? "pede permissão" : "aguardando você"
        return what + " · " + elapsed(now.timeIntervalSince(record.since))
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        // The pill is redrawn every half minute: a count of seconds would
        // sit frozen on screen, so under a minute it says only that.
        if seconds < 60 { return "agora" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }

    /// The text of the notification: claude's own words, else the plain fact.
    static func body(_ record: AttentionRecord) -> String {
        record.message ?? "O maestro terminou e aguarda você"
    }
}

/// When to interrupt the user with a notification and a sound.
final class AttentionThrottle {
    /// No more than one alert per project in this time.
    static let interval: TimeInterval = 30

    private var states: [String: AttentionState] = [:]
    private var lastAlert: [String: Date] = [:]

    /// Notes the project's state, and says whether this is the moment to alert.
    ///
    /// An alert is a transition into `waiting` or `needsPermission` — from
    /// working, or from nothing, or from waiting to a permission — while the
    /// user is not typing in that project's terminal, and not within
    /// `interval` of the last one.
    func shouldAlert(project: String, state: AttentionState?, now: Date, isWatching: Bool) -> Bool {
        let before = states[project]
        states[project] = state
        guard let state, state != .working, before != state else { return false }
        if state == .waiting, before == .needsPermission { return false }
        guard !isWatching else { return false }
        if let last = lastAlert[project], now.timeIntervalSince(last) < Self.interval { return false }
        lastAlert[project] = now
        return true
    }
}
