import Foundation

/// The tabs of a project's browser, and whose each one is.
///
/// Every agent drives a tab of its own — the maestro one, each worker one,
/// the user as many as they open — so no agent's clicks land on another's
/// page. Looking is open to all; that is decided where the tools are run.
struct BrowserTabs {
    struct Tab: Equatable {
        let id: String
        var lastUsed: Date
    }

    /// How long a tab may sit untouched before it is closed: each one is a
    /// WebKit process, and this is a machine with little memory to spare.
    static let idleLimit: TimeInterval = 30 * 60
    static let maestro = "maestro"
    private static let users = "você"

    private(set) var tabs: [Tab] = []
    /// The tab on screen.
    private(set) var current: String?

    /// The tab of the agent calling: its run id for a worker, and the
    /// maestro's for a call that names nobody.
    static func id(forAgent agent: String?) -> String {
        agent.flatMap { $0.isEmpty ? nil : $0 } ?? maestro
    }

    static func isUsers(_ id: String) -> Bool { id.hasPrefix(users) }

    /// What the tab is called on screen.
    static func label(_ id: String, runTitle: String?) -> String {
        if id == maestro || isUsers(id) { return id }
        return runTitle ?? "operário \(id)"
    }

    func contains(_ id: String) -> Bool { tabs.contains { $0.id == id } }

    /// Notes that `id` was used, opening it if it was not. True when it is
    /// new — and only a new tab comes to the front: an agent working away in
    /// a tab already open must not pull the user off the one they are reading.
    mutating func use(_ id: String, now: Date) -> Bool {
        if contains(id) {
            touch(id, now: now)
            return false
        }
        tabs.append(Tab(id: id, lastUsed: now))
        current = id
        return true
    }

    mutating func touch(_ id: String, now: Date) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].lastUsed = now
    }

    mutating func show(_ id: String) {
        if contains(id) { current = id }
    }

    /// Opens a tab for the user and returns its id.
    mutating func openUsers(now: Date) -> String {
        let taken = Set(tabs.map(\.id))
        let id = ([Self.users] + (2...99).map { "\(Self.users) \($0)" }).first { !taken.contains($0) } ?? Self.users
        _ = use(id, now: now)
        current = id
        return id
    }

    /// Closes a tab. When it was the one in front, its neighbour takes over.
    mutating func close(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        guard current == id else { return }
        current = tabs.isEmpty ? nil : tabs[max(0, index - 1)].id
    }

    /// The tabs nobody has touched for longer than the limit.
    func idle(now: Date) -> [String] {
        tabs.filter { now.timeIntervalSince($0.lastUsed) > Self.idleLimit }.map(\.id)
    }

    /// The tabs of workers that are done, given which runs are still going.
    func finished(isRunning: [String: Bool]) -> [String] {
        tabs.map(\.id).filter { $0 != Self.maestro && !Self.isUsers($0) && isRunning[$0] == false }
    }
}
