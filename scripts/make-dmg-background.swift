// Draws the .dmg window background: dark, quiet, and only as instructive as it
// needs to be.
//
//   swift scripts/make-dmg-background.swift <output.png>

import AppKit

let size = NSSize(width: 640, height: 400)
let image = NSImage(size: size)
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0x0e2630), color(0x060c11)] as CFArray,
    locations: [0, 1]
)!
context.drawRadialGradient(
    gradient,
    startCenter: CGPoint(x: size.width / 2, y: size.height * 0.72),
    startRadius: 0,
    endCenter: CGPoint(x: size.width / 2, y: size.height * 0.5),
    endRadius: size.width * 0.75,
    options: [.drawsAfterEndLocation]
)

// The arrow between the two icons, drawn as a shape rather than a glyph so it
// sits exactly between them whatever the system font is doing.
let arrow = CGMutablePath()
let midY = size.height * 0.52
arrow.move(to: CGPoint(x: 268, y: midY))
arrow.addLine(to: CGPoint(x: 366, y: midY))
context.addPath(arrow)
context.setStrokeColor(color(0x7fc7de, 0.55))
context.setLineWidth(2)
context.setLineCap(.round)
context.strokePath()

let head = CGMutablePath()
head.move(to: CGPoint(x: 352, y: midY + 9))
head.addLine(to: CGPoint(x: 368, y: midY))
head.addLine(to: CGPoint(x: 352, y: midY - 9))
context.addPath(head)
context.setStrokeColor(color(0x7fc7de, 0.55))
context.setLineWidth(2)
context.setLineJoin(.round)
context.strokePath()

let title = "Drag Vitra into Applications"
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(white: 0.62, alpha: 1),
]
let text = NSAttributedString(string: title, attributes: attributes)
let textSize = text.size()
text.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: size.height * 0.16))

image.unlockFocus()

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dist/dmg-background.png"
if let tiff = image.tiffRepresentation,
   let representation = NSBitmapImageRep(data: tiff),
   let data = representation.representation(using: .png, properties: [:]) {
    try? data.write(to: URL(fileURLWithPath: output))
    print("wrote \(output)")
}
