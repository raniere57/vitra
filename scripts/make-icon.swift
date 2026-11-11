// Draws Vitra's icon with Core Graphics and writes every size the .icns needs.
//
// The mark is the cockpit's own stage, read as a V: one lit core at the bottom
// — the maestro — with two beams rising to workers that sit on its orbit, and
// other workers, in their providers' tints, travelling the same rings.
// Graphite and amber, the cockpit's colours, with amber kept for the one
// thing that is live.
//
// Core Graphics rather than SVG: the glow and the squircle are easier to
// control directly, and one pass produces every size with the artwork
// simplified per size instead of downscaled.
//
//   swift scripts/make-icon.swift <output-directory>

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

/// Everything is drawn on a 1024 canvas and scaled to the size asked for.
let canvas: CGFloat = 1024

/// Apple's macOS template: the art occupies 824 of a 1024 canvas, leaving the
/// margin the system expects for shadows and alignment with other icons.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185

/// The three points of the V, in canvas units with y growing upwards.
let vertex = CGPoint(x: 512, y: 318)
let leftTip = CGPoint(x: 322, y: 706)
let rightTip = CGPoint(x: 702, y: 706)

/// How much of the artwork a given size can carry.
///
/// Small sizes are a different drawing, not a smaller one: a faithful
/// reduction of the full artwork is a grey smudge.
enum Detail {
    case full     // 256 and up: lit tile, glow, ringed nodes
    case medium   // 64 and 128: no glow gradients, heavier arms and nodes
    case small    // 32 and below: the V and the maestro, as heavy as they go

    init(size: Int) {
        switch size {
        case 256...: self = .full
        case 64...: self = .medium
        default: self = .small
        }
    }

    var armWidth: CGFloat {
        switch self {
        case .full: return 58
        case .medium: return 76
        case .small: return 132
        }
    }

    var nodeRadius: CGFloat {
        switch self {
        case .full: return 92
        case .medium: return 100
        case .small: return 122
        }
    }

