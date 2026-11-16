import Foundation

/// A prompt whose hook cannot name its tab.
///
/// A conversation claude runs in the background lives in its daemon, which
/// keeps the environment of whichever terminal started it: its hooks carry
/// another tab's VITRA_TAB, and `Maestro.belongs` rightly turns them away.
/// So when a tab attaches to such a conversation (/resume), no hook tells it,
/// and a relaunch brings back the conversation it had before. The hook notes
/// the prompt here instead; the tab the user was typing in at that moment
/// claims it.
enum MaestroStray {
    static var directory: URL { Maestro.supportDirectory.appendingPathComponent("strays") }

    /// How far apart the Return and the hook can be and still be one prompt.
    static let window: TimeInterval = 20

    private struct Note: Codable {
        let session: String
        let cwd: String
        let time: Date
    }

    /// Hook side: notes a prompt sent from a folder the hook's tab is not in.
    static func note(event: String?, input: Data, tab: String?, in directory: URL = directory, now: Date = Date()) {
        guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              (event ?? payload["hook_event_name"] as? String) == "UserPromptSubmit",
              let session = payload["session_id"] as? String, UUID(uuidString: session) != nil,
              let cwd = payload["cwd"] as? String, !cwd.isEmpty,
              let tab, !tab.isEmpty, !Maestro.belongs(cwd: cwd, to: tab),
              let data = try? encoder.encode(Note(session: session, cwd: cwd, time: now))
        else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(session + ".json"), options: .atomic)
    }

    /// App side: the conversation `tab` was typed into at `typedAt`, when a
    /// stray prompt from its folder came then. Records it as the tab's.
    @discardableResult
    static func claim(for tab: String, typedAt: Date, in directory: URL = directory,
                      sessions: URL = Maestro.sessionsDirectory, now: Date = Date()) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var claimed: String?
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let note = try? decoder.decode(Note.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if claimed == nil, Maestro.belongs(cwd: note.cwd, to: tab), abs(note.time.timeIntervalSince(typedAt)) < window,
               let input = try? JSONSerialization.data(withJSONObject: ["session_id": note.session, "cwd": note.cwd]) {
                Maestro.recordSession(hookInput: input, project: tab, in: sessions)
                claimed = note.session
                try? FileManager.default.removeItem(at: file)
            } else if now.timeIntervalSince(note.time) > 3600 {
                // Nobody typed for it: a prompt sent from elsewhere.
                try? FileManager.default.removeItem(at: file)
            }
        }
        return claimed
    }

    private static let encoder: JSONEncoder = {
        let made = JSONEncoder()
        made.dateEncodingStrategy = .secondsSince1970
        return made
    }()

    private static let decoder: JSONDecoder = {
        let made = JSONDecoder()
        made.dateDecodingStrategy = .secondsSince1970
        return made
    }()
}
