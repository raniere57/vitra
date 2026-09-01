import Foundation

/// Whether a Vitra is already answering on the socket.
///
/// The socket is the app's singleton lock: a live listener means a copy of the
/// GUI is already up and owns the tools, so a second one starting has nothing
/// to add. A file with nothing behind it — left by a crash — is not a running
/// app and does not count.
public enum SocketProbe {
    public static func anotherInstanceIsServing(at path: String = SocketPath.path) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let ping = JSONRPC.Request(id: .number(0), method: "ping")
        return (try? SocketClient.send(ping, to: path, timeout: 2)) != nil
    }
}
