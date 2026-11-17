import CoreGraphics
import Foundation
import Testing
@testable import VitraApp

/// A window of an app, as the tests need one: on the screen, ordinary, and
/// big enough to be worth shooting.
private func window(_ id: CGWindowID, _ application: String, _ width: CGFloat = 400, _ height: CGFloat = 300) -> ScreenCapture.Window {
    ScreenCapture.Window(
        id: id,
        application: application,
        size: CGSize(width: width, height: height),
        layer: 0,
        onScreen: true
    )
}

@Test func theFrontmostWindowOfTheAppIsTheOneToShoot() {
    // The windows come in front-to-back order: the first Safari window is on
    // top, even though the one behind it is bigger.
    let windows = [
        window(1, "Safari", 200, 200),
        window(2, "Safari", 900, 700),
        window(3, "Simulator", 800, 600),
    ]
    #expect(ScreenCapture.window(for: "Safari", among: windows)?.id == 1)
}

@Test func aBiggerWindowOfAnotherAppInFrontDoesNotWin() {
    let windows = [
        window(1, "Simulator", 900, 700),
        window(2, "Safari", 400, 300),
    ]
    #expect(ScreenCapture.window(for: "Safari", among: windows)?.id == 2)
}

@Test func aPanelOfTheAppIsPassedBy() {
    // The panel is bigger and on top, but it is not the window of the app.
    let windows = [
        ScreenCapture.Window(id: 1, application: "Safari", size: CGSize(width: 900, height: 700), layer: 3, onScreen: true),
        window(2, "Safari"),
    ]
    #expect(ScreenCapture.window(for: "Safari", among: windows)?.id == 2)
}

@Test func aWindowThatIsNotOnScreenIsPassedBy() {
    let windows = [
        ScreenCapture.Window(id: 1, application: "Safari", size: CGSize(width: 900, height: 700), layer: 0, onScreen: false),
        window(2, "Safari"),
    ]
    #expect(ScreenCapture.window(for: "Safari", among: windows)?.id == 2)
}

@Test func aWindowTooSmallToLookAtIsPassedBy() {
    let windows = [
        window(1, "Safari", 20, 20),
        window(2, "Safari"),
    ]
    #expect(ScreenCapture.window(for: "Safari", among: windows)?.id == 2)
}

@Test func theAppIsMatchedWithoutRegardToCaseOrSpaces() {
    let windows = [window(7, "Safari")]
    #expect(ScreenCapture.window(for: "safari", among: windows)?.id == 7)
    #expect(ScreenCapture.window(for: "SAFARI", among: windows)?.id == 7)
    #expect(ScreenCapture.window(for: "  Safari  ", among: windows)?.id == 7)
}

@Test func anAppWithNoWindowIsGivenNone() {
    let windows = [window(1, "Safari")]
    #expect(ScreenCapture.window(for: "Xcode", among: windows) == nil)
    #expect(ScreenCapture.window(for: "", among: windows) == nil)
    #expect(ScreenCapture.window(for: "   ", among: windows) == nil)
    #expect(ScreenCapture.window(for: "Safari", among: []) == nil)
}
