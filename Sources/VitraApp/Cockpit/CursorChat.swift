import Foundation

/// A Cursor maestro's chat: Cursor chooses a chat's id, so one is made
/// before the maestro starts and resumed from then on.
enum CursorChat {
    /// Makes an empty chat for `directory` and returns its id, or nil when
    /// Cursor is missing, signed out or said something that is not an id.
    /// Blocks for a second or two: never on the main thread.
    static func create(in directory: String) -> String? {
        let process = Process()
        // A login shell, for the PATH the user's own terminal has.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "agent create-chat"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return id(in: String(decoding: data, as: UTF8.self))
    }

    /// The chat id in what `agent create-chat` printed: its last line, when
    /// that is exactly a UUID. It is typed into a shell, so nothing else passes.
    static func id(in output: String) -> String? {
        let last = output.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
        return last.flatMap { UUID(uuidString: $0) != nil ? $0.lowercased() : nil }
    }
}
