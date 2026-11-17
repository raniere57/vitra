import Foundation
import Testing
@testable import VitraApp

/// What the first-run guide and the panel chords remember between launches.
struct FirstRunHintTests {
    @Test func hintIsRememberedOnceDismissed() throws {
        let suite = "vitra-hint-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!FirstRunHint(defaults: defaults).isDismissed)
        FirstRunHint(defaults: defaults).dismiss()
        #expect(FirstRunHint(defaults: defaults).isDismissed)
    }

    @Test func sidePanelHiddenIsSavedPerProject() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let state = CockpitState(projects: [
            CockpitProject(path: "/tmp/a", sidePanelHidden: true),
            CockpitProject(path: "/tmp/b"),
        ])
        try state.save(to: url)
        #expect(CockpitState.load(from: url).projects.map(\.sidePanelHidden) == [true, false])
    }

    @Test func olderFilesOpenWithThePanelShown() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"projects":[{"path":"/tmp/a","mode":"solo"}],"selected":0}"#.utf8).write(to: url)
        #expect(CockpitState.load(from: url).projects.first?.sidePanelHidden == false)
    }
}
