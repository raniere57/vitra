// Draws Vitra's icon with Core Graphics and writes every size the .icns needs.
//
// Core Graphics rather than SVG: the gradients, the glass fill and the Big Sur
// squircle are all easier to control directly, and one pass produces every size
// with the artwork simplified per size instead of downscaled.
//
//   swift scripts/make-icon.swift <output-directory>

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

/// Apple's macOS template: the art occupies 824 of a 1024 canvas, leaving the
/// margin the system expects for shadows and alignment with other icons.
let bodyRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat = 185.0 / 824.0

/// How much of the artwork a given size can carry.
///
/// The caret is one shape at every size; what changes is its weight and how
/// much light is drawn around it. Small sizes are a different drawing, not a
/// smaller one — a faithful reduction is a grey smudge.
enum Detail {
    case full     // 256 and up: lit tile, glass fill, chromatic edge, glow
    case medium   // 64 and 128: flat glass, no chromatic edge
    case small    // 32 and below: solid white, heavier stroke, bigger cursor

    init(size: Int) {
        switch size {
        case 256...: self = .full
        case 64...: self = .medium
        default: self = .small
        }
    }
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    let colors = stops.map { color($0.0, $0.1) } as CFArray
    let locations = stops.map { $0.2 }
    return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations)!
}

