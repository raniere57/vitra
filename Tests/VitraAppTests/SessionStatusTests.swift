import Foundation
import Testing
@testable import VitraApp

@Test func aSessionSaysWhatItIsDoingAndOnlyWhatWaitsOnTheUserGoesUp() {
    typealias Tab = CockpitTabBar.Tab
    #expect(SessionStatus(Tab(name: "a", running: 2, callsForYou: true)) == .permission)
    #expect(SessionStatus(Tab(name: "a", running: 2, maestroWorking: true)) == .working)
    // The maestro ended its turn with workers going: not news yet.
    #expect(SessionStatus(Tab(name: "a", running: 2, finishedUnseen: true)) == .workers(2))
    #expect(SessionStatus(Tab(name: "a", running: 0, finishedUnseen: true)) == .finished)
    #expect(SessionStatus(Tab(name: "a", running: 0)) == .idle)
    #expect(SessionStatus(Tab(name: "a", running: 1, callsForYou: true, isAsleep: true)) == .asleep)
    #expect(SessionStatus.permission.isForYou && SessionStatus.finished.isForYou)
    #expect(!SessionStatus.workers(2).isForYou && !SessionStatus.working.isForYou && !SessionStatus.idle.isForYou)
    #expect(SessionStatus.workers(1).label == "1 operário")
}

@Test func anAgeIsShortAndSilentInTheFirstMinute() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func age(_ seconds: TimeInterval) -> String { SessionStatus.age(since: now.addingTimeInterval(-seconds), now: now) }
    #expect(age(59) == "")
    #expect(age(8 * 60 + 30) == "8m")
    #expect(age(3 * 3600 + 10) == "3h")
    #expect(age(49 * 3600) == "2d")
    #expect(SessionStatus.age(since: nil, now: now) == "")
}
