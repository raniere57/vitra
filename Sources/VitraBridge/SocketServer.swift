import Darwin
import Foundation

/// The GUI's end of the bridge: a unix socket carrying framed JSON-RPC.
///
/// The socket is created with mode 0600, so only the user who is running Vitra
/// can drive it. Nothing else authenticates: a process running as the user could
/// read the terminal anyway.
public final class SocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (JSONRPC.Request) async -> JSONRPC.Response?

    private let queue = DispatchQueue(label: "dev.vitra.bridge", qos: .userInitiated)
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: DispatchSourceRead] = [:]

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit { stop() }

    /// Binds and starts accepting. Throws if the path cannot be bound.
    public func start(at path: String = SocketPath.path) throws {
        try FileManager.default.createDirectory(
            at: SocketPath.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Another window may already be serving. Ask before taking the socket:
        // a live listener answers, and a socket left behind by a crash does not.
        if FileManager.default.fileExists(atPath: path) {
            let probe = JSONRPC.Request(id: .number(0), method: "ping")
            if (try? SocketClient.send(probe, to: path, timeout: 2)) != nil {
                throw SocketError.alreadyServing
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.failed("socket", errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            Darwin.close(fd)
            throw SocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw SocketError.failed("bind", errno)
        }

        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw SocketError.failed("listen", errno)
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        for (fd, source) in connections {
            source.cancel()
            Darwin.close(fd)
        }
        connections.removeAll()
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
            unlink(SocketPath.path)
        }
    }

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }

        var buffer = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let available = Int(source.data)
            guard available > 0 else {
                self.closeConnection(fd)
                return
            }

            var chunk = [UInt8](repeating: 0, count: available)
            let read = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, available) }
            guard read > 0 else {
                self.closeConnection(fd)
                return
            }
            buffer.append(contentsOf: chunk[0..<read])

            while true {
                let frame: Data?
                do {
                    frame = try SocketFraming.nextFrame(from: &buffer)
                } catch {
                    self.closeConnection(fd)
                    return
                }
                guard let frame else { return }
                self.dispatch(frame, to: fd)
            }
        }
        source.resume()
        connections[fd] = source
    }

    private func dispatch(_ frame: Data, to fd: Int32) {
        guard let request = try? JSONDecoder().decode(JSONRPC.Request.self, from: frame) else {
            let response = JSONRPC.Response(id: nil, code: .parse, message: "malformed request")
            send(response, to: fd)
            return
        }

        Task { [handler] in
            guard let response = await handler(request) else { return }
            self.send(response, to: fd)
        }
    }

    private func send(_ response: JSONRPC.Response, to fd: Int32) {
        guard let payload = try? JSONRPC.encode(response) else { return }
        let framed = SocketFraming.frame(payload)
        framed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private func closeConnection(_ fd: Int32) {
        connections[fd]?.cancel()
        connections[fd] = nil
        Darwin.close(fd)
    }
}

public enum SocketError: Error, CustomStringConvertible {
    case failed(String, Int32)
    case pathTooLong(String)
    case notRunning
    case alreadyServing
    case timedOut
    case malformedReply

    public var description: String {
        switch self {
        case let .failed(call, code): return "\(call) failed: \(String(cString: strerror(code)))"
        case let .pathTooLong(path): return "socket path too long: \(path)"
        case .notRunning: return "Vitra is not running"
        case .alreadyServing: return "another Vitra window is already serving the tools"
        case .timedOut: return "Vitra did not answer in time"
        case .malformedReply: return "Vitra sent a reply this version cannot read"
        }
    }
}
