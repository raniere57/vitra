import Foundation
import Testing
@testable import VitraPanel

private func file(_ name: String, _ bytes: [UInt8]) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vitra-kind-\(UUID().uuidString)-\(name)")
    try? Data(bytes).write(to: url)
    return url
}

@Test func typesMapToTheirEngines() {
    #expect(PreviewKind(for: URL(fileURLWithPath: "/x/a.png")) == .image)
    #expect(PreviewKind(for: URL(fileURLWithPath: "/x/a.heic")) == .image)
    #expect(PreviewKind(for: URL(fileURLWithPath: "/x/a.pdf")) == .pdf)
    #expect(PreviewKind(for: URL(fileURLWithPath: "/x/a.html")) == .web)
    #expect(PreviewKind(for: URL(fileURLWithPath: "/x/a.swift")) == .text)
    #expect(PreviewKind(for: URL(fileURLWithPath: "/x/a.md")) == .text)
}

/// SVG is an image type, but NSImageView rasterises it unreliably, so it is
/// routed to WebKit instead. Deliberate deviation from the original table.
@Test func svgGoesToTheWebEngine() {
    #expect(PreviewKind(for: URL(fileURLWithPath: "/x/a.svg")) == .web)
}

@Test func anExtensionlessTextFileIsSniffed() {
    let url = file("log", Array("hello, world\n".utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(PreviewKind(for: url) == .text)
}

@Test func binaryContentWithoutATypeIsUnsupported() {
    let url = file("blob", [0x00, 0x01, 0x02, 0x00, 0xFF])
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(PreviewKind(for: url) == .unsupported)
}
