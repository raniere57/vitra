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

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(to: path)
            if ProcessInfo.processInfo.environment["VITRA_SELF_SHOT_QUIT"] != nil {
                NSApp.terminate(nil)
            }
        }
    }

    private static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
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
            FileHandle.standardError.write(Data("[self-shot] capture failed\n".utf8))
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
