import Foundation
import Testing
@testable import VitraCore

/// Feeds `text` in chunks of `chunk` bytes and returns every payload found.
private func scan(_ text: String, chunk: Int = .max) -> [String] {
    var scanner = OSCScanner()
    var found: [String] = []
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let end = min(bytes.count, offset + max(1, chunk))
        bytes[offset..<end].withUnsafeBytes { scanner.scan($0) { found.append($0) } }
        offset = end
    }
    return found
}

@Test func belTerminatedSequenceIsFound() {
    #expect(scan("\u{1B}]7337;file=/tmp/a.png\u{07}") == ["file=/tmp/a.png"])
}

@Test func stTerminatedSequenceIsFound() {
    #expect(scan("\u{1B}]7337;file=/tmp/a.png\u{1B}\\") == ["file=/tmp/a.png"])
}

@Test func surroundingOutputIsIgnored() {
    let stream = "before\u{1B}]7337;file=/tmp/a.png\u{07}after\n"
    #expect(scan(stream) == ["file=/tmp/a.png"])
}

/// The pty hands over whatever the kernel had ready, so a sequence is routinely
/// cut in half. Every split has to behave like the whole.
@Test func sequenceSplitAcrossReadsIsFound() {
    let stream = "x\u{1B}]7337;file=/tmp/a.png\u{07}y"
    for chunk in 1...stream.utf8.count {
        #expect(scan(stream, chunk: chunk) == ["file=/tmp/a.png"], "chunk size \(chunk)")
    }
}

@Test func otherOSCSequencesAreLeftAlone() {
    #expect(scan("\u{1B}]0;a title\u{07}\u{1B}]7;file://host/tmp\u{07}").isEmpty)
}

@Test func severalSequencesInOneChunkAreAllFound() {
    let stream = "\u{1B}]7337;file=/a\u{07}\u{1B}]7337;file=/b\u{1B}\\"
    #expect(scan(stream) == ["file=/a", "file=/b"])
}

@Test func aCancelledSequenceIsDiscarded() {
    #expect(scan("\u{1B}]7337;file=/a\u{18}\u{1B}]7337;file=/b\u{07}") == ["file=/b"])
}

/// A stray introducer in binary output must not make the scanner buffer without
/// bound, and must not swallow a real sequence that comes after it.
@Test func anOverlongPayloadIsAbandoned() {
    let flood = String(repeating: "z", count: 5000)
    #expect(scan("\u{1B}]7337;\(flood)\u{07}\u{1B}]7337;file=/b\u{07}") == ["file=/b"])
}

@Test func anEmbeddedEscapeRestartsTheMatch() {
    // The first introducer is interrupted by a second ESC, which must not leave
    // the scanner stuck half-way through the prefix.
    #expect(scan("\u{1B}]73\u{1B}]7337;file=/a\u{07}") == ["file=/a"])
}
