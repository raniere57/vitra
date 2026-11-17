import Foundation
import Testing
@testable import VitraOrchestrator

private func scratchFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("vitra-providers-\(UUID().uuidString)/providers.json")
}

@Test func switchesSurviveARoundTripThroughTheFile() throws {
    let url = scratchFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try ProviderSwitches(off: [.cursor, .gemini]).save(to: url)

    let loaded = ProviderSwitches.load(from: url)
    #expect(loaded.off == [.gemini, .cursor])
    #expect(!loaded.isOn(.cursor) && loaded.isOn(.claude))
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"version\" : 1"))
}

@Test func aMissingBrokenOtherVersionOrAllOffFileMeansEveryCLIIsOn() throws {
    let url = scratchFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(ProviderSwitches.load(from: url) == .allOn)

    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    for body in [
        "{ not json",
        #"{"version": 2, "off": ["cursor"]}"#,
        #"{"version": 1, "off": ["claude", "opencode", "gemini", "cursor"]}"#,
    ] {
        try Data(body.utf8).write(to: url)
        // A new date each time, so the cache reads the file again.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(body.count))], ofItemAtPath: url.path)
        #expect(ProviderSwitches.load(from: url) == .allOn, "\(body)")
    }
}

@Test func switchingOffTheLastInstalledCLIThatIsOnIsRefused() throws {
    let installed: Set<WorkerCLI> = [.claude, .cursor]
    let one = try ProviderSwitches.allOn.setting(.cursor, on: false, installed: installed)
    #expect(one.off == [.cursor])

    #expect(throws: ProviderSwitches.Refusal.lastOne(.claude)) {
        try one.setting(.claude, on: false, installed: installed)
    }
    // A CLI that is not installed can always be switched, either way.
    let gemini = try one.setting(.gemini, on: false, installed: installed)
    #expect(gemini.off == [.gemini, .cursor])
    #expect(try gemini.setting(.cursor, on: true, installed: installed).off == [.gemini])
    #expect(ProviderSwitches.Refusal.lastOne(.claude).text.contains("último"))
}

// MARK: - The picker

private let grok = ModelCatalog.Offer(cli: .cursor, model: "cursor-grok-4.6-low-fast", effort: nil)
private let haiku = ModelCatalog.Offer(cli: .claude, model: "haiku", effort: "low")
private let lineup = Lineup(hard: [], normal: [grok, haiku], easy: [])

private func pick(off: Set<WorkerCLI>, offers: [ModelCatalog.Offer] = [grok, haiku]) -> WorkerPicker.Choice? {
    WorkerPicker.pick(
        kind: .implement, access: .edit, needsCommands: false, history: [], offers: offers,
        installed: [.claude, .cursor], lineup: lineup, switchedOff: off
    )
}

@Test func thePickerPassesASwitchedOffCLIAndSaysSo() throws {
    #expect(pick(off: [])?.offer == grok)

    let choice = try #require(pick(off: [.cursor]))
    #expect(choice.offer == haiku)
    #expect(choice.reason == "2nd in your lineup: cursor is switched off")
    #expect(choice.pick.cause == .switchedOff)
}

@Test func aSwitchedOffCLIIsNeverPickedEvenWhenNobodyElseMayRun() {
    #expect(pick(off: [.claude], offers: [haiku]) == nil)
    // Nor from outside the lineup.
    let outside = ModelCatalog.Offer(cli: .cursor, model: "grok-4.7-low-fast", effort: nil)
    #expect(pick(off: [.cursor], offers: [outside, haiku])?.offer == haiku)
}
