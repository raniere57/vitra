import AppKit
import UniformTypeIdentifiers
import VitraCore

/// Turns clipboard and drag-and-drop contents into files the agent can read.
///
/// The agent takes file paths typed into its prompt, so an image living only on
/// the pasteboard has to be written to disk before it can be referred to. Raw
/// image bytes are never written to the pty.
enum PasteboardAttachments {
    /// Attachments carried by `pasteboard`, or an empty array for plain text.
    ///
    /// File URLs win over image data: copying a PNG in the Finder puts both on
    /// the pasteboard, and the file the user already has is better than a second
    /// copy of it.
    static func read(from pasteboard: NSPasteboard, store: AttachmentStore) -> [Attachment] {
        if let urls = fileURLs(from: pasteboard), !urls.isEmpty {
            return urls.map { Attachment(url: $0, isTemporary: false) }
        }
        if let image = imageAttachment(from: pasteboard, store: store) {
            return [image]
        }
        return []
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    private static func imageAttachment(from pasteboard: NSPasteboard, store: AttachmentStore) -> Attachment? {
        // A screenshot taken with Cmd-Shift-4 lands as PNG already; using those
        // bytes directly avoids a decode and re-encode that can only lose data.
        if let png = pasteboard.data(forType: .png) {
            return write(png, extension: "png", prefix: "paste", store: store)
        }

        // Anything else image-shaped gets normalised to PNG so the extension
        // always describes the contents.
        guard let tiff = pasteboard.data(forType: .tiff),
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:])
        else { return nil }

        return write(png, extension: "png", prefix: "paste", store: store)
    }

    private static func write(
        _ data: Data,
        extension pathExtension: String,
        prefix: String,
        store: AttachmentStore
    ) -> Attachment? {
        guard let url = try? store.store(data, extension: pathExtension, prefix: prefix) else { return nil }
        return Attachment(url: url, isTemporary: true)
    }
}
