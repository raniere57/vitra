import AppKit
import VitraCore

/// The application menu.
///
/// Built in code rather than a nib: a nib is one more file format, one more
/// build step, and one more thing to keep in sync with the code that uses it.
enum MainMenu {
    static func build(
        keybindings: [String: String] = Config.defaultKeybindings,
        bookmarks: [Bookmark] = []
    ) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Vitra", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Vitra", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Vitra", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(AppDelegate.newWindowForTab(_:)), keyEquivalent: key("new_tab", keybindings))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Split Right", action: #selector(AppDelegate.splitHorizontally(_:)), keyEquivalent: key("split_right", keybindings))
        let splitDown = fileMenu.addItem(withTitle: "Split Down", action: #selector(AppDelegate.splitVertically(_:)), keyEquivalent: key("split_right", keybindings))
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Pane", action: #selector(AppDelegate.closePane(_:)), keyEquivalent: key("close_pane", keybindings))
        let closeWindow = fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: key("close_pane", keybindings))
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let folderMenuItem = NSMenuItem()
        let folderMenu = NSMenu(title: "Folders")
        folderMenu.addItem(withTitle: "Go to Folder…", action: #selector(AppDelegate.showFolderPalette(_:)), keyEquivalent: "p")
        let openFolder = folderMenu.addItem(
            withTitle: "New Tab in Folder…",
            action: #selector(AppDelegate.openFolderInNewTab(_:)),
            keyEquivalent: "o"
        )
        openFolder.keyEquivalentModifierMask = [.command, .shift]
        let addFolder = folderMenu.addItem(
            withTitle: "Add Current Folder",
            action: #selector(AppDelegate.addCurrentFolder(_:)),
            keyEquivalent: "d"
        )
        addFolder.keyEquivalentModifierMask = [.command, .control]

        if !bookmarks.isEmpty {
            folderMenu.addItem(.separator())
            for (index, bookmark) in bookmarks.enumerated() {
                // Cmd-Ctrl-1…9 for the first nine: Cmd-1 belongs to tab
                // switching, and a favourite is not worth stealing it for.
                let key = index < 9 ? String(index + 1) : ""
                let item = folderMenu.addItem(
                    withTitle: "\(bookmark.emoji)  \(bookmark.name)",
                    action: #selector(AppDelegate.openBookmarkTab(_:)),
                    keyEquivalent: key
                )
                item.keyEquivalentModifierMask = [.command, .control]
                item.representedObject = bookmark.id.uuidString
                item.toolTip = bookmark.displayPath
                item.isEnabled = true
            }
        }

        folderMenu.addItem(.separator())
        folderMenu.addItem(withTitle: "Manage Folders…", action: #selector(AppDelegate.showFolders(_:)), keyEquivalent: "")
        folderMenuItem.submenu = folderMenu
        mainMenu.addItem(folderMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Clear", action: #selector(TerminalView.clearScreen(_:)), keyEquivalent: key("clear", keybindings))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let togglePanel = viewMenu.addItem(
            withTitle: "Preview Panel",
            action: #selector(AppDelegate.togglePreviewPanel(_:)),
            keyEquivalent: key("preview_panel", keybindings)
        )
        togglePanel.keyEquivalentModifierMask = [.command, .shift]

        let toggleSidebar = viewMenu.addItem(
            withTitle: "Folders Sidebar",
            action: #selector(AppDelegate.toggleFolderSidebar(_:)),
            keyEquivalent: key("folder_sidebar", keybindings)
        )
        toggleSidebar.keyEquivalentModifierMask = [.command, .option]

        let toggleSessions = viewMenu.addItem(
            withTitle: "Claude Code Sessions",
            action: #selector(AppDelegate.toggleSessionsSidebar(_:)),
            keyEquivalent: key("sessions_sidebar", keybindings)
        )
        toggleSessions.keyEquivalentModifierMask = [.command, .option]
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        return mainMenu
    }

    /// The configured key for an action, or the default when it is missing.
    private static func key(_ action: String, _ keybindings: [String: String]) -> String {
        keybindings[action] ?? Config.defaultKeybindings[action] ?? ""
    }
}
