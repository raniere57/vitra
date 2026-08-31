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
                    // "close" presses the window's own close button, which is
                    // the path a menu item cannot reach: it asks the delegate
                    // first, and the delegate is what decides tab or app.
                    if name == "close" {
                        let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible })
                        window?.performClose(nil)
                        let left = NSApp.windows.filter(\.isVisible).count
                        FileHandle.standardError.write(Data("[self-shot] close: \(left) visible after\n".utf8))
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

        // Keystrokes sent to whatever holds the keyboard, so chrome that only
        // reacts to typing — the sidebar's filter field — can be checked too.
        // Named keys, as "shift+116" — the only way to reach Page Up and the
        // other keys that carry no character.
        if let chord = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_CHORD"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.7) {
                let parts = chord.split(separator: "+")
                guard let code = parts.last.flatMap({ UInt16($0) }) else { return }
                var flags: NSEvent.ModifierFlags = []
                if parts.contains("shift") { flags.insert(.shift) }
                if parts.contains("command") { flags.insert(.command) }
                if parts.contains("option") { flags.insert(.option) }
                if parts.contains("control") { flags.insert(.control) }
                guard let event = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                    context: nil,
                    characters: "",
                    charactersIgnoringModifiers: "",
                    isARepeat: false,
                    keyCode: code
                ) else { return }
                let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible })
                (window?.firstResponder as? TerminalView)?.keyDown(with: event)
            }
        }

        if let keys = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_KEYS"] {
            // One key every 150ms rather than a burst inside one runloop turn:
            // a person types with gaps, and a frame that only ever lands after
            // the last key would hide exactly the bug this measures.
            let gap = 0.15
            for (index, character) in keys.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.5 + Double(index) * gap) {
                    let text = String(character)
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                        context: nil,
                        characters: text,
                        charactersIgnoringModifiers: text,
                        isARepeat: false,
                        // Space carries its real code: the input context sees a
                        // key, not only the text it produced.
                        keyCode: character == " " ? 49 : 0
                    ) else { return }
                    let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible })
                    // The pane is handed the key directly, because a synthetic
                    // event does not survive AppKit's routing; anything else
                    // that has the keyboard - a search field - is reached the
                    // ordinary way.
                    if let pane = window?.firstResponder as? TerminalView {
                        pane.keyDown(with: event)
                    } else {
                        NSApp.sendEvent(event)
                    }
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

        // A second round of typing, once whatever the first round started has
        // had time to come up: a TUI cannot be typed into before it exists.
        if let input = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_INPUT_LATE"] {
            let text = input.replacingOccurrences(of: "\\n", with: "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.9) {
                let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible })
                (window?.firstResponder as? TerminalView)?.session.send(text: text)
            }
        }

        // A click at a point in the window, so behaviour that only a pointer can
        // reach - a link in the grid - can be checked from an automated run.
        if let point = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_CLICK"] {
            let parts = point.split(separator: ",").compactMap { Double($0) }
            if parts.count >= 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.75) {
                    guard let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible })
                    else { return }
                    let modifiers: NSEvent.ModifierFlags =
                        ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_CLICK_COMMAND"] != nil ? [.command] : []
                    let location = NSPoint(x: parts[0], y: parts[1])
                    // Handed to the view rather than the window: a synthetic
                    // event has no real hit-testing behind it, and the pane is
                    // the only thing a click in the grid can mean.
                    let pane = window.contentView?.hitTest(location) as? TerminalView
                        ?? (window.firstResponder as? TerminalView)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        guard let event = NSEvent.mouseEvent(
                            with: type,
                            location: location,
                            modifierFlags: modifiers,
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber,
                            context: nil,
                            eventNumber: 0,
                            clickCount: 1,
                            pressure: type == .leftMouseDown ? 1 : 0
                        ) else { continue }
                        if let pane {
                            if type == .leftMouseDown { pane.mouseDown(with: event) } else { pane.mouseUp(with: event) }
                        } else {
                            window.sendEvent(event)
                        }
                    }
                    FileHandle.standardError.write(Data("[self-shot] clicked \(location)\n".utf8))
                }
            }
        }

        // Scrollback moved before the shot: a wheel gesture cannot be faked from
        // a headless run, and scrolling is the one behaviour a screenshot of the
        // live screen can never show.
        if let lines = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_SCROLL"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.8) {
                guard let pane = (NSApp.keyWindow?.firstResponder as? TerminalView)
                    ?? (NSApp.orderedWindows.first(where: { $0.isVisible })?.firstResponder as? TerminalView)
                else {
                    FileHandle.standardError.write(Data("[self-shot] no pane to scroll\n".utf8))
                    return
                }
                pane.session.scroll(lines: lines)
            }
        }

        // The wheel, as the trackpad delivers it: posted to the app so AppKit's
        // own routing decides which view sees it, which is the half of the
        // path that calling scrollWheel(with:) directly would skip.
        if let points = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_WHEEL"].flatMap(Int32.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.8) {
                guard let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible }),
                      let pane = window.firstResponder as? TerminalView,
                      let scroll = CGEvent(
                          scrollWheelEvent2Source: nil,
                          units: .pixel,
                          wheelCount: 1,
                          wheel1: points,
                          wheel2: 0,
                          wheel3: 0
                      )
                else {
                    FileHandle.standardError.write(Data("[self-shot] no pane to wheel\n".utf8))
                    return
                }
                // Handed to the pane rather than posted: a synthesised event
                // posted to the app never survives AppKit's own routing, and
                // what is being measured here is the pane's own arithmetic.
                let centre = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
                let onScreen = window.convertPoint(toScreen: centre)
                let height = NSScreen.screens.first?.frame.height ?? 0
                scroll.location = CGPoint(x: onScreen.x, y: height - onScreen.y)
                guard let wheel = NSEvent(cgEvent: scroll) else { return }
                pane.scrollWheel(with: wheel)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let pane = (NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible }))?
                .firstResponder as? TerminalView
            {
                FileHandle.standardError.write(Data("[self-shot] \(pane.scrollState)\n".utf8))
            }
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
