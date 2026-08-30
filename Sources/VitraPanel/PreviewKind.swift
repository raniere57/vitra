import Foundation
import UniformTypeIdentifiers
import VitraCore

/// Which engine renders a file.
///
/// Chosen from the file's type, not its extension text, so `screenshot` with no
/// extension still opens as an image when the bytes say it is one.
public enum PreviewKind: Sendable, Equatable {
    case image
    case pdf
    case web
    case text
    case unsupported

    public init(for url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension)
            ?? (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        else {
            self = Self.looksLikeText(url) ? .text : .unsupported
            return
        }

        // SVG before the image check: it is an image type, but NSImageView
        // rasterises it unreliably and WebKit draws it properly.
        if type.conforms(to: .svg) || type.conforms(to: .html) || type.conforms(to: .xml) {
            self = .web
        } else if type.conforms(to: .pdf) {
            self = .pdf
        } else if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .text) || type.conforms(to: .sourceCode) {
            self = .text
        } else {
            self = Self.looksLikeText(url) ? .text : .unsupported
        }
    }

    /// Sniffs the first few kilobytes for a NUL byte, the usual tell that a file
    /// is binary. Cheap, and it rescues extensionless logs and dotfiles.
    private static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), !head.isEmpty else { return false }
        return !head.contains(0) && String(data: head, encoding: .utf8) != nil
    }
}
