// Draws Vitra's icon with Core Graphics and writes every size the .icns needs.
//
// Core Graphics rather than SVG: the gradients, the refraction and the Big Sur
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
enum Detail {
    case full     // 256 and up: refraction, spectrum, every highlight
    case medium   // 64 and 128: glass and caret, no spectrum
    case small    // 32 and below: the blade and the caret, higher contrast

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

    // --- the surface the glass sits on
    context.saveGState()
    context.addPath(bodyPath(in: body, radius: radius))
    context.clip()

    // Deep blue-petrol falling away to near black, lit from the upper left.
    context.drawRadialGradient(
        gradient([
            (0x14414f, 1, 0),
            (0x0c2d38, 1, 0.45),
            (0x06131a, 1, 0.78),
            (0x03070a, 1, 1),
        ]),
        startCenter: CGPoint(x: body.minX + body.width * 0.32, y: body.maxY - body.height * 0.26),
        startRadius: 0,
        endCenter: CGPoint(x: body.midX, y: body.midY),
        endRadius: body.width * 0.82,
        options: [.drawsAfterEndLocation]
    )

    // A soft bloom where the light comes from, so the background is lit rather
    // than merely coloured.
    context.setBlendMode(.screen)
    context.drawRadialGradient(
        gradient([(0x7fd3e8, 0.22, 0), (0x7fd3e8, 0.00, 1)]),
        startCenter: CGPoint(x: body.minX + body.width * 0.28, y: body.maxY - body.height * 0.22),
        startRadius: 0,
        endCenter: CGPoint(x: body.minX + body.width * 0.28, y: body.maxY - body.height * 0.22),
        endRadius: body.width * 0.55,
        options: []
    )
    context.setBlendMode(.normal)

    // A vignette: the corners fall away, which is what keeps the eye on the
    // glass rather than on the edges of the tile.
    context.setBlendMode(.multiply)
    context.drawRadialGradient(
        gradient([(0xffffff, 1, 0), (0xffffff, 1, 0.55), (0x0a1a22, 1, 1)]),
        startCenter: CGPoint(x: body.midX, y: body.midY),
        startRadius: 0,
        endCenter: CGPoint(x: body.midX, y: body.midY),
        endRadius: body.width * 0.72,
        options: [.drawsAfterEndLocation]
    )
    context.setBlendMode(.normal)

