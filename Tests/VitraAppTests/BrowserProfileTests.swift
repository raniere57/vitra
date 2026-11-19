import Foundation
import Testing
@testable import VitraApp

@Test func eachProjectHasItsOwnBrowserProfileThatLastsAcrossLaunches() {
    #expect(BrowserProfile.id(for: "/Users/a/Dev/hapto") == BrowserProfile.id(for: "/Users/a/Dev/hapto"))
    #expect(BrowserProfile.id(for: "/Users/a/Dev/hapto") != BrowserProfile.id(for: "/Users/a/Dev/farol"))
}

@Test func projectsShareTheBrowserUntilOneIsGivenItsOwn() {
    let defaults = UserDefaults(suiteName: "browser-profile-\(UUID().uuidString)")!
    #expect(BrowserProfile.profile(for: "/a", defaults: defaults) == nil)
    BrowserProfile.setOwn(true, for: "/a", defaults: defaults)
    #expect(BrowserProfile.profile(for: "/a", defaults: defaults) == BrowserProfile.id(for: "/a"))
    #expect(BrowserProfile.profile(for: "/b", defaults: defaults) == nil)
    BrowserProfile.setOwn(false, for: "/a", defaults: defaults)
    #expect(BrowserProfile.profile(for: "/a", defaults: defaults) == nil)
}
