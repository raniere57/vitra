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
        let delay = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_DELAY"].flatMap(Double.init) ?? 1.5

        // Optional comma-separated selectors fired before the shot, so keyboard
        // shortcuts can be exercised from an automated run.
        if let actions = ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_ACTIONS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 2) {
                for name in actions.split(separator: ",") {
                    let selector = Selector(String(name))
                    // The responder chain only reaches the app delegate when a
                    // key window exists, which it may not for a headless run.
                    var delivered = NSApp.sendAction(selector, to: nil, from: nil)
                    if !delivered {
                        delivered = NSApp.sendAction(selector, to: NSApp.delegate, from: nil)
                    }
                    FileHandle.standardError.write(Data("[self-shot] \(name): \(delivered ? "sent" : "NOT DELIVERED")\n".utf8))
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(to: path)
            if ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_QUIT"] != nil {
                NSApp.terminate(nil)
            }
        }
    }

    private static func capture(to path: String) {
        // Prefer the key window: with native tabs, several windows are "visible"
        // but only the front tab is on screen.
        let candidate = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
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
