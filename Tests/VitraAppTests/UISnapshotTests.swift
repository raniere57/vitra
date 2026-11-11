import AppKit
import Foundation
import Testing
@testable import VitraApp

@MainActor
@Test func snapshotWritesEveryPictureAtTwiceItsSizeAndNotBlank() throws {
    // With a `.build/snap-keep` file in the package, the pictures are kept in
    // `.build/snap`, where an agent that cannot run the app can look at them.
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let keeps = FileManager.default.fileExists(atPath: package.appendingPathComponent(".build/snap-keep").path)
    let directory = keeps
        ? package.appendingPathComponent(".build/snap")
        : FileManager.default.temporaryDirectory.appendingPathComponent("vitra-snapshot-test-\(UUID().uuidString)")
    defer { if !keeps { try? FileManager.default.removeItem(at: directory) } }

    let files = try UISnapshot.run(into: directory)

    let expected = [
        "window-1440", "window-min", "workers", "ranking", "git", "files", "recent-images", "browser-tabs", "preview-header", "quit-hold",
        "stage", "stage-empty", "stage-reduced-motion", "resumo", "resumo-expanded",
    ]
    #expect(Set(expected).isSubset(of: Set(UISnapshot.shots.map(\.name))))
    #expect(files.count == UISnapshot.shots.count)

    for shot in UISnapshot.shots {
        let url = directory.appendingPathComponent(shot.name + ".png")
        let data = try #require(FileManager.default.contents(atPath: url.path), "\(shot.name).png was not written")
        let rep = try #require(NSBitmapImageRep(data: data), "\(shot.name).png is not an image")
        #expect(rep.pixelsWide == Int(shot.size.width * UISnapshot.scale), "\(shot.name) width")
        #expect(rep.pixelsHigh == Int(shot.size.height * UISnapshot.scale), "\(shot.name) height")
        #expect(colourCount(of: rep) > 1, "\(shot.name) is a single flat colour")
    }
}

/// How many different colours there are in a sample of the picture's pixels.
private func colourCount(of rep: NSBitmapImageRep) -> Int {
    var seen = Set<[CGFloat]>()
    for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
            guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            seen.insert([colour.redComponent, colour.greenComponent, colour.blueComponent])
            if seen.count > 1 { return seen.count }
        }
    }
    return seen.count
}
