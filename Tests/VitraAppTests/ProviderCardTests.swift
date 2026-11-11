import Foundation
import Testing
@testable import VitraApp
import VitraOrchestrator

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 16:05 UTC on some day.
private let later = Date(timeIntervalSince1970: 1_794_412_800 + 5 * 60)

private func card(
    _ cli: WorkerCLI = .cursor, path: String? = "/usr/local/bin/x", lines: [String]? = ["grok-4.7-low-fast - Grok"],
    availability: Availability = .ok, deliveries: Int = 2, lineup: Lineup = .standard, isOn: Bool = true
) -> ProviderCard {
    ProviderBoard.card(cli, path: path, lines: lines, availability: availability, deliveriesToday: deliveries, lineup: lineup, isOn: isOn)
}

@Test func everyCLIHasItsLoginCommandAndAnInstallHint() {
    let logins = WorkerCLI.allCases.map(ProviderBoard.login)
    #expect(logins == ["claude /login", "opencode auth login", "agy auth login", "cursor-agent login"])
    for cli in WorkerCLI.allCases {
        #expect(!ProviderBoard.install(cli).hint.isEmpty)
    }
    #expect(ProviderBoard.install(.cursor).command == "curl https://cursor.com/install -fsS | bash")
    #expect(ProviderBoard.install(.gemini).command == nil)
}

@Test func aCardSaysWhyItsProviderCanOrCannotWork() {
    let ok = card()
    #expect(ok.state == .ok && ok.signedIn == true && ok.command == nil)
    #expect(ok.statusText(calendar: utc) == "ok")

    let quota = card(availability: .noQuota(until: later))
    #expect(quota.state == .noQuota(until: later))
    #expect(quota.statusText(calendar: utc) == "sem cota · volta ~16:05")

    let down = card(availability: .down(until: later))
    #expect(down.statusText(calendar: utc) == "fora do ar · volta ~16:05")

    let resting = card(availability: .resting(until: later, workers: ["grok"]))
    #expect(resting.statusText(calendar: utc) == "descansando até 16:05 após 3 falhas")

    let missing = card(path: nil, lines: nil)
    #expect(missing.state == .notInstalled && missing.signedIn == nil && missing.detailText == nil)
    #expect(missing.statusText(calendar: utc) == "não instalado")
    #expect(missing.command == ProviderBoard.install(.cursor).command)
}

@Test func anEmptyListingOrASignInFailureMeansSignedOutWithTheLoginCommand() {
    let listedNothing = card(lines: [], availability: .noQuota(until: later))
    #expect(listedNothing.state == .signedOut && listedNothing.signedIn == false)
    #expect(listedNothing.models == nil)
    #expect(listedNothing.statusText(calendar: utc) == "deslogado — rode `cursor-agent login` no terminal")
    #expect(listedNothing.command == "cursor-agent login")

    let byRuns = card(.claude, lines: [], availability: .signedOut)
    #expect(byRuns.state == .signedOut && byRuns.command == "claude /login")
    // Claude lists nothing by design: that alone is no sign-out.
    #expect(card(.claude, lines: []).state == .ok)
    // Not yet listed: unknown, and no models to count.
    let unknown = card(lines: nil)
    #expect(unknown.signedIn == nil && unknown.models == nil && unknown.state == .ok)
}

@Test func aCardCountsItsModelsTheLineupAndTodaysDeliveries() {
    let lines = ["opencode/glm-5.3-flash-free", "opencode/big-pickle", "opencode/deepseek-v4.1-flash-free"]
    let opencode = card(.opencode, path: NSHomeDirectory() + "/.opencode/bin/opencode", lines: lines, deliveries: 1)
    #expect(opencode.models?.map(\.model) == ["opencode/glm-5.3-flash-free", "opencode/deepseek-v4.1-flash-free"])
    #expect(opencode.tiers[ModelCatalog.Offer(cli: .opencode, model: "opencode/glm-5.3-flash-free", effort: nil)] == [.normal, .easy])
    #expect(opencode.inLineup == 2)
    #expect(opencode.detailText == "~/.opencode/bin/opencode · 2 modelos · 2 na escalação · 1 entrega hoje")
}

@Test func aCollapsedRowSaysLittleAndSwitchedOffWins() {
    #expect(ProviderBoard.rowStatus(.ok, card: nil, calendar: utc) == "ok")
    #expect(ProviderBoard.rowStatus(.ok, card: card(lines: []), calendar: utc) == "deslogado")
    #expect(ProviderBoard.rowStatus(.ok, card: card(path: nil), calendar: utc) == "não instalado")
    #expect(ProviderBoard.rowStatus(.noQuota(until: later), card: card(isOn: false), calendar: utc) == "desligado")
}
