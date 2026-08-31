import CoreGraphics
import CoreText
import Foundation
import Metal

/// Where a rasterized glyph lives in the atlas, and how to place it in a cell.
///
/// Coordinates are pixels with y increasing downward, matching the renderer's
/// screen space. `bearingY` is the height of the glyph above the text baseline,
/// so the top edge of the quad is `baseline - bearingY`.
public struct GlyphEntry: Sendable {
    public var u0: Float
    public var v0: Float
    public var u1: Float
    public var v1: Float
    public var bearingX: Float
    public var bearingY: Float
    public var width: Float
    public var height: Float

    /// A glyph with no ink, such as a space.
    static let empty = GlyphEntry(u0: 0, v0: 0, u1: 0, v1: 0, bearingX: 0, bearingY: 0, width: 0, height: 0)

    public var isEmpty: Bool { width == 0 || height == 0 }
}

public enum GlyphAtlasError: Error {
    case textureCreationFailed
    case glyphTooLarge
}

/// A single-channel texture of rasterized glyphs, packed in shelves.
///
/// One texture and one cache for every style variant, so a full grid draws in a
/// single pass with one texture bound. Coverage only — colour comes from the
/// per-cell instance data, which is what lets one rasterization serve every
/// foreground colour the terminal throws at it.
///
/// ponytail: coverage-only means colour emoji render as monochrome silhouettes,
/// because Apple Color Emoji is a colour bitmap font. Fixing it needs a second
/// RGBA sheet and a flag on the glyph entry to pick the sampler.
public final class GlyphAtlas {
    public let texture: MTLTexture
    public let fonts: FontSet

    private let size: Int
    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0

    /// Direct-indexed cache for single-byte ASCII, which is the overwhelming
    /// majority of cells. Four style variants x 128 code points.
    private var asciiCache: [GlyphEntry?]

    /// Everything else: multi-byte clusters, emoji, combining sequences.
    private var clusterCache: [ClusterKey: GlyphEntry] = [:]

    /// Reused rasterization buffer, sized for the largest glyph worth caching.
    private var scratch: UnsafeMutablePointer<UInt8>
    private let scratchSide: Int

    /// A sheet big enough for about fifteen hundred glyphs at this cell size,
    /// rounded up to a power of two and never below 1024.
    ///
    /// A fixed 2048x2048 sheet is 4 MB of texture whatever the font: at a 13pt
    /// cell that is room for twenty thousand glyphs, for a session that draws a
    /// few hundred. A full sheet is not an error — it clears and rasterizes
    /// again — so the cost of guessing low is a little work, not a wrong pixel.
    public static func side(for metrics: FontMetrics) -> Int {
        let area = Double(metrics.cellWidth + 2) * Double(metrics.cellHeight + 2) * 1500
        let exact = area.squareRoot()
        let power = 1 << Int(log2(max(exact, 1)).rounded(.up))
        // Never past 2048: a bigger sheet than that trades 12 MB of texture for
        // fewer resets on a font nobody runs a terminal in.
        return min(2048, max(1024, power))
    }

    public convenience init(device: MTLDevice, fonts: FontSet) throws {
        try self.init(device: device, fonts: fonts, size: GlyphAtlas.side(for: fonts.metrics))
    }

