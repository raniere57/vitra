import Foundation

/// JSON-RPC 2.0, only the parts MCP actually uses.
///
/// Hand-written rather than pulled from a package: this is the whole protocol,
/// and a dependency would be larger than the code it replaces.
public enum JSONRPC {
    public static let version = "2.0"

    /// Errors defined by JSON-RPC itself, plus the one this app raises.
    public enum ErrorCode: Int, Sendable {
        case parse = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
        /// Vitra's window is not open, so nothing can act on the request.
        case notRunning = -32000
    }

    public struct Request: Codable, Equatable, Sendable {
        public let jsonrpc: String
        /// Absent for notifications, which expect no reply.
        public let id: JSONValue?
        public let method: String
        public let params: JSONValue?

        public init(id: JSONValue?, method: String, params: JSONValue? = nil) {
            self.jsonrpc = JSONRPC.version
            self.id = id
            self.method = method
            self.params = params
        }

        public var isNotification: Bool { id == nil }
    }

    public struct ResponseError: Codable, Equatable, Sendable {
        public let code: Int
        public let message: String

        public init(code: ErrorCode, message: String) {
            self.code = code.rawValue
            self.message = message
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        public let jsonrpc: String
        public let id: JSONValue?
        public let result: JSONValue?
        public let error: ResponseError?

        public init(id: JSONValue?, result: JSONValue) {
            self.jsonrpc = JSONRPC.version
            self.id = id
            self.result = result
            self.error = nil
        }

        public init(id: JSONValue?, error: ResponseError) {
            self.jsonrpc = JSONRPC.version
            self.id = id
            self.result = nil
            self.error = error
        }

        public init(id: JSONValue?, code: ErrorCode, message: String) {
            self.init(id: id, error: ResponseError(code: code, message: message))
        }
    }

    /// Encoding is deterministic so tests can compare bytes, and because a
    /// stable key order makes protocol logs readable.
    public static func encode(_ response: Response) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(response)
    }

    public static func encode(_ request: Request) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }
}
