import Foundation
import Testing
@testable import VitraApp

@Test func theBiggestWindowOfTheAppIsTheOneToShoot() {
    let windows = [
        ScreenCapture.Window(id: 1, application: "Safari", area: 100),
        ScreenCapture.Window(id: 2, application: "Safari", area: 900),
        ScreenCapture.Window(id: 3, application: "Simulator", area: 800),
    ]
    #expect(ScreenCapture.window(for: "Safari", among: windows)?.id == 2)
}

@Test func theAppIsMatchedWithoutRegardToCase() {
    let windows = [ScreenCapture.Window(id: 7, application: "Safari", area: 100)]
    #expect(ScreenCapture.window(for: "safari", among: windows)?.id == 7)
    #expect(ScreenCapture.window(for: "SAFARI", among: windows)?.id == 7)
}

@Test func anAppWithNoWindowIsGivenNone() {
    let windows = [ScreenCapture.Window(id: 1, application: "Safari", area: 100)]
    #expect(ScreenCapture.window(for: "Xcode", among: windows) == nil)
    #expect(ScreenCapture.window(for: "", among: windows) == nil)
    #expect(ScreenCapture.window(for: "Safari", among: []) == nil)
}
