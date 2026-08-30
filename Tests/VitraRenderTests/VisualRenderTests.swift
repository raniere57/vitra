import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
import VitraCore
@testable import VitraRender

private let visualFonts = FontSet(name: "Menlo", size: 26)

/// A rendered frame, with pixel access for assertions.
private struct RenderedFrame {
    let width: Int
    let height: Int
    let pixels: [UInt8]  // BGRA

    /// The colour at a pixel, as (red, green, blue).
    func color(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let offset = (y * width + x) * 4
        return (pixels[offset + 2], pixels[offset + 1], pixels[offset])
    }

    /// True when any pixel in the rectangle is meaningfully brighter than `base`.
    func hasInk(inRect rect: (x: Int, y: Int, width: Int, height: Int), over base: (r: UInt8, g: UInt8, b: UInt8)) -> Bool {
        for y in rect.y ..< min(rect.y + rect.height, height) {
            for x in rect.x ..< min(rect.x + rect.width, width) {
                let pixel = color(x: x, y: y)
                let difference = abs(Int(pixel.r) - Int(base.r))
                    + abs(Int(pixel.g) - Int(base.g))
                    + abs(Int(pixel.b) - Int(base.b))
                if difference > 60 { return true }
            }
        }
        return false
    }

    func writePNG(to url: URL) {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                      .union(.byteOrder32Little),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

private func render(
    _ snapshot: RenderSnapshot,
    cursorOn: Bool = true,
    padding: CGFloat = 0,
    saveAs name: String? = nil
) throws -> RenderedFrame {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = try TerminalRenderer(device: device, fonts: visualFonts)

    let size = renderer.pixelSize(
        columns: Int(snapshot.columns),
        rows: Int(snapshot.rows),
        padding: padding
    )
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: Int(size.width),
        height: Int(size.height),
        mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: descriptor))

    renderer.render(snapshot: snapshot, cursorOn: cursorOn, padding: padding, into: target)

    var pixels = [UInt8](repeating: 0, count: target.width * target.height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        target.getBytes(
            buffer.baseAddress!,
            bytesPerRow: target.width * 4,
            from: MTLRegionMake2D(0, 0, target.width, target.height),
            mipmapLevel: 0
        )
    }

