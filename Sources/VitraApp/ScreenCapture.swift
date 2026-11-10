import AppKit
import ScreenCaptureKit
import VitraBridge

/// Pictures of what is on the user's screen.
///
/// browser_screenshot can only shoot the page Vitra shows. An agent working
/// on something else — the Simulator, Xcode, a browser of its own — needs a
/// picture of that window too, and ScreenCaptureKit is the way to ask macOS
/// for one without the user picking the window by hand.
enum ScreenCapture {
    /// A window that could be shot, without ScreenCaptureKit's types: the
    /// choice between windows is made on these, so it can be tested without
    /// capturing anything.
    struct Window: Equatable {
        /// ScreenCaptureKit's id for the window, which is how it is found again.
        let id: CGWindowID
        /// The name of the app that owns it, as ScreenCaptureKit spells it.
        let application: String
        /// How big it is, in points squared: the bigger window is the one on show.
        let area: Double
    }

    /// The window to shoot for the app named: the biggest one that belongs to
    /// it, matched without regard to case. Nil when that app has no window.
    static func window(for app: String, among windows: [Window]) -> Window? {
        windows
            .filter { $0.application.compare(app, options: .caseInsensitive) == .orderedSame }
            .max { $0.area < $1.area }
    }

    /// The PNG of the biggest window of the app named — the one on show — or
    /// of the whole main display when no app is named.
    @MainActor
    static func png(app: String?) async throws -> Data {
        guard hasPermission() else { throw ToolError(permissionAdvice) }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // macOS refuses a capture it is not allowed to make, and says so
            // with the error of a user who declined: the advice to give then
            // is the permission's, not a broken screen's.
            let failure = error as NSError
            if failure.domain == SCStreamErrorDomain,
               failure.code == SCStreamError.Code.userDeclined.rawValue {
                throw ToolError(permissionAdvice)
            }
            if !CGPreflightScreenCaptureAccess() { throw ToolError(permissionAdvice) }
            throw ToolError("the screen could not be read: \(failure.localizedDescription)")
        }

        let windows = content.windows.filter(\.isOnScreen)
        guard let wanted = wantedApp(app) else {
            guard let display = mainDisplay(in: content.displays) else { throw ToolError("no screen is attached") }
            return try await capture(display: display)
        }

        let candidates = windows.map {
            Window(
                id: $0.windowID,
                application: $0.owningApplication?.applicationName ?? "",
                area: Double($0.frame.width * $0.frame.height)
            )
        }
        guard let chosen = window(for: wanted, among: candidates) else {
            throw ToolError(missingWindow(app: wanted, windows: candidates))
        }
        guard let target = windows.first(where: { $0.windowID == chosen.id }) else {
            throw ToolError("\(wanted) closed its window before it could be captured")
        }
        return try await capture(window: target, displays: content.displays)
    }

    /// The app to shoot, or nothing when the caller named none.
    private static func wantedApp(_ app: String?) -> String? {
        guard let app else { return nil }
        let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether macOS lets Vitra record the screen.
    ///
    /// The first call is what asks the user: macOS puts up the prompt, and the
    /// answer decides whether the capture can go on.
    @MainActor
    private static func hasPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// What to say when macOS will not let Vitra record the screen.
    private static let permissionAdvice =
        "macOS has not allowed Vitra to record the screen: allow Vitra under System Settings › Privacy & Security › Screen Recording, then try again."

    /// The picture of the whole display, at its own pixel size.
    @MainActor
    private static func capture(display: SCDisplay) async throws -> Data {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(Double(display.width) * scale(of: display))
        configuration.height = Int(Double(display.height) * scale(of: display))
        configuration.showsCursor = false
        return try await image(filter: filter, configuration: configuration)
    }

    /// The picture of one window, at the pixel size of the screen it is on.
    @MainActor
    private static func capture(window: SCWindow, displays: [SCDisplay]) async throws -> Data {
        guard let screen = display(containing: window, in: displays) else {
            throw ToolError("the window is on a screen that is gone")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale(of: screen))
        configuration.height = Int(window.frame.height * scale(of: screen))
        configuration.showsCursor = false
        return try await image(filter: filter, configuration: configuration)
    }

    /// The picture itself, as a PNG.
    @MainActor
    private static func image(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> Data {
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw ToolError("the capture could not be turned into a PNG")
        }
        return png
    }

    /// The screen the user is looking at.
    @MainActor
    private static func mainDisplay(in displays: [SCDisplay]) -> SCDisplay? {
        displays.first { $0.displayID == CGMainDisplayID() } ?? displays.first
    }

    /// The screen a window is on, which decides the size of its pixels.
    @MainActor
    private static func display(containing window: SCWindow, in displays: [SCDisplay]) -> SCDisplay? {
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        return displays.first { $0.frame.contains(center) } ?? mainDisplay(in: displays)
    }

    /// How many pixels a point on that screen is: a Retina screen has two.
    @MainActor
    private static func scale(of display: SCDisplay) -> Double {
        guard display.width > 0 else { return 1 }
        return Double(CGDisplayPixelsWide(display.displayID)) / Double(display.width)
    }

    /// What to say when the app named has no window to shoot: whether it is
    /// running at all, and what is on the screen instead.
    @MainActor
    private static func missingWindow(app: String, windows: [Window]) -> String {
        let others = Set(windows.map(\.application)).filter { !$0.isEmpty }.sorted()
        let list = others.isEmpty ? "none" : others.joined(separator: ", ")
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.localizedName?.compare(app, options: .caseInsensitive) == .orderedSame
        }
        guard running else {
            return "there is no app called '\(app)' running. Apps with windows: \(list)."
        }
        return "\(app) has no window open on screen. Apps with windows: \(list)."
    }
}
