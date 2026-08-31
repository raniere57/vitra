import Foundation

/// One entry of a directory: what it is called and whether you can enter it.
public struct DirectoryEntry: Sendable, Equatable, Identifiable {
    public let url: URL
    public let isDirectory: Bool

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

/// Reads a directory for the sidebars.
///
/// Sorted the way a file browser sorts — folders first, then names the way a
/// person reads them, so `item2` comes before `item10`.
public enum DirectoryListing {
    public static func entries(of directory: URL, includeHidden: Bool = false) -> [DirectoryEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: options
        ) else { return [] }

        return urls
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return DirectoryEntry(url: url, isDirectory: isDirectory)
            }
            .sorted(by: precedes)
    }

    /// Only the directories, for the tree on the left.
    public static func directories(of directory: URL, includeHidden: Bool = false) -> [DirectoryEntry] {
        entries(of: directory, includeHidden: includeHidden).filter(\.isDirectory)
    }

    private static func precedes(_ lhs: DirectoryEntry, _ rhs: DirectoryEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