/// The squircle Apple's template uses. A rounded rectangle is close enough at
/// these radii, and it is what the mask in the template actually is.
func bodyPath(in rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Drawing

func drawIcon(size: Int) -> CGImage {
    let side = CGFloat(size)
    let detail = Detail(size: size)
    let isTiny = size <= 16
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let body = CGRect(
        x: side * (1 - bodyRatio) / 2,
        y: side * (1 - bodyRatio) / 2,
        width: side * bodyRatio,
        height: side * bodyRatio
    )
    let radius = body.width * cornerRatio

    /// A point of the 1024-unit design, in the context's own coordinates.
    ///
    /// The design is drawn with y running down, the way every drawing tool
    /// states it; Core Graphics runs y up. One conversion here keeps every
    /// coordinate below identical to the artboard it came from.
    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: side * x / 1024, y: side * (1024 - y) / 1024)
    }

    /// A length of the design, in the context's own coordinates.
    func unit(_ value: CGFloat) -> CGFloat { side * value / 1024 }

    // --- the tile
    context.saveGState()
    context.addPath(bodyPath(in: body, radius: radius))
    context.clip()

    // Slate blue falling away to near black, lit from the upper left. The
    // caret is white, so the tile has to stay dark all the way to the corners.
    context.drawRadialGradient(
        gradient([
            (0x223041, 1, 0),
            (0x151d27, 1, 0.42),
            (0x0b0e14, 1, 0.76),
            (0x06070b, 1, 1),
        ]),
        startCenter: at(330, 250),
        startRadius: 0,
        endCenter: at(512, 512),
        endRadius: unit(840),
        options: [.drawsAfterEndLocation]
    )

    if detail != .small {
        // A soft bloom where the light comes from, so the tile is lit rather
        // than merely coloured.
        context.setBlendMode(.screen)
        context.drawRadialGradient(
            gradient([(0x5aa5e0, 0.26, 0), (0x5aa5e0, 0.00, 1)]),
            startCenter: at(320, 250),
            startRadius: 0,
            endCenter: at(320, 250),
            endRadius: unit(560),
            options: []
        )
        context.setBlendMode(.normal)
    }

    // --- the caret
    //
    // The one mark every terminal user already reads as "type here": the
    // prompt's chevron, with the cursor block waiting beside it.
    // Shorter and blunter as the size drops: a round cap reaches half a stroke
    // past the mitre, so a heavy chevron eats the gap the cursor needs.
    let chevron = CGMutablePath()
    let (back, tip, stroke): (CGFloat, CGFloat, CGFloat) = isTiny
        ? (330, 528, 132)
        : detail == .small ? (344, 546, 116) : (340, 560, 86)
    let reach: CGFloat = isTiny ? 166 : detail == .small ? 174 : 192

    // A block cursor is one cell: taller than it is wide, and level with the
    // prompt it follows — the mitre of the chevron is the line it sits on,
    // with room for one blank cell between them.
    let cursorWidth: CGFloat = isTiny ? 148 : detail == .small ? 138 : 124
    let cursorHeight = cursorWidth * 1.32
    let gap: CGFloat = isTiny ? 56 : detail == .small ? 48 : 34
    chevron.move(to: at(back, 512 - reach))
    chevron.addLine(to: at(tip, 512))
    chevron.addLine(to: at(back, 512 + reach))

    /// The chevron as an area, so it can be filled with a gradient rather than
    /// stroked in one flat colour.
    func chevronArea(offsetBy offset: CGSize = .zero) -> CGPath {
        let shape = CGMutablePath()
        shape.addPath(chevron, transform: CGAffineTransform(translationX: offset.width, y: offset.height))
        // Stroking only happens inside a context; a throwaway one keeps the
        // real context's state untouched.
        let scratch = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        scratch.addPath(shape)
        scratch.setLineWidth(unit(stroke))
        scratch.setLineCap(.round)
        scratch.setLineJoin(.round)
        scratch.replacePathWithStrokedPath()
        return scratch.path ?? shape
    }

    // The chevron and the cursor are one mark, and it is the mark that gets
    // centred on the tile — not the chevron, which would leave the pair
    // hanging to the left.
    let markLeft = back - stroke / 2
    let markRight = tip + stroke / 2 + gap + cursorWidth
    context.saveGState()
    context.translateBy(x: unit(512 - (markLeft + markRight) / 2), y: 0)

    if detail == .full {
        // A hair of colour escaping the lower-right edge of the glass: teal
        // through blue to violet, the terminal's own accents. Drawn under the
        // white so it reads as refraction and not as an outline.
        context.saveGState()
        context.setAlpha(0.6)
        context.addPath(chevronArea(offsetBy: CGSize(width: unit(7), height: -unit(7))))
        context.clip()
        context.drawLinearGradient(
            gradient([(0x4fb8b0, 1, 0), (0x7cc0ff, 1, 0.5), (0xc07ce8, 1, 1)]),
            start: at(340, 320),
            end: at(560, 704),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(chevronArea())
    context.clip()
    if detail == .small {
        context.setFillColor(color(0xf6fcff, 1))
        context.fill(CGRect(origin: .zero, size: CGSize(width: side, height: side)))
    } else {
        context.drawLinearGradient(
            gradient([(0xffffff, 1, 0), (0xe6f4fb, 1, 0.5), (0xa9d6ec, 1, 1)]),
            start: at(300, 280),
            end: at(600, 740),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    context.restoreGState()

    // The cursor block: the only saturated shape in the icon, and what makes
    // the chevron Vitra's rather than any terminal's.
    let cursor = CGRect(
        origin: at(tip + stroke / 2 + gap, 512 + cursorHeight / 2),
        size: CGSize(width: unit(cursorWidth), height: unit(cursorHeight))
    )
    let cursorPath = CGPath(
        roundedRect: cursor,
        cornerWidth: unit(isTiny ? 14 : 16),
        cornerHeight: unit(isTiny ? 14 : 16),
        transform: nil
    )

    if detail == .full {
        context.saveGState()
        context.setShadow(offset: .zero, blur: unit(46), color: color(0x7cc0ff, 0.85))
        context.addPath(cursorPath)
        context.setFillColor(color(0x7cc0ff, 1))
        context.fillPath()
        context.restoreGState()
    } else {
        context.addPath(cursorPath)
        context.setFillColor(color(0x7cc0ff, 1))
        context.fillPath()
    }

    context.restoreGState()
    context.restoreGState()

    // --- the rim of the tile itself
    context.addPath(bodyPath(in: body, radius: radius))
    context.setStrokeColor(color(0x8fd8e8, 0.12))
    context.setLineWidth(side * 0.004)
    context.strokePath()

    return context.makeImage()!
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) {
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: image.width, height: image.height)
    guard let data = representation.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

let arguments = CommandLine.arguments
let outputDirectory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "dist/icon")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = drawIcon(size: size)
    write(image, to: outputDirectory.appendingPathComponent("icon_\(size).png"))
}
print("wrote icons to \(outputDirectory.path)")
