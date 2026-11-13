import Foundation

/// Which pages a project's browser had open, kept so a restart of the app —
/// an update, a crash — brings them back instead of a blank panel. The
/// maestro's terminal outlives the app; its browser used to not.
///
/// Only the address of each tab is kept: what was typed into a form, or how
/// far a video had played, lives in the page's process and goes with it.
enum BrowserPages {
    struct Saved: Codable, Equatable {
        /// Tab id → address.
        var pages: [String: String]
        var current: String?
    }

    private static func key(_ project: String) -> String { "browserPages." + CockpitProject(path: project).path }

    static func load(project: String, defaults: UserDefaults = .standard) -> Saved? {
        defaults.data(forKey: key(project)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    /// Saves `saved`; no pages, nothing kept.
    static func save(_ saved: Saved, project: String, defaults: UserDefaults = .standard) {
        guard !saved.pages.isEmpty, let data = try? JSONEncoder().encode(saved) else {
            return defaults.removeObject(forKey: key(project))
        }
        defaults.set(data, forKey: key(project))
    }
}