    public init(device: MTLDevice, fonts: FontSet, size: Int) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GlyphAtlasError.textureCreationFailed
        }

        self.texture = texture
        self.fonts = fonts
        self.size = size
        self.asciiCache = Array(repeating: nil, count: 4 * 128)

        // Four cells wide and tall is enough for any single glyph, including the
        // box-drawing and emoji that overflow their advance.
        scratchSide = max(64, Int((max(fonts.metrics.cellWidth, fonts.metrics.cellHeight) * 4).rounded(.up)))
        scratch = .allocate(capacity: scratchSide * scratchSide)
        scratch.initialize(repeating: 0, count: scratchSide * scratchSide)
    }

    deinit {
        scratch.deallocate()
    }

    // MARK: - Lookup

    public func entry(ascii byte: UInt8, bold: Bool, italic: Bool) -> GlyphEntry {
        let index = Self.styleIndex(bold: bold, italic: italic) * 128 + Int(byte)
        if let cached = asciiCache[index] { return cached }

        let entry = rasterize(String(UnicodeScalar(byte)), bold: bold, italic: italic)
        asciiCache[index] = entry
        return entry
    }

    public func entry(cluster: String, bold: Bool, italic: Bool) -> GlyphEntry {
        let key = ClusterKey(cluster: cluster, style: Self.styleIndex(bold: bold, italic: italic))
        if let cached = clusterCache[key] { return cached }

        let entry = rasterize(cluster, bold: bold, italic: italic)
        clusterCache[key] = entry
        return entry
    }

    // MARK: - Rasterization

    private func rasterize(_ text: String, bold: Bool, italic: Bool) -> GlyphEntry {
        let font = fonts.font(bold: bold, italic: italic)
        // kCTFontAttributeName rather than AppKit's .font: the renderer has no
        // reason to pull in AppKit, and Core Text handles font fallback for
        // clusters the base face cannot draw.
        //
        // The colour is not cosmetic here. Core Text defaults to black, and the
        // atlas is a coverage mask on a black background, so without white the
        // glyph is drawn perfectly and is completely invisible.
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: GlyphAtlas.white,
        ])
        let line = CTLineCreateWithAttributedString(attributed)

        // Glyph path bounds, not typographic bounds: the atlas should hold ink,
        // not the font's notion of line box.
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let width = Int(bounds.width.rounded(.up)) + 2
        let height = Int(bounds.height.rounded(.up)) + 2
        guard width > 2, height > 2, width <= scratchSide, height <= scratchSide else {
            return .empty
        }

        guard let region = allocate(width: width, height: height) else { return .empty }

        scratch.update(repeating: 0, count: scratchSide * scratchSide)
        guard let context = CGContext(
            data: scratch,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: scratchSide,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return .empty }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        // Subpixel positioning would make the same glyph rasterize differently per
        // column; the atlas caches one bitmap per glyph, so it must be stable.
        context.setAllowsFontSubpixelPositioning(false)
        context.setShouldSubpixelPositionFonts(false)
        // LCD smoothing writes RGB fringes, which a single-channel coverage mask
        // cannot represent.
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        context.setFillColor(gray: 1, alpha: 1)

        // Place the glyph's ink box at the context origin.
        context.textPosition = CGPoint(x: -bounds.minX + 1, y: -bounds.minY + 1)
        CTLineDraw(line, context)

        texture.replace(
            region: MTLRegionMake2D(region.x, region.y, width, height),
            mipmapLevel: 0,
            withBytes: scratch,
            bytesPerRow: scratchSide
        )

        let inverseSize = Float(1.0 / Double(size))
        let u0 = Float(region.x) * inverseSize
        let u1 = Float(region.x + width) * inverseSize
        // No v flip needed: a Core Graphics bitmap context draws in a bottom-left
        // coordinate system but stores rows top-down, which is the order Metal
        // wants. (Verified against the rasterized bitmap, not assumed.)
        let v0 = Float(region.y) * inverseSize
        let v1 = Float(region.y + height) * inverseSize
        let bearingX = Float(bounds.minX) - 1
        let bearingY = Float(bounds.maxY) + 1

        return GlyphEntry(
            u0: u0,
            v0: v0,
            u1: u1,
            v1: v1,
            bearingX: bearingX,
            bearingY: bearingY,
            width: Float(width),
            height: Float(height)
        )
    }

    // MARK: - Shelf packing

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        if shelfX + width > size {
            shelfX = 0
            shelfY += shelfHeight
            shelfHeight = 0
        }
        if shelfY + height > size {
            // ponytail: full atlas evicts everything and starts over. A 2048x2048
            // sheet holds thousands of glyphs, so this should never fire in a real
            // session; add LRU eviction only if it does.
            reset()
        }

        let position = (x: shelfX, y: shelfY)
        shelfX += width
        shelfHeight = max(shelfHeight, height)
        return position
    }

    private func reset() {
        shelfX = 0
        shelfY = 0
        shelfHeight = 0
        asciiCache = Array(repeating: nil, count: 4 * 128)
        clusterCache.removeAll(keepingCapacity: true)
    }

    private static func styleIndex(bold: Bool, italic: Bool) -> Int {
        (bold ? 1 : 0) | (italic ? 2 : 0)
    }

    /// Cached so every rasterization does not allocate a new colour.
    private static let white = CGColor(colorSpace: CGColorSpaceCreateDeviceGray(), components: [1, 1])!

    private struct ClusterKey: Hashable {
        let cluster: String
        let style: Int
    }
}