    /// The workers at the tips of the arms. Drawn as nodes of their own so the
    /// mark reads as three things connected, not as one bent stroke; at the
    /// smallest sizes the arm's round end is all there is room for.
    var workerRadius: CGFloat? {
        switch self {
        case .full: return 54
        case .medium: return 62
        case .small: return nil
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
    return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: stops.map { $0.2 })!
}

func circle(_ centre: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
}

// MARK: - Drawing

func drawIcon(size: Int) -> CGImage {
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
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let tile = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // --- the tile: graphite, lighter at the top where the light comes from
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(
        gradient([(0x262B36, 1, 0), (0x141720, 1, 0.5), (0x090A0E, 1, 1)]),
        start: CGPoint(x: 512, y: body.maxY),
        end: CGPoint(x: 512, y: body.minY),
        options: []
    )

    if detail == .full {
        // The maestro lights the tile around itself.
        context.drawRadialGradient(
            gradient([(0xE8A33D, 0.34, 0), (0xE8A33D, 0.10, 0.45), (0xE8A33D, 0, 1)]),
            startCenter: vertex, startRadius: 0,
            endCenter: vertex, endRadius: 470,
            options: []
        )
        // A soft sheen across the top edge, as glass has.
        context.drawLinearGradient(
            gradient([(0xFFFFFF, 0.10, 0), (0xFFFFFF, 0, 1)]),
            start: CGPoint(x: 512, y: body.maxY),
            end: CGPoint(x: 512, y: body.maxY - 230),
            options: []
        )
    }

    // --- the orbits: the stage the cockpit draws, centred on the maestro.
    // The outer one passes through the tips of the V, so the two workers it
    // reaches are simply the nearest of those in orbit.
    if detail != .small {
        let outer = hypot(leftTip.x - vertex.x, leftTip.y - vertex.y)
        let inner = outer * 0.58
        context.setLineWidth(detail == .full ? 5 : 8)
        context.setStrokeColor(color(0xFFFFFF, detail == .full ? 0.13 : 0.16))
        context.strokeEllipse(in: circle(vertex, outer))
        context.setStrokeColor(color(0xFFFFFF, detail == .full ? 0.09 : 0.12))
        context.strokeEllipse(in: circle(vertex, inner))

        // Workers that are not being spoken to right now: smaller, tinted.
        let others: [(radius: CGFloat, degrees: CGFloat, tint: UInt32, size: CGFloat)] = [
            (outer, 90, 0x7FB2E5, 30),
            (inner, 158, 0xA596E8, 24),
            (inner, 36, 0x86D0A6, 20),
        ]
        for other in others {
            let angle = other.degrees * .pi / 180
            let centre = CGPoint(x: vertex.x + cos(angle) * other.radius, y: vertex.y + sin(angle) * other.radius)
            context.saveGState()
            if detail == .full {
                context.setShadow(offset: .zero, blur: 26, color: color(other.tint, 0.75))
            }
            context.setFillColor(color(other.tint))
            context.fillEllipse(in: circle(centre, detail == .full ? other.size : other.size * 1.25))
            context.restoreGState()
        }
    }

    // --- the arms: maestro to workers
    let arms = CGMutablePath()
    arms.move(to: leftTip)
    arms.addLine(to: vertex)
    arms.addLine(to: rightTip)

    context.saveGState()
    if detail == .full {
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x000000, 0.55))
    }
    context.addPath(arms)
    context.setLineWidth(detail.armWidth)
    context.replacePathWithStrokedPath()
    context.clip()
    // Bright at the workers, warming towards the maestro they answer to.
    context.drawLinearGradient(
        gradient([(0xFBF8F1, 1, 0), (0xE9E6DF, 1, 0.55), (0xF0C98A, 1, 1)]),
        start: CGPoint(x: 512, y: leftTip.y + detail.armWidth / 2),
        end: CGPoint(x: 512, y: vertex.y - detail.armWidth / 2),
        options: []
    )
    context.restoreGState()

    // --- the workers
    if let radius = detail.workerRadius {
        for tip in [leftTip, rightTip] {
            context.saveGState()
            if detail == .full {
                context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.5))
            }
            context.setFillColor(color(0xFBF8F1))
            context.fillEllipse(in: circle(tip, radius))
            context.restoreGState()
        }
    }

    // --- the maestro
    context.saveGState()
    if detail != .small {
        context.setShadow(offset: .zero, blur: detail == .full ? 70 : 40, color: color(0xE8A33D, 0.9))
    }
    context.setFillColor(color(0xE8A33D))
    context.fillEllipse(in: circle(vertex, detail.nodeRadius))
    context.restoreGState()

    if detail == .full {
        // Lit from above, like everything else on the tile.
        context.saveGState()
        context.addEllipse(in: circle(vertex, detail.nodeRadius))
        context.clip()
        context.drawRadialGradient(
            gradient([(0xFFE2A8, 0.95, 0), (0xF2B04A, 0.4, 0.55), (0xC9831F, 0, 1)]),
            startCenter: CGPoint(x: vertex.x - 22, y: vertex.y + 30), startRadius: 0,
            endCenter: vertex, endRadius: detail.nodeRadius * 1.15,
            options: []
        )
        context.restoreGState()
        // The ring that separates the node from the arms it sits on.
        context.setStrokeColor(color(0x14161A, 0.9))
        context.setLineWidth(10)
        context.strokeEllipse(in: circle(vertex, detail.nodeRadius + 5))
        // And the one the stage draws around a maestro at work.
        context.setStrokeColor(color(0xE8A33D, 0.55))
        context.setLineWidth(6)
        context.strokeEllipse(in: circle(vertex, detail.nodeRadius + 34))
    }
    context.restoreGState()

    // --- the rim of the tile itself
    if detail != .small {
        context.addPath(tile)
        context.setStrokeColor(color(0xFFFFFF, 0.10))
        context.setLineWidth(4)
        context.strokePath()
    }

    return context.makeImage()!
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) {
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: image.width, height: image.height)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not encode \(url.lastPathComponent)\n".utf8))
        exit(1)
    }
    do {
        try data.write(to: url)
    } catch {
        FileHandle.standardError.write(Data("could not write \(url.path): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let arguments = CommandLine.arguments
let outputDirectory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "dist/icon")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(drawIcon(size: size), to: outputDirectory.appendingPathComponent("icon_\(size).png"))
}
print("wrote icons to \(outputDirectory.path)")
