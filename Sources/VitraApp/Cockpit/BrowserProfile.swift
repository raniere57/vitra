import CryptoKit
import Foundation

/// Each project's browser is a profile of its own: cookies and logins apart,
/// so a session on Instagram in one project is not the account another uses.
/// Every session of a folder shares its profile.
enum BrowserProfile {
    /// The same id for the same folder, launch after launch.
    static func id(for path: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("vitra-browser:" + path).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // a name-based UUID
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