    // --- the glass blade
    //
    // A slab seen at an angle: the far edge is shorter than the near one, which
    // is all the perspective a shape this size can carry. The near long edge is
    // where the light leaves, so that is where the thickness and the spectrum go.
    let width = body.width
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: body.minX + width * x, y: body.minY + width * y)
    }

    // The slab, built from a centre, an axis and a half-width, so the two long
    // edges stay parallel and it reads as one object rather than a bent ribbon.
    // The far end is slightly narrower: that is the whole of the perspective.
    // At 16 points the tilt is what destroys the drawing: every rotated edge is
    // anti-aliased across two pixels and the icon turns to a grey smudge. The
    // smallest size is drawn flat so its edges land on the pixel grid.
    let isTiny = size <= 16
    let angle: CGFloat = isTiny ? 0 : -23 * .pi / 180
    let axis = CGPoint(x: cos(angle), y: sin(angle))
    let normal = CGPoint(x: -sin(angle), y: cos(angle))
    let centre = point(0.475, 0.605)
    // The small artwork is a different drawing, not a smaller one: shorter,
    // thicker, and higher in contrast, because at 16 points a faithful
    // reduction is a grey smudge.
    let halfLength = width * (isTiny ? 0.330 : detail == .small ? 0.285 : 0.300)
    let nearHalf = width * (isTiny ? 0.200 : detail == .small ? 0.165 : 0.140)
    let farHalf = isTiny ? nearHalf : nearHalf * 0.78

    func corner(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
        CGPoint(
            x: centre.x + axis.x * along + normal.x * across,
            y: centre.y + axis.y * along + normal.y * across
        )
    }

    let farTop = corner(-halfLength, farHalf)
    let farBottom = corner(-halfLength, -farHalf)
    let nearTop = corner(halfLength, nearHalf)
    let nearBottom = corner(halfLength, -nearHalf)

    let blade = CGMutablePath()
    blade.move(to: farTop)
    blade.addLine(to: nearTop)
    blade.addLine(to: nearBottom)
    blade.addLine(to: farBottom)
    blade.closeSubpath()

    // The thickness, extruded below the lower long edge.
    let depth = width * (detail == .small ? 0.050 : 0.040)
    let edge = CGMutablePath()
    edge.move(to: farBottom)
    edge.addLine(to: nearBottom)
    edge.addLine(to: CGPoint(x: nearBottom.x, y: nearBottom.y - depth))
    edge.addLine(to: CGPoint(x: farBottom.x, y: farBottom.y - depth * 0.82))
    edge.closeSubpath()

    // Refraction, kept where it belongs: in the thickness of the lower-right
    // edge, with only a little of it escaping. A spectrum drawn large stops
    // reading as light and starts reading as a sticker.
    if detail == .full {
        func onEdge(_ t: CGFloat, drop: CGFloat) -> CGPoint {
            CGPoint(
                x: farBottom.x + (nearBottom.x - farBottom.x) * t,
                y: farBottom.y + (nearBottom.y - farBottom.y) * t - drop
            )
        }

        let spectrum = gradient([
            (0xff4d5e, 0.00, 0.00),
            (0xff5f4d, 1.00, 0.12),
            (0xffb84d, 1.00, 0.30),
            (0xf2ef6a, 1.00, 0.46),
            (0x5cf0a8, 1.00, 0.62),
            (0x4db2ff, 1.00, 0.78),
            (0xa87dff, 0.90, 0.92),
            (0xa87dff, 0.00, 1.00),
        ])

        let from = 0.52 as CGFloat
        let start = onEdge(from, drop: 0)
        let end = onEdge(1.02, drop: 0)

        // The lit part of the edge itself.
        context.saveGState()
        context.setBlendMode(.screen)
        let band = CGMutablePath()
        band.move(to: onEdge(from, drop: depth * 0.15))
        band.addLine(to: onEdge(1.0, drop: depth * 0.15))
        band.addLine(to: onEdge(1.0, drop: depth * 0.95))
        band.addLine(to: onEdge(from, drop: depth * 0.95))
        band.closeSubpath()
        context.addPath(band)
        context.clip()
        context.drawLinearGradient(spectrum, start: start, end: end, options: [])
        context.restoreGState()

    }

    // The lit edge: light concentrated in the thickness of the slab.
    context.saveGState()
    context.addPath(edge)
    context.clip()
    context.drawLinearGradient(
        gradient([(0x9fe6f5, 0.70, 0), (0x54b4cc, 0.50, 0.5), (0x1b6377, 0.60, 1)]),
        start: farBottom,
        end: nearBottom,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

    // The face: cool, translucent, brighter where the light enters.
    context.saveGState()
    context.addPath(blade)
    context.clip()
    context.drawLinearGradient(
        gradient(detail == .small
            ? [(0xf2fbff, 0.62, 0), (0x8ccfe4, 0.42, 1)]
            : [(0xdff4fb, 0.32, 0), (0x74bcd4, 0.13, 0.55), (0x2a6c82, 0.22, 1)]),
        start: corner(-halfLength, nearHalf),
        end: corner(halfLength, -nearHalf),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    if detail != .small {
        // One narrow sweep of specular light across the face.
        context.setBlendMode(.screen)
        context.drawLinearGradient(
            gradient([
                (0xffffff, 0.00, 0.24),
                (0xffffff, 0.26, 0.40),
                (0xffffff, 0.00, 0.54),
            ]),
            start: corner(0, nearHalf),
            end: corner(0, -nearHalf),
            options: []
        )
        context.setBlendMode(.normal)
    }
    context.restoreGState()

    // A reflection inside the glass, parallel to the lit edge and a little way
    // in: the tell that a surface has depth behind it.
    if detail == .full {
        // A streak, not a line: it fades at both ends, so it reads as light
        // lying on the surface rather than as a scratch in it.
        let inset = nearHalf * 0.40
        let thickness = width * 0.016
        let streak = CGMutablePath()
        streak.move(to: corner(-halfLength * 0.78, farHalf - inset + thickness))
        streak.addLine(to: corner(halfLength * 0.84, nearHalf - inset + thickness))
        streak.addLine(to: corner(halfLength * 0.84, nearHalf - inset - thickness))
        streak.addLine(to: corner(-halfLength * 0.78, farHalf - inset - thickness))
        streak.closeSubpath()

        context.saveGState()
        context.addPath(streak)
        context.clip()
        context.setBlendMode(.screen)
        context.drawLinearGradient(
            gradient([
                (0xeaf9ff, 0.00, 0.00),
                (0xeaf9ff, 0.30, 0.30),
                (0xeaf9ff, 0.14, 0.72),
                (0xeaf9ff, 0.00, 1.00),
            ]),
            start: corner(-halfLength * 0.78, 0),
            end: corner(halfLength * 0.84, 0),
            options: []
        )
        context.restoreGState()
    }

    // The upper long edge catches the light; the rest stays quiet.
    let litEdge = CGMutablePath()
    litEdge.move(to: farBottom)
    litEdge.addLine(to: farTop)
    litEdge.addLine(to: nearTop)
    context.addPath(litEdge)
    context.setStrokeColor(color(0xeaf9ff, detail == .small ? 0.92 : 0.74))
    context.setLineWidth(width * (detail == .small ? 0.018 : 0.010))
    context.setLineJoin(.round)
    context.strokePath()

    context.addPath(blade)
    context.setStrokeColor(color(0x9fd8ea, 0.20))
    context.setLineWidth(width * 0.005)
    context.strokePath()

    // The light that leaves the edge, drawn after the glass so the slab does
    // not cover its own glow: the same spectrum, smeared into three widening,
    // fading passes. A bleed along the edge reads as refraction; rays and
    // blooms read as decoration stuck on afterwards.
    if detail == .full {
        func spillPoint(_ t: CGFloat, drop: CGFloat) -> CGPoint {
            CGPoint(
                x: farBottom.x + (nearBottom.x - farBottom.x) * t,
                y: farBottom.y + (nearBottom.y - farBottom.y) * t - drop
            )
        }

        let spectrum = gradient([
            (0xff4d5e, 0.00, 0.00),
            (0xff5f4d, 1.00, 0.12),
            (0xffb84d, 1.00, 0.30),
            (0xf2ef6a, 1.00, 0.46),
            (0x5cf0a8, 1.00, 0.62),
            (0x4db2ff, 1.00, 0.78),
            (0xa87dff, 0.90, 0.92),
            (0xa87dff, 0.00, 1.00),
        ])

        // Twenty-odd thin slices with a square falloff, rather than three wide
        // passes: at three the steps are visible as bands, and a gradient mask
        // inside a transparency layer leaves hard sides.
        let slices = 26
        let travel = depth * 7.5

        context.saveGState()
        context.setBlendMode(.screen)
        for index in 0..<slices {
            let near = CGFloat(index) / CGFloat(slices)
            let far = CGFloat(index + 1) / CGFloat(slices)
            let alpha = 0.30 * pow(1 - near, 2.2)

            context.saveGState()
            context.setAlpha(alpha)
            let slice = CGMutablePath()
            slice.move(to: spillPoint(0.52 - 0.09 * near, drop: depth * 0.2 + travel * near))
            slice.addLine(to: spillPoint(1.03 + 0.05 * near, drop: depth * 0.2 + travel * near))
            slice.addLine(to: spillPoint(1.03 + 0.05 * far, drop: depth * 0.2 + travel * far))
            slice.addLine(to: spillPoint(0.52 - 0.09 * far, drop: depth * 0.2 + travel * far))
            slice.closeSubpath()
            context.addPath(slice)
            context.clip()
            context.drawLinearGradient(
                spectrum,
                start: spillPoint(0.52, drop: 0),
                end: spillPoint(1.03, drop: 0),
                options: []
            )
            context.restoreGState()
        }
        context.restoreGState()
    }

    // --- the caret, cut into the glass
    //
    // Drawn in the slab's own frame so it lies on the surface instead of
    // floating in front of it.
    let caretCentre = centre
    let caretHeight = width * (isTiny ? 0.34 : detail == .small ? 0.27 : 0.150)
    let caretWidth = caretHeight * (isTiny ? 0.50 : detail == .small ? 0.44 : 0.38)

    context.saveGState()
    context.translateBy(x: caretCentre.x, y: caretCentre.y)
    context.rotate(by: angle)
    let caret = CGRect(
        x: -caretWidth / 2,
        y: -caretHeight / 2,
        width: caretWidth,
        height: caretHeight
    )
    let caretPath = CGPath(
        roundedRect: caret,
        cornerWidth: caretWidth * 0.12,
        cornerHeight: caretWidth * 0.12,
        transform: nil
    )

    if detail == .full {
        // The cut: a dark lip on the shaded side, before the light in it.
        // The cut: a dark lip on the shaded side, laid down before the light
        // that fills it.
        context.addPath(CGPath(
            roundedRect: caret.offsetBy(dx: width * 0.008, dy: -width * 0.008),
            cornerWidth: caretWidth * 0.12,
            cornerHeight: caretWidth * 0.12,
            transform: nil
        ))
        context.setFillColor(color(0x02121a, 0.60))
        context.fillPath()
    }

    if detail == .small {
        // A dark surround is what keeps the caret from dissolving into the
        // blade once the two are only a few pixels apart.
        context.addPath(CGPath(
            roundedRect: caret.insetBy(dx: -width * 0.028, dy: -width * 0.022),
            cornerWidth: caretWidth * 0.4,
            cornerHeight: caretWidth * 0.4,
            transform: nil
        ))
        context.setFillColor(color(0x03141c, 0.72))
        context.fillPath()
    }

    if detail != .small {
        context.saveGState()
        context.setShadow(offset: .zero, blur: width * 0.038, color: color(0xa8e6ff, 0.9))
        context.addPath(caretPath)
        context.setFillColor(color(0xf4fcff, 0.98))
        context.fillPath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(caretPath)
    context.clip()
    context.drawLinearGradient(
        gradient([(0xffffff, 1, 0), (0xdff6ff, 1, 0.55), (0x9fd9ee, 1, 1)]),
        start: CGPoint(x: 0, y: caret.maxY),
        end: CGPoint(x: 0, y: caret.minY),
        options: []
    )
    context.restoreGState()
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
