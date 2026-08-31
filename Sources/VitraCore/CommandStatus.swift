import Foundation

/// How a command ended, as the shell reported it.
///
/// The exit code cannot be read back off the screen: OSC 133's `D` is consumed
/// by the terminal core, so the shell integration also sends this on Vitra's own
/// channel, where it reaches the app intact.
public struct CommandStatus: Equatable, Sendable {
    /// Exit code, or nil for a prompt where nothing was run (a bare Return).
    public var exitCode: Int32?
    /// How long the command took.
    public var duration: TimeInterval

    public init(exitCode: Int32?, duration: TimeInterval) {
        self.exitCode = exitCode
        self.duration = duration
    }

    public var failed: Bool { (exitCode ?? 0) != 0 }

    /// `exit 1 · 0.4s`, or just the duration when the command succeeded.
    ///
    /// Only interesting durations are shown: every command taking "0.0s" is
    /// noise on every line, and the eye stops reading the column.
    public var label: String? {
        let time = duration >= 0.5 ? Self.time(duration) : nil
        switch (exitCode, time) {
        case let (code?, time?) where code != 0: return "exit \(code) · \(time)"
        case let (code?, nil) where code != 0: return "exit \(code)"
        case let (_, time?): return time
        default: return nil
        }
    }

    private static func time(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return "\(minutes)m \(rest)s"
    }

    /// What the shell integration reports on Vitra's own channel.
    public enum Event: Equatable, Sendable {
        /// A command just started running.
        case started
        /// A command ended, or a prompt closed with nothing run.
        case finished(CommandStatus)

        public static func parse(payload: String) -> Event? {
            if payload.hasPrefix("vitra-block-start") { return .started }
            return CommandStatus.parse(payload: payload).map { .finished($0) }
        }
    }

    /// Parses `vitra-block;code=1;ms=412`, the payload the shell integration sends.
    ///
    /// A prompt where nothing ran carries no `code`, which is what keeps the
    /// statuses lined up with the blocks on screen: one per prompt, always.
    public static func parse(payload: String) -> CommandStatus? {
        var fields: [String: String] = [:]
        for field in payload.split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }
        guard payload.hasPrefix("vitra-block"), !payload.hasPrefix("vitra-block-start") else { return nil }

        let milliseconds = fields["ms"].flatMap(Double.init) ?? 0
        return CommandStatus(
            exitCode: fields["code"].flatMap { Int32($0) },
            duration: max(0, milliseconds) / 1000
        )
    }
}
