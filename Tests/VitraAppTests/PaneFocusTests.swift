import AppKit
import Metal
import Testing
@testable import VitraApp

@Test @MainActor func sidebarFocusKeepsTheSelectedTerminal() throws {
    _ = NSApplication.shared
    let device = try #require(MTLCreateSystemDefaultDevice())
    let controller = try TerminalWindowController(device: device, fontName: "Menlo", fontSize: 13)
    defer { controller.close() }
    let first = try #require(controller.focusedPane)
    let second = try #require(controller.splitFocusedPane(vertical: true))
    let window = try #require(controller.window)
    #expect(window.makeFirstResponder(first))
    #expect(window.makeFirstResponder(nil))
    #expect(controller.focusedPane === first)
    #expect(controller.focusedPane !== second)
    controller.close(first)
    #expect(controller.focusedPane === second)
}

@Test @MainActor func closedPaneRestoresDirectoryAndSession() throws {
    _ = NSApplication.shared
    let device = try #require(MTLCreateSystemDefaultDevice())
    let controller = try TerminalWindowController(device: device, fontName: "Menlo", fontSize: 13)
    defer { controller.close() }
    let original = try #require(controller.focusedPane)
    original.agentSession = "test-session"
    original.agentHarness = .codex
    let saved = try #require(controller.focusedPaneLayout())
    #expect(saved.session == "test-session")
    #expect(saved.harness == "codex")
    #expect(saved.directory != nil)
    _ = try #require(controller.splitFocusedPane(vertical: true))
    controller.close(original)
    #expect(controller.reopen(saved))
    let restored = try #require(controller.focusedPane)
    #expect(restored !== original)
    #expect(restored.agentSession == saved.session)
    #expect(restored.agentHarness == .codex)
    #expect(controller.focusedPaneLayout()?.directory == saved.directory)
    let fileMenu = try #require(MainMenu.build().items.first { $0.submenu?.title == "File" }?.submenu)
    let item = try #require(fileMenu.items.first { $0.action == #selector(AppDelegate.reopenClosedPane(_:)) })
    #expect(item.keyEquivalent == "t")
    #expect(item.keyEquivalentModifierMask == [.command, .shift])
}
