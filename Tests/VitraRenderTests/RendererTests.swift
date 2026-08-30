import Foundation
import Metal
import Testing
import VitraCore
@testable import VitraRender

private let fonts = FontSet(name: "Menlo", size: 26)

@Test func fontMetricsAreWholePixels() {
    let metrics = fonts.metrics
    // Fractional advances accumulate across a row and leave the last column
    // visibly misaligned, so the grid is built on integers.
    #expect(metrics.cellWidth == metrics.cellWidth.rounded())
    #expect(metrics.cellHeight == metrics.cellHeight.rounded())
    #expect(metrics.cellWidth > 0)
    #expect(metrics.cellHeight > metrics.cellWidth)
    #expect(metrics.baseline > 0 && metrics.baseline < metrics.cellHeight)
}

@Test func shaderLibraryLoadsAndPipelineBuilds() throws {
    // Launch cost matters for a terminal, so the phases are measured separately:
    // shader compilation, GPU pipeline compilation, and atlas texture allocation
    // have very different fixed costs and only one of them is ours to control.
    func milliseconds(_ body: () throws -> Void) rethrows -> String {
        let start = DispatchTime.now()
        try body()
        return String(format: "%.1f ms", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
    }

    var device: MTLDevice?
    let deviceTime = milliseconds { device = MTLCreateSystemDefaultDevice() }
    let metalDevice = try #require(device)

    var library: MTLLibrary?
    let libraryTime = milliseconds { library = try? metalDevice.makeDefaultLibrary(bundle: .module) }
    #expect(library != nil, "precompiled default.metallib should be in the resource bundle")

    var atlas: GlyphAtlas?
    let atlasTime = try milliseconds { atlas = try GlyphAtlas(device: metalDevice, fonts: fonts) }
    #expect(atlas != nil)

    let firstRenderer = try milliseconds { _ = try TerminalRenderer(device: metalDevice, fonts: fonts) }
    let secondRenderer = try milliseconds { _ = try TerminalRenderer(device: metalDevice, fonts: fonts) }

    print("device: \(deviceTime)  library: \(libraryTime)  atlas: \(atlasTime)  renderer: \(firstRenderer) then \(secondRenderer)")
}

@Test func atlasRasterizesAsciiAndCachesIt() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let atlas = try GlyphAtlas(device: device, fonts: fonts)

    let a = atlas.entry(ascii: UInt8(ascii: "A"), bold: false, italic: false)
    #expect(!a.isEmpty)
    #expect(a.width > 0 && a.height > 0)

    // Same glyph must resolve to the same atlas region, not a second copy.
    let again = atlas.entry(ascii: UInt8(ascii: "A"), bold: false, italic: false)
    #expect(again.u0 == a.u0 && again.v0 == a.v0)

    // Bold is a different rasterization and must occupy its own region.
    let bold = atlas.entry(ascii: UInt8(ascii: "A"), bold: true, italic: false)
    #expect(bold.u0 != a.u0 || bold.v0 != a.v0)
}

@Test func atlasHandlesClustersAndReportsEmptyForBlanks() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let atlas = try GlyphAtlas(device: device, fonts: fonts)

    #expect(!atlas.entry(cluster: "日", bold: false, italic: false).isEmpty)
    #expect(!atlas.entry(cluster: "é", bold: false, italic: false).isEmpty)
    // A space has no ink; drawing a quad for it would be wasted work every frame.
    #expect(atlas.entry(ascii: UInt8(ascii: " "), bold: false, italic: false).isEmpty)
}

@Test func gridSizeAndPixelSizeAreInverses() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = try TerminalRenderer(device: device, fonts: fonts)

    let pixels = renderer.pixelSize(columns: 80, rows: 24, padding: 8)
    let grid = renderer.gridSize(for: pixels, padding: 8)
    #expect(grid.columns == 80)
    #expect(grid.rows == 24)
}

@Test func gridSizeNeverReturnsZero() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = try TerminalRenderer(device: device, fonts: fonts)
    // A window can be dragged smaller than one cell; a zero-sized grid would
    // divide by zero downstream.
    let grid = renderer.gridSize(for: CGSize(width: 1, height: 1), padding: 8)
    #expect(grid.columns == 1)
    #expect(grid.rows == 1)
}
