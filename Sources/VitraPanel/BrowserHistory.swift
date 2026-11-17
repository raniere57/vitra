import Foundation

/// The pages the browser has been to, most recent first, so an address is
/// typed once and picked from then on.
///
/// One list for the whole app, kept in a small file: every project's browser
/// offers the same places.
public enum BrowserHistory {
    static let limit = 200

    public static var defaultFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".vitra/browser-history.json")
    }

    /// `entries` with `url` at the top. Only pages from the web: a local file
    /// or a blank page is not somewhere to return to by typing.
    static func adding(_ url: URL, to entries: [String]) -> [String] {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return entries }
        let entry = url.absoluteString
        return Array(([entry] + entries.filter { $0 != entry }).prefix(limit))
    }

    /// An entry as it would be typed: without the scheme and a bare trailing
    /// slash, wherever the address bar would put the same ones back.
    static func display(_ entry: String) -> String {
        guard let range = entry.range(of: "://") else { return entry }
        var short = String(entry[range.upperBound...])
        if short.hasSuffix("/"), !short.dropLast().contains("/") { short.removeLast() }
        let roundTrip = BrowserView.url(from: short)?.absoluteString
        return roundTrip == entry || roundTrip.map { $0 + "/" } == entry ? short : entry
    }

    static func load(from file: URL = defaultFile) -> [String] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Remembers a visit. A history that cannot be written is only a history
    /// that is not kept: the page still loaded.
    static func record(_ url: URL, in file: URL = defaultFile) {
        let entries = load(from: file)
        let updated = adding(url, to: entries)
        guard updated != entries, let data = try? JSONEncoder().encode(updated) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
