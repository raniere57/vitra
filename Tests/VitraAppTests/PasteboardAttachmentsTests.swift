import AppKit
import Testing
import VitraCore

@testable import VitraApp

@Suite("Pasteboard attachments")
struct PasteboardAttachmentsTests {
    /// A pasteboard nobody else writes to, so the tests cannot disturb — or be
    /// disturbed by — whatever the user has actually copied.
    private func scratchPasteboard(_ name: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.vitra.tests.\(name)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func scratchStore() -> (AttachmentStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vitra-paste-\(UUID().uuidString)")
        return (AttachmentStore(directory: directory), directory)
    }

    private func onePixelPNG() -> Data {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        )!
        representation.setColor(.red, atX: 0, y: 0)
        return representation.representation(using: .png, properties: [:])!
    }

    @Test("plain text is not an attachment")
    func plainTextIsNotAnAttachment() {
        let (store, directory) = scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pasteboard = scratchPasteboard("text")
        pasteboard.setString("ls -la", forType: .string)

        #expect(PasteboardAttachments.read(from: pasteboard, store: store).isEmpty)
    }

    @Test("a pasted image is written to disk as png")
    func pastedImageIsWrittenToDisk() throws {
        let (store, directory) = scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let png = onePixelPNG()
        let pasteboard = scratchPasteboard("png")
        pasteboard.setData(png, forType: .png)

        let attachments = PasteboardAttachments.read(from: pasteboard, store: store)
        #expect(attachments.count == 1)

        let attachment = try #require(attachments.first)
        #expect(attachment.isTemporary)
        #expect(attachment.url.pathExtension == "png")
        // The bytes are passed through, not re-encoded.
        #expect(try Data(contentsOf: attachment.url) == png)
    }

    @Test("tiff-only image data is normalised to png")
    func tiffIsNormalisedToPNG() throws {
        let (store, directory) = scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tiff = try #require(NSBitmapImageRep(data: onePixelPNG())?.tiffRepresentation)
        let pasteboard = scratchPasteboard("tiff")
        pasteboard.setData(tiff, forType: .tiff)

        let attachment = try #require(PasteboardAttachments.read(from: pasteboard, store: store).first)
        #expect(attachment.url.pathExtension == "png")

        // The extension has to describe the contents: PNG starts with \x89PNG.
        let written = try Data(contentsOf: attachment.url)
        #expect(written.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("a copied file is referenced in place, not duplicated")
    func copiedFileIsReferencedInPlace() throws {
        let (store, directory) = scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vitra-copied-\(UUID().uuidString).png")
        try onePixelPNG().write(to: existing)
        defer { try? FileManager.default.removeItem(at: existing) }

        // The Finder puts both the file URL and the image data on the pasteboard.
        let pasteboard = scratchPasteboard("file")
        pasteboard.writeObjects([existing as NSURL])
        pasteboard.setData(onePixelPNG(), forType: .png)

        let attachment = try #require(PasteboardAttachments.read(from: pasteboard, store: store).first)
        #expect(attachment.url.standardizedFileURL == existing.standardizedFileURL)
        #expect(!attachment.isTemporary)
        // Nothing was copied into the attachments directory.
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("a path with spaces reaches the prompt quoted")
    func pathWithSpacesIsQuoted() throws {
        let (store, directory) = scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let awkward = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vitra test \(UUID().uuidString).png")
        try onePixelPNG().write(to: awkward)
        defer { try? FileManager.default.removeItem(at: awkward) }

        let pasteboard = scratchPasteboard("spaces")
        pasteboard.writeObjects([awkward as NSURL])

        let attachments = PasteboardAttachments.read(from: pasteboard, store: store)
        let typed = ShellQuoting.join(attachments.map(\.path))
        #expect(typed.hasPrefix("'"))
        #expect(typed.contains("vitra test "))
    }
}
