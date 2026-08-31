import Foundation
import Testing
@testable import VitraCore

@Suite("Layout")
struct LayoutTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vitra-layout-\(UUID().uuidString).json")
    }

    private var tree: Layout.Node {
        .split(
            vertical: true,
            fractions: [0.6, 0.4],
            children: [
                .pane(Layout.Pane(directory: "/Users/x/vitra", session: "abc")),
                .split(
                    vertical: false,
                    fractions: [0.5, 0.5],
                    children: [
                        .pane(Layout.Pane(directory: "/Users/x/farol")),
                        .pane(Layout.Pane()),
                    ]
                ),
            ]
        )
    }

    @Test func aNestedLayoutSurvivesTheRoundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let layout = Layout(windows: [
            Layout.Window(
                directory: "/Users/x/vitra",
                frame: Layout.Frame(x: 10, y: 20, width: 1200, height: 800),
                sidebar: Layout.Sidebar(expanded: true, mode: "sessions", width: 260),
                tabGroup: 0,
                root: tree
            ),
        ])
        try layout.save(to: url)

        #expect(Layout.load(from: url) == layout)
    }

    @Test func everyPaneOfTheTreeIsFound() {
        let panes = tree.panes
        #expect(panes.count == 3)
        #expect(panes.first?.session == "abc")
        #expect(panes.map(\.directory) == ["/Users/x/vitra", "/Users/x/farol", nil])
    }

    @Test func nothingSavedMeansNothingToRestore() {
        let url = temporaryURL()
        #expect(Layout.load(from: url) == nil)

        // An empty window list is the same as no layout: restoring it would open
        // a window with nothing in it.
        try? Layout(windows: []).save(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Layout.load(from: url) == nil)
    }

    @Test func aCorruptFileIsNotAnError() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ not json".utf8).write(to: url)
        #expect(Layout.load(from: url) == nil)
    }
}
