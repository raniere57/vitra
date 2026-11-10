import Foundation
import Testing
@testable import VitraApp

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Test func everyAgentHasATabOfItsOwnAndTheMaestroIsWhoeverGivesNoName() {
    var tabs = BrowserTabs()
    let opened = [
        tabs.use(BrowserTabs.id(forAgent: nil), now: t0),
        tabs.use(BrowserTabs.id(forAgent: "ab12cd34"), now: t0),
        // The same agent again is the same tab, not a second one.
        tabs.use(BrowserTabs.id(forAgent: ""), now: t0),
        tabs.use("ab12cd34", now: t0),
    ]
    #expect(opened == [true, true, false, false])
    #expect(tabs.tabs.map(\.id) == ["maestro", "ab12cd34"])
}

@Test func aNewTabComesToTheFrontButATabAlreadyOpenLeavesTheUsersViewAlone() {
    var tabs = BrowserTabs()
    _ = tabs.use("maestro", now: t0)
    let mine = tabs.openUsers(now: t0)
    #expect(mine == "você")
    #expect(tabs.current == "você")
    // The maestro clicks something in its tab while the user reads theirs.
    _ = tabs.use("maestro", now: t0)
    #expect(tabs.current == "você")
    let second = tabs.openUsers(now: t0)
    #expect(second == "você 2")
}

@Test func aTabNobodyTouchedForHalfAnHourIsDueToClose() {
    var tabs = BrowserTabs()
    _ = tabs.use("maestro", now: t0)
    _ = tabs.use("ab12cd34", now: t0)
    tabs.touch("maestro", now: t0.addingTimeInterval(20 * 60))
    #expect(tabs.idle(now: t0.addingTimeInterval(29 * 60)).isEmpty)
    #expect(tabs.idle(now: t0.addingTimeInterval(31 * 60)) == ["ab12cd34"])
    #expect(tabs.idle(now: t0.addingTimeInterval(51 * 60)) == ["maestro", "ab12cd34"])
}

@Test func aWorkersTabGoesWhenTheWorkerIsDoneAndNobodyElsesDoes() {
    var tabs = BrowserTabs()
    for id in ["maestro", "aaaa1111", "bbbb2222", "você"] { _ = tabs.use(id, now: t0) }
    // aaaa1111 finished, bbbb2222 is running; a run not listed is not known
    // to be over, and the maestro and the user are not runs at all.
    #expect(tabs.finished(isRunning: ["aaaa1111": false, "bbbb2222": true, "maestro": false]) == ["aaaa1111"])
}

@Test func closingTheTabInFrontShowsItsNeighbourAndClosingTheLastShowsNone() {
    var tabs = BrowserTabs()
    for id in ["maestro", "aaaa1111", "você"] { _ = tabs.use(id, now: t0) }
    tabs.show("aaaa1111")
    tabs.close("aaaa1111")
    #expect(tabs.current == "maestro")
    tabs.close("você")
    #expect(tabs.current == "maestro")
    tabs.close("maestro")
    #expect(tabs.current == nil)
    #expect(tabs.tabs.isEmpty)
}

@Test func aTabIsNamedForWhoOwnsIt() {
    #expect(BrowserTabs.label("maestro", runTitle: nil) == "maestro")
    #expect(BrowserTabs.label("você 2", runTitle: nil) == "você 2")
    #expect(BrowserTabs.label("ab12cd34", runTitle: "Diário: alinhar calendário") == "Diário: alinhar calendário")
    #expect(BrowserTabs.label("ab12cd34", runTitle: nil) == "operário ab12cd34")
}

// MARK: - Handing the browser to the other CLIs

@Test func vitrasServerIsAddedToACLIsSettingsWithoutDisturbingWhatIsThere() throws {
    let existing = Data(#"{"mcpServers":{"bitrix":{"url":"https://x"}},"theme":"dark"}"#.utf8)
    let merged = try #require(WorkerBrowser.merged(binary: "/Applications/Vitra.app/Contents/MacOS/Vitra", trust: true, into: existing))
    let object = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
    #expect(object["theme"] as? String == "dark")
    let servers = try #require(object["mcpServers"] as? [String: Any])
    #expect(servers["bitrix"] != nil)
    let vitra = try #require(servers["vitra"] as? [String: Any])
    #expect(vitra["command"] as? String == "/Applications/Vitra.app/Contents/MacOS/Vitra")
    #expect(vitra["args"] as? [String] == ["mcp"])
    #expect(vitra["trust"] as? Bool == true)

    // Already there and the same: nothing to write.
    #expect(WorkerBrowser.merged(binary: "/Applications/Vitra.app/Contents/MacOS/Vitra", trust: true, into: merged) == nil)
    // No file yet: one is made.
    #expect(WorkerBrowser.merged(binary: "/v", trust: false, into: nil) != nil)
    // A file with the key twice means different things to different parsers:
    // rewriting it would silently drop a server the CLI was using.
    let twice = Data(#"{"mcpServers":{"a":{"url":"x"}},"mcpServers":{"b":{"url":"y"}}}"#.utf8)
    #expect(WorkerBrowser.merged(binary: "/v", trust: false, into: twice) == nil)
    // A file that is not plain JSON is the user's to sort out, not ours to overwrite.
    #expect(WorkerBrowser.merged(binary: "/v", trust: false, into: Data("{ // comment\n}".utf8)) == nil)
}

@Test func agyIsLetCallVitrasToolsAndNothingElseItHadIsTouched() throws {
    let existing = Data(#"{"permissions":{"allow":["command(git status)"]},"model":"x"}"#.utf8)
    let updated = try #require(WorkerBrowser.allowingVitra(in: existing))
    let object = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
    #expect(object["model"] as? String == "x")
    #expect((object["permissions"] as? [String: Any])?["allow"] as? [String] == ["command(git status)", "mcp(vitra/*)"])
    // Already allowed: nothing to write.
    #expect(WorkerBrowser.allowingVitra(in: updated) == nil)
    #expect(WorkerBrowser.allowingVitra(in: nil) != nil)
    #expect(WorkerBrowser.allowingVitra(in: Data("{ broken".utf8)) == nil)
}