    let frame = RenderedFrame(width: target.width, height: target.height, pixels: pixels)
    if let name, let directory = ProcessInfo.processInfo.environment["VITRA_RENDER_DUMP"] {
        frame.writePNG(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
    return frame
}

/// Builds a snapshot without going through a terminal engine.
private func makeSnapshot(columns: UInt16, rows: UInt16, _ fill: (RenderSnapshot) -> Void) -> RenderSnapshot {
    let snapshot = RenderSnapshot()
    snapshot.beginFrame(
        columns: columns,
        rows: rows,
        foreground: TerminalColor(red: 220, green: 220, blue: 220),
        background: TerminalColor(red: 20, green: 20, blue: 25)
    )
    fill(snapshot)
    return snapshot
}

private func put(
    _ text: String,
    at column: Int,
    row: Int,
    in snapshot: RenderSnapshot,
    foreground: TerminalColor? = nil,
    background: TerminalColor? = nil,
    flags: CellFlags = []
) {
    var bytes = Array(text.utf8)
    let location = bytes.withUnsafeBytes { snapshot.appendText($0) }
    snapshot.setCell(
        RenderCell(
            textOffset: location.offset,
            textLength: location.length,
            flags: flags,
            foreground: foreground ?? snapshot.defaultForeground,
            background: background ?? snapshot.defaultBackground
        ),
        column: column,
        row: row
    )
}

@Test func emptyGridIsFilledWithTheDefaultBackground() throws {
    let snapshot = makeSnapshot(columns: 4, rows: 2) { _ in }
    let frame = try render(snapshot, cursorOn: false)
    let pixel = frame.color(x: frame.width / 2, y: frame.height / 2)
    #expect(pixel.r == 20 && pixel.g == 20 && pixel.b == 25)
}

@Test func glyphsPutInkInTheirOwnCell() throws {
    let snapshot = makeSnapshot(columns: 4, rows: 1) { snapshot in
        put("A", at: 0, row: 0, in: snapshot)
        put("W", at: 2, row: 0, in: snapshot)
    }
    let frame = try render(snapshot, cursorOn: false, saveAs: "glyphs")

    let cellWidth = Int(visualFonts.metrics.cellWidth)
    let cellHeight = Int(visualFonts.metrics.cellHeight)
    let background = (r: UInt8(20), g: UInt8(20), b: UInt8(25))

    #expect(frame.hasInk(inRect: (0, 0, cellWidth, cellHeight), over: background))
    // Column 1 was never written to and must stay empty.
    #expect(!frame.hasInk(inRect: (cellWidth, 0, cellWidth, cellHeight), over: background))
    #expect(frame.hasInk(inRect: (cellWidth * 2, 0, cellWidth, cellHeight), over: background))
    #expect(!frame.hasInk(inRect: (cellWidth * 3, 0, cellWidth, cellHeight), over: background))
}

@Test func cellBackgroundColourIsPainted() throws {
    let red = TerminalColor(red: 200, green: 30, blue: 30)
    let snapshot = makeSnapshot(columns: 2, rows: 1) { snapshot in
        put(" ", at: 0, row: 0, in: snapshot, background: red)
    }
    let frame = try render(snapshot, cursorOn: false, saveAs: "background")

    let pixel = frame.color(x: 2, y: Int(visualFonts.metrics.cellHeight) / 2)
    #expect(pixel.r == 200 && pixel.g == 30 && pixel.b == 30)
}

@Test func inverseSwapsForegroundAndBackground() throws {
    let snapshot = makeSnapshot(columns: 2, rows: 1) { snapshot in
        put("X", at: 0, row: 0, in: snapshot, flags: .inverse)
    }
    let frame = try render(snapshot, cursorOn: false, saveAs: "inverse")

    // The cell now carries the foreground colour as its background.
    let pixel = frame.color(x: 1, y: 1)
    #expect(pixel.r > 200 && pixel.g > 200 && pixel.b > 200)
}

@Test func underlineDrawsBelowTheGlyph() throws {
    let plain = makeSnapshot(columns: 1, rows: 1) { put("o", at: 0, row: 0, in: $0) }
    let underlined = makeSnapshot(columns: 1, rows: 1) { put("o", at: 0, row: 0, in: $0, flags: .underline) }

    let cellWidth = Int(visualFonts.metrics.cellWidth)
    let cellHeight = Int(visualFonts.metrics.cellHeight)
    let baseline = Int(visualFonts.metrics.baseline)
    let background = (r: UInt8(20), g: UInt8(20), b: UInt8(25))
    // Below the baseline, where "o" has no descender of its own.
    let strip = (x: 0, y: baseline + 2, width: cellWidth, height: max(1, cellHeight - baseline - 2))

    #expect(!(try render(plain, cursorOn: false).hasInk(inRect: strip, over: background)))
    #expect(try render(underlined, cursorOn: false, saveAs: "underline").hasInk(inRect: strip, over: background))
}

@Test func blockCursorPaintsItsCellAndInvertsTheGlyph() throws {
    let snapshot = makeSnapshot(columns: 3, rows: 1) { snapshot in
        put("a", at: 0, row: 0, in: snapshot)
        snapshot.cursor = CursorSnapshot(
            column: 0,
            row: 0,
            style: .block,
            isBlinking: true,
            color: TerminalColor(red: 240, green: 200, blue: 80)
        )
    }

    let on = try render(snapshot, cursorOn: true, saveAs: "cursor-on")
    let off = try render(snapshot, cursorOn: false, saveAs: "cursor-off")

    // Corner of the cursor cell, away from the glyph's ink.
    let cursorPixel = on.color(x: 1, y: 1)
    #expect(cursorPixel.r > 200 && cursorPixel.g > 150 && cursorPixel.b < 140)

    let blinkedOff = off.color(x: 1, y: 1)
    #expect(blinkedOff.r == 20 && blinkedOff.g == 20 && blinkedOff.b == 25)
}

@Test func wideCharacterOverhangsIntoItsTrailingCell() throws {
    // The tail cell holds no text, so ink appearing there proves the glyph is
    // being drawn at its natural width rather than squeezed into one cell.
    let snapshot = makeSnapshot(columns: 3, rows: 1) { put("日", at: 0, row: 0, in: $0) }
    let frame = try render(snapshot, cursorOn: false, saveAs: "wide")

    let cellWidth = Int(visualFonts.metrics.cellWidth)
    let cellHeight = Int(visualFonts.metrics.cellHeight)
    let background = (r: UInt8(20), g: UInt8(20), b: UInt8(25))

    #expect(frame.hasInk(inRect: (0, 0, cellWidth, cellHeight), over: background))
    #expect(frame.hasInk(inRect: (cellWidth, 0, cellWidth, cellHeight), over: background))
    #expect(!frame.hasInk(inRect: (cellWidth * 2, 0, cellWidth, cellHeight), over: background))
}
