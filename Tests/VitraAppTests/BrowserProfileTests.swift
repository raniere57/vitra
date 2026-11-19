import Testing
@testable import VitraApp

@Test func eachProjectHasItsOwnBrowserProfileThatLastsAcrossLaunches() {
    #expect(BrowserProfile.id(for: "/Users/a/Dev/hapto") == BrowserProfile.id(for: "/Users/a/Dev/hapto"))
    #expect(BrowserProfile.id(for: "/Users/a/Dev/hapto") != BrowserProfile.id(for: "/Users/a/Dev/farol"))
}
