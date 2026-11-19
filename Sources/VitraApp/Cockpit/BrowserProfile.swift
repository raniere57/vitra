import CryptoKit
import Foundation

/// Projects share one browser profile — the logins made once, Google and the
/// rest, are everywhere — unless one is given its own: cookies and logins
/// apart, so it can be on another Instagram account than the rest. History
/// stays the app's. Every session of a folder shares its profile.
enum BrowserProfile {
    private static let ownKey = "vitra.browser.ownProfiles"

    /// The profile `path`'s browser uses: its own, or nil for the shared one.
    static func profile(for path: String, defaults: UserDefaults = .standard) -> UUID? {
        isOwn(path, defaults: defaults) ? id(for: path) : nil
    }

    static func isOwn(_ path: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.stringArray(forKey: ownKey)?.contains(path) == true
    }

    static func setOwn(_ own: Bool, for path: String, defaults: UserDefaults = .standard) {
        var paths = Set(defaults.stringArray(forKey: ownKey) ?? [])
        if own { paths.insert(path) } else { paths.remove(path) }
        defaults.set(paths.sorted(), forKey: ownKey)
    }

    /// The same id for the same folder, launch after launch.
    static func id(for path: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("vitra-browser:" + path).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // a name-based UUID
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
