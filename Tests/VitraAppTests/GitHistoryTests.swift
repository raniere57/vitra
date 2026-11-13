import Foundation
import Testing
@testable import VitraApp

// The fixtures are what git 2.x and gh printed in a real repository.

@Test func aCommitLineBecomesACommitWithItsAuthorAndTime() {
    let log = "9711b7d\u{1f}Ana Lima\u{1f}1794093205\u{1f}feat: painel master\nbe7b915\u{1f}Ana Lima\u{1f}1794088877\u{1f}Merge branch 'x'\n"
    let events = GitHistory.commits(fromLog: log)
    #expect(events == [
        GitEvent(kind: .commit, title: "feat: painel master", detail: "9711b7d · Ana Lima", date: Date(timeIntervalSince1970: 1_794_093_205), url: nil),
        GitEvent(kind: .commit, title: "Merge branch 'x'", detail: "be7b915 · Ana Lima", date: Date(timeIntervalSince1970: 1_794_088_877), url: nil),
    ])
}

@Test func aPushIsReadFromTheRemoteBranchItMoved() {
    let reflog = "refs/remotes/origin/main@{1794274272}\u{1f}update by push\u{1f}a849cb0\u{1f}fix: acha a conversa\n"
    #expect(GitHistory.pushes(fromReflog: reflog) == [
        GitEvent(kind: .push, title: "push → origin/main", detail: "a849cb0 · fix: acha a conversa", date: Date(timeIntervalSince1970: 1_794_274_272), url: nil),
    ])
}

@Test func aPullRequestCarriesItsStateAndItsLink() {
    let json = Data("""
    [{"number":12,"title":"Busca por número","state":"MERGED","updatedAt":"2026-11-09T20:10:00Z","url":"https://github.com/o/r/pull/12","headRefName":"fix/busca"},
     {"number":13,"title":"Tema","state":"OPEN","updatedAt":"2026-11-09T21:00:00Z","url":"https://github.com/o/r/pull/13","headRefName":"tema"}]
    """.utf8)
    let events = GitHistory.pullRequests(fromJSON: json)
    #expect(events.map(\.title) == ["PR #12 · Busca por número", "PR #13 · Tema"])
    #expect(events.map(\.detail) == ["mesclado · fix/busca", "aberto · tema"])
    #expect(events[0].url == "https://github.com/o/r/pull/12")
    #expect(events[0].kind == .pullRequest)
}

@Test func linesThatAreNotWhatGitPrintsAreLeftOut() {
    // A subject may hold anything; a line with fields missing is not an event.
    #expect(GitHistory.commits(fromLog: "garbage\n\nabc\u{1f}x\u{1f}not-a-time\u{1f}s\n").isEmpty)
    #expect(GitHistory.pushes(fromReflog: "refs/remotes/origin/main\u{1f}update by push\u{1f}a\u{1f}s\n").isEmpty)
    #expect(GitHistory.pullRequests(fromJSON: Data("gh: not logged in".utf8)).isEmpty)
}

@Test func everythingIsShownAsOneTimelineNewestFirst() {
    let at = { (seconds: TimeInterval, kind: GitEvent.Kind) in
        GitEvent(kind: kind, title: "\(seconds)", detail: "", date: Date(timeIntervalSince1970: seconds), url: nil)
    }
    let timeline = GitHistory.timeline([at(10, .commit), at(30, .commit)], [at(20, .push)], [at(40, .pullRequest)])
    #expect(timeline.map(\.title) == ["40.0", "30.0", "20.0", "10.0"])
}

@Test func everyEventSaysItsDateAndHourAndHowLongAgoThatWas() {
    // A history without when is not a history: the date and hour come first,
    // where no long commit subject can push them out of sight.
    let utc = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_794_274_272)
    let stamp = GitHistory.stamp(now.addingTimeInterval(-3 * 3600), now: now, timeZone: utc)
    #expect(stamp == "09/11 22:31 · há 3 h")
    // Last year's says which year.
    #expect(GitHistory.stamp(now.addingTimeInterval(-400 * 86400), now: now, timeZone: utc).hasPrefix("06/10/2025 01:31"))
}
