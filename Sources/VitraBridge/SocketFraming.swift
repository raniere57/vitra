import Foundation
import VitraCore

/// Length-prefixed JSON on a stream socket.
///
/// A stream gives no message boundaries, and the alternative — newline
/// delimiting — would need escaping the moment a payload contains one. Four
/// bytes of big-endian length in front costs nothing and cannot be ambiguous.
public enum SocketFraming {
    /// Refuses anything absurd, so a wrong-protocol client cannot make the
    /// server allocate a gigabyte.
    public static let maximumFrame = 8 * 1024 * 1024

    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    /// Pulls one complete frame off the front of `buffer`, if there is one.
    public static func nextFrame(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length <= maximumFrame else { throw FramingError.frameTooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }

        let payload = buffer.subdata(in: 4..<(4 + length))
        buffer.removeSubrange(0..<(4 + length))
        return payload
    }

    public enum FramingError: Error, CustomStringConvertible {
        case frameTooLarge(Int)

        public var description: String {
            switch self {
            case let .frameTooLarge(size): return "frame of \(size) bytes exceeds the limit"
            }
        }
    }
}

/// Where the GUI listens and the CLI connects.
public enum SocketPath {
    public static let url = Vitra.supportDirectory.appendingPathComponent("vitra.sock")
    public static var path: String { url.path }
}
