import Foundation

/// Which build of Vitra typed a maestro's launch line, noted per project.
///
/// A maestro lives in the pty-host and outlives the app, a reinstall
/// included. It then goes on with the brief, the MCP helper (the old binary,
/// with the old tool logic) and the hooks the old app gave it. The stamp is
/// how the next app tells such a maestro from one it started itself.
struct MaestroStamp: Codable, Equatable {
    /// `MaestroStamp.currentBuild` of the app that launched it.
    let build: String
    let mode: MaestroMode
    let launched: Date
    /// The project's folder, so a file is never taken for another project's.
    let path: String

    /// The installed build: the main executable's modification date and size.
    ///
    /// Not CFBundleVersion: scripts/build-app.sh writes a fixed version, so
    /// two installs of different code carry the same one. A rebuilt binary
    /// always has a new date, and a reinstall copies it with that date.
    static func currentBuild(executable: String? = Bundle.main.executablePath) -> String? {
        guard let executable,
              let attributes = try? FileManager.default.attributesOfItem(atPath: executable),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return "\(Int64(modified.timeIntervalSince1970 * 1000))-\(size.int64Value)"
    }

    /// Beside the attention and model files, named by the same digest.
    static func file(for project: String, in directory: URL = Maestro.supportDirectory) -> URL {
        directory.appendingPathComponent("stamp-" + Maestro.sessionFile(for: project, in: directory).lastPathComponent)
    }

    static func load(for project: String, in directory: URL = Maestro.supportDirectory) -> MaestroStamp? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file(for: project, in: directory)),
              let stamp = try? decoder.decode(MaestroStamp.self, from: data),
              stamp.path == CockpitProject(path: project).path
        else { return nil }
        return stamp
    }

    /// Notes who launched `project`'s maestro. Failing is harmless: the
    /// maestro is merely taken for an old one after the next reinstall.
    static func record(build: String, mode: MaestroMode, for project: String, now: Date = Date(), in directory: URL = Maestro.supportDirectory) {
        let stamp = MaestroStamp(build: build, mode: mode, launched: now, path: CockpitProject(path: project).path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(stamp) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: project, in: directory), options: .atomic)
    }

    /// Whether a maestro is running code older than the app's.
    ///
    /// Only one the app attached to can be: a maestro the app launched is its
    /// own. One attached with no stamp predates stamps, so it is old too. A
    /// build that cannot be read marks nothing, rather than everything.
    static func isOutdated(attached: Bool, recorded: MaestroStamp?, current: String?) -> Bool {
        guard attached, let current else { return false }
        return recorded?.build != current
    }
}

/// Where a project's maestro stands on being brought up to the new build.
///
/// `armed` is a one-shot: the maestro was mid-turn when the user asked, and
/// it is restarted the next time a turn ends. Pure, so the order of events
/// can be tested without a terminal.
struct MaestroUpdateState: Equatable {
    enum Phase: Equatable {
        /// Launched by this build, or nothing is known against it.
        case current
        /// Survived a reinstall: still the old brief, helper and hooks.
        case outdated
        /// Restarts when the running turn ends.
        case armed
    }

    private(set) var phase: Phase = .current

    mutating func markOutdated() {
        if phase == .current { phase = .outdated }
    }

    mutating func arm() {
        if phase == .outdated { phase = .armed }
    }

    mutating func cancel() {
        if phase == .armed { phase = .outdated }
    }

    /// A fresh launch: the stamp is rewritten, nothing is pending.
    mutating func relaunched() {
        phase = .current
    }

    /// Whether this attention change is the end of a turn that an armed
    /// update waits for. Only working → waiting: a permission prompt is the
    /// middle of a turn, and a state merely re-read is no change at all.
    func fires(from previous: AttentionState?, to state: AttentionState?) -> Bool {
        phase == .armed && previous == .working && state == .waiting
    }
}

extension Maestro {
    /// What a maestro restarted on the new build is told when it comes back:
    /// its turn had ended, so there is nothing to pick up.
    static let updatedPrompt = "O Vitra foi atualizado e este maestro foi reiniciado na versão nova. A conversa é a mesma; siga normalmente."
}
