import Foundation
import Testing
@testable import VitraPanel

@Test("a host with a port is a host, not a scheme")
func hostWithPortIsNotAScheme() {
    #expect(BrowserView.url(from: "localhost:5173")?.absoluteString == "http://localhost:5173")
    #expect(BrowserView.url(from: "127.0.0.1:8000")?.absoluteString == "http://127.0.0.1:8000")
    #expect(
        BrowserView.url(from: "localhost:5173/app?a=1")?.absoluteString
            == "http://localhost:5173/app?a=1"
    )
    #expect(BrowserView.url(from: "example.com:8443")?.absoluteString == "https://example.com:8443")
}

@Test("a real scheme is left alone, a bare host gets https")
func schemesAndBareHosts() {
    #expect(BrowserView.url(from: "https://example.com")?.absoluteString == "https://example.com")
    #expect(BrowserView.url(from: "http://localhost:3000")?.absoluteString == "http://localhost:3000")
    #expect(BrowserView.url(from: "example.com")?.absoluteString == "https://example.com")
    #expect(BrowserView.url(from: "  ")  == nil)
    #expect(BrowserView.url(from: "/etc/hosts")?.isFileURL == true)
}
