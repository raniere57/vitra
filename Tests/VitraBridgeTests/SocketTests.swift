import Foundation
import Testing
@testable import VitraBridge

@Suite("Socket transport")
struct SocketTests {
    @Test func aFrameSurvivesBeingSplitAcrossReads() throws {
        let payload = Data("{\"a\":1}".utf8)
        let framed = SocketFraming.frame(payload)

        var buffer = Data()
        for byte in framed.dropLast() {
            buffer.append(byte)
            #expect(try SocketFraming.nextFrame(from: &buffer) == nil)
        }
        buffer.append(framed.last!)
        #expect(try SocketFraming.nextFrame(from: &buffer) == payload)
        #expect(buffer.isEmpty)
    }

    @Test func severalFramesInOneBufferComeOutInOrder() throws {
        var buffer = SocketFraming.frame(Data("one".utf8))
        buffer.append(SocketFraming.frame(Data("two".utf8)))

        #expect(try SocketFraming.nextFrame(from: &buffer) == Data("one".utf8))
        #expect(try SocketFraming.nextFrame(from: &buffer) == Data("two".utf8))
        #expect(try SocketFraming.nextFrame(from: &buffer) == nil)
    }

    /// A wrong-protocol client must not be able to make the server allocate.
    @Test func anAbsurdLengthIsRejected() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: SocketFraming.FramingError.self) {
            _ = try SocketFraming.nextFrame(from: &buffer)
        }
    }

    @Test func aRequestReachesTheServerAndTheReplyComesBack() throws {
        let path = NSTemporaryDirectory() + "vitra-test-\(UUID().uuidString.prefix(8)).sock"
        let server = SocketServer { request in
            JSONRPC.Response(id: request.id, result: ["echo": .string(request.method)])
        }
        try server.start(at: path)
        defer { server.stop() }

        let response = try SocketClient.send(
            JSONRPC.Request(id: .number(3), method: "ping"),
            to: path,
            timeout: 5
        )
        #expect(response.id == .number(3))
        #expect(response.result?["echo"]?.stringValue == "ping")
    }

    /// The socket carries the user's terminal, so it is theirs alone.
    @Test func theSocketIsOnlyReadableByItsOwner() throws {
        let path = NSTemporaryDirectory() + "vitra-perm-\(UUID().uuidString.prefix(8)).sock"
        let server = SocketServer { _ in nil }
        try server.start(at: path)
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func connectingToNothingSaysVitraIsNotRunning() {
        let path = NSTemporaryDirectory() + "vitra-absent-\(UUID().uuidString.prefix(8)).sock"
        #expect(throws: SocketError.self) {
            _ = try SocketClient.send(JSONRPC.Request(id: .number(1), method: "ping"), to: path, timeout: 1)
        }
    }
}
