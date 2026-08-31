import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Saves a PNG of Vitra's own window when `VITRA_SELF_SHOT` names a path.
///
/// A process capturing its own window needs no screen-recording permission,
/// which makes this the only way to verify what the app actually puts on screen
/// from an automated run. Off unless the variable is set.
@MainActor
enum SelfCapture {
    static func scheduleIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT"] else { return }

        // A binary launched from a shell never becomes active on its own, and
        // without an active app there is no key window to send actions to.
        NSApp.activate(ignoringOtherApps: true)
        let delay = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_DELAY"].flatMap(Double.init) ?? 1.5

        // A PNG put on the clipboard before the actions fire, so an automated run
        // can exercise Cmd-V with an image the way pasting a screenshot does.
        if let image = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_PASTE_IMAGE"],
           let data = FileManager.default.contents(atPath: image) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
        }

        // Optional comma-separated selectors fired before the shot, so keyboard
        // shortcuts can be exercised from an automated run.
        if let actions = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_ACTIONS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 2) {
                for name in actions.split(separator: ",") {
                    // "menu:Folders/Vitra" fires a menu item by title, which is
                    // the only way to exercise a command whose sender carries
                    // the payload — a bookmark, say — rather than a bare
                    // selector.
                    if name.hasPrefix("menu:") {
                        let path = name.dropFirst(5).split(separator: "/").map(String.init)
                        let fired = fireMenuItem(path: path)
                        FileHandle.standardError.write(Data("[self-shot] \(name): \(fired ? "sent" : "NOT FOUND")\n".utf8))
                        continue
                    }
                    let selector = Selector(String(name))
                    // The responder chain only reaches anything when a key window
                    // exists, which it may not for a run launched from a shell, so
                    // the view and then the delegate are tried by hand.
                    var delivered = NSApp.sendAction(selector, to: nil, from: nil)
                    if !delivered, let responder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder,
                       responder.responds(to: selector) {
                        delivered = NSApp.sendAction(selector, to: responder, from: nil)
                    }
                    if !delivered, NSApp.delegate?.responds(to: selector) == true {
                        delivered = NSApp.sendAction(selector, to: NSApp.delegate, from: nil)
                    }
                    FileHandle.standardError.write(Data("[self-shot] \(name): \(delivered ? "sent" : "NOT DELIVERED")\n".utf8))
                }
            }
        }

        // Text typed into the focused pane before the shot, so terminal
        // behaviour — not just chrome — can be checked from an automated run.
        if let input = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_INPUT"] {
            let text = input.replacingOccurrences(of: "\\n", with: "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.4) {
                guard let pane = (NSApp.keyWindow?.firstResponder as? TerminalView)
                    ?? (NSApp.orderedWindows.first(where: { $0.isVisible })?.firstResponder as? TerminalView)
                else {
                    FileHandle.standardError.write(Data("[self-shot] no pane for input\n".utf8))
                    return
                }
                pane.session.send(text: text)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(to: path)
            if ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_QUIT"] != nil {
                NSApp.terminate(nil)
            }
        }
    }

    /// Finds a menu item by its title path and sends its action, with the item
    /// itself as the sender.
    private static func fireMenuItem(path: [String]) -> Bool {
        var menu = NSApp.mainMenu
        for (index, title) in path.enumerated() {
            // Top-level items carry no title of their own — the submenu does —
            // so both are matched.
            guard let item = menu?.items.first(where: {
                $0.title.contains(title) || $0.submenu?.title.contains(title) == true
            }) else { return false }
            if index == path.count - 1 {
                guard let action = item.action else { return false }
                return NSApp.sendAction(action, to: item.target, from: item)
            }
            menu = item.submenu
        }
        return false
    }

    private static func capture(to path: String) {
        // Prefer the key window: with native tabs, several windows are "visible"
        // but only the front tab is on screen.
        // Front to back: with the app in the background there is no key window,
        // and the frontmost visible one is what a person would be looking at.
        // VITRA_SELF_SHOT_WINDOW names the window to shoot, because a floating
        // panel never becomes key and would otherwise be unreachable from here.
        let wanted = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_WINDOW"]
        let candidate = wanted.flatMap { name in
            NSApp.orderedWindows.first { $0.isVisible && ($0.title.contains(name) || String(describing: type(of: $0)).contains(name)) }
        }
            ?? NSApp.keyWindow
            ?? NSApp.orderedWindows.first(where: { $0.isVisible })
            ?? NSApp.mainWindow
        guard let window = candidate else {
            FileHandle.standardError.write(Data("[self-shot] no visible window\n".utf8))
            return
        }

        let windowID = CGWindowID(window.windowNumber)
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            // Tabbed windows are composited by a container the app does not own,
            // so a child tab has no image of its own to capture.
            let tabs = window.tabGroup?.windows.count ?? 1
            FileHandle.standardError.write(Data(
                "[self-shot] capture failed (windows=\(NSApp.windows.count) tabs=\(tabs))\n".utf8
            ))
            return
        }

        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        FileHandle.standardError.write(Data("[self-shot] wrote \(image.width)x\(image.height) to \(path)\n".utf8))
    }
}
