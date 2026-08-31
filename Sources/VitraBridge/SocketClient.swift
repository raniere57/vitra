import Darwin
import Foundation

/// The CLI's end of the bridge: one request, one reply, then done.
///
/// Deliberately blocking. This runs inside a short-lived helper process that has
/// nothing else to do, and a state machine would only add ways to be wrong.
public enum SocketClient {
    public static func send(
        _ request: JSONRPC.Request,
        to path: String = SocketPath.path,
        timeout: TimeInterval = 30
    ) throws -> JSONRPC.Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.failed("socket", errno) }
        defer { Darwin.close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        // ENOENT and ECONNREFUSED both mean the same thing to a user: the app
        // is not there. A stale socket file left by a crash gives the second.
        guard connected == 0 else { throw SocketError.notRunning }

        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        let framed = SocketFraming.frame(try JSONRPC.encode(request))
        try framed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                guard written > 0 else { throw SocketError.failed("write", errno) }
                offset += written
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let frame = try SocketFraming.nextFrame(from: &buffer) {
                guard let response = try? JSONDecoder().decode(JSONRPC.Response.self, from: frame) else {
                    throw SocketError.malformedReply
                }
                return response
            }

            let read = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 16 * 1024) }
            if read > 0 {
                buffer.append(contentsOf: chunk[0..<read])
                continue
            }
            // Zero is a clean close before a full frame; EAGAIN is the timeout.
            throw read == 0 ? SocketError.notRunning : SocketError.timedOut
        }
    }
}
