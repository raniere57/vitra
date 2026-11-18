import Foundation

/// What a session is doing, in the word the sidebar gives it.
enum SessionStatus: Equatable {
    case asleep
    /// The maestro stopped and asks: a permission, a question.
    case permission
    /// A turn ended that the user has not looked at.
    case finished
    case working
    /// The maestro ended its turn and its workers are still going.
    case workers(Int)
    case idle

    init(_ tab: CockpitTabBar.Tab) {
        if tab.isAsleep { self = .asleep }
        else if tab.callsForYou { self = .permission }
        else if tab.maestroWorking { self = .working }
        else if tab.running > 0 { self = .workers(tab.running) }
        else if tab.finishedUnseen { self = .finished }
        else { self = .idle }
    }

    /// Whether the session waits on the user: those go to the top of the sidebar.
    var isForYou: Bool { self == .permission || self == .finished }

    var label: String {
        switch self {
        case .asleep: "suspensa"
        case .permission: "pede você"
        case .finished: "terminou"
        case .working: "rodando"
        case let .workers(count): count == 1 ? "1 operário" : "\(count) operários"
        case .idle: "parada"
        }
    }

    /// How long a session has been as it is: "8m", "3h", "2d". Nothing in
    /// the first minute, when the word alone says it.
    static func age(since: Date?, now: Date) -> String {
        guard let since else { return "" }
        let minutes = Int(now.timeIntervalSince(since)) / 60
        switch minutes {
        case ..<1: return ""
        case ..<60: return "\(minutes)m"
        case ..<(24 * 60): return "\(minutes / 60)h"
        default: return "\(minutes / (24 * 60))d"
        }
    }
}
