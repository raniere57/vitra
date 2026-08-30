import CoreGraphics
import Foundation
import ImageIO
import Metal
import QuartzCore
import VitraCore
import simd

struct CellInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
    var uvMin: SIMD2<Float>
    var uvMax: SIMD2<Float>
}

private struct Uniforms {
    var viewportSize: SIMD2<Float>
}

public enum RendererError: Error, CustomStringConvertible {
    case shaderLibraryUnavailable
    case pipelineCreationFailed(String)

    public var description: String {
        switch self {
        case .shaderLibraryUnavailable: "Metal shader library could not be loaded"
        case let .pipelineCreationFailed(reason): "render pipeline creation failed: \(reason)"
        }
    }
}

/// Draws a `RenderSnapshot` into a Metal drawable.
///
/// Everything on screen is one rectangle primitive, so a frame is one draw call
/// regardless of how much of the grid changed. The instance buffer is grown once
/// and refilled in place, so a steady-state redraw allocates nothing.
public final class TerminalRenderer {
    public let atlas: GlyphAtlas
    public var metrics: FontMetrics { atlas.fonts.metrics }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private var instances: [CellInstance] = []
    private var instanceBuffer: MTLBuffer?
    private var instanceCapacity = 0

    /// Extra colour applied to selected cells, blended over their background.
    public var selectionColor = TerminalColor(red: 60, green: 90, blue: 140)

    public init(device: MTLDevice, fonts: FontSet) throws {
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.pipelineCreationFailed("no command queue")
        }
        self.device = device
        self.commandQueue = queue
        self.atlas = try GlyphAtlas(device: device, fonts: fonts)

        let library = try Self.loadShaderLibrary(device: device)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "cell_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cell_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Glyphs arrive as coverage masks, so they must blend over whatever
        // background was already drawn rather than replace it.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RendererError.pipelineCreationFailed(String(describing: error))
        }
    }

    /// Loads the shader library, precompiled if available and from source if not.
    ///
    /// Xcode compiles `.metal` files into a `default.metallib`; `swift build` does
    /// not, it just copies the source into the resource bundle. Supporting both
    /// keeps `swift build` usable for development without giving up the
    /// precompiled library in release builds.
    private static func loadShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let library = try? device.makeDefaultLibrary(bundle: .module) {
            return library
        }
        guard let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw RendererError.shaderLibraryUnavailable
        }
        return try device.makeLibrary(source: source, options: nil)
    }

    /// The pixel size needed to show `columns` x `rows` cells.
    public func pixelSize(columns: Int, rows: Int, padding: CGFloat = 0) -> CGSize {
        CGSize(
            width: CGFloat(columns) * metrics.cellWidth + padding * 2,
            height: CGFloat(rows) * metrics.cellHeight + padding * 2
        )
    }

    /// The largest grid that fits in `pixelSize`.
    public func gridSize(for pixelSize: CGSize, padding: CGFloat = 0) -> (columns: Int, rows: Int) {
        let usableWidth = max(0, pixelSize.width - padding * 2)
        let usableHeight = max(0, pixelSize.height - padding * 2)
        return (
            max(1, Int(usableWidth / metrics.cellWidth)),
            max(1, Int(usableHeight / metrics.cellHeight))
        )
    }

    // MARK: - Drawing

    public func draw(
        snapshot: RenderSnapshot,
        cursorOn: Bool,
        padding: CGFloat,
        drawable: CAMetalDrawable,
        viewportSize: CGSize
    ) {
        guard let commandBuffer = encode(
            snapshot: snapshot,
            cursorOn: cursorOn,
            padding: padding,
            target: drawable.texture,
            viewportSize: viewportSize
        ) else { return }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Renders into `target` and waits for the GPU, for offscreen use.
    public func render(
        snapshot: RenderSnapshot,
        cursorOn: Bool,
        padding: CGFloat,
        into target: MTLTexture
    ) {
        let size = CGSize(width: target.width, height: target.height)
        guard let commandBuffer = encode(
            snapshot: snapshot,
            cursorOn: cursorOn,
            padding: padding,
            target: target,
            viewportSize: size
        ) else { return }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func encode(
        snapshot: RenderSnapshot,
        cursorOn: Bool,
        padding: CGFloat,
        target: MTLTexture,
        viewportSize: CGSize
    ) -> MTLCommandBuffer? {
        build(from: snapshot, cursorOn: cursorOn, padding: padding)
        // An empty instance list still needs the pass: the clear is what paints
        // the terminal background, and skipping it leaves the drawable undefined.
        let buffer: MTLBuffer? = uploadInstances() ? instanceBuffer : nil

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = snapshot.defaultBackground.clearColor

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return nil }

        if !instances.isEmpty, let buffer {
            var uniforms = Uniforms(
                viewportSize: SIMD2(Float(viewportSize.width), Float(viewportSize.height))
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: instances.count
            )
        }

        encoder.endEncoding()
        return commandBuffer
    }

    // MARK: - Instance building

    /// Fills `instances` in draw order: backgrounds, then the cursor block, then
    /// glyphs, then decorations. Order in the buffer is order on screen.
    private func build(from snapshot: RenderSnapshot, cursorOn: Bool, padding: CGFloat) {
        instances.removeAll(keepingCapacity: true)

        let cellWidth = Float(metrics.cellWidth)
        let cellHeight = Float(metrics.cellHeight)
        let originX = Float(padding)
        let originY = Float(padding)
        let defaultBackground = snapshot.defaultBackground

        let cursor = cursorOn ? snapshot.cursor : nil
        // Only a filled block replaces the cell's colours; hollow and thin
        // cursors draw over whatever is already there.
        let cursorIsBlock = cursor?.style == .block

        for row in 0 ..< Int(snapshot.rows) {
            let y = originY + Float(row) * cellHeight
            for column in 0 ..< Int(snapshot.columns) {
                let cell = snapshot[column, row]
                let x = originX + Float(column) * cellWidth
                var (foreground, background) = resolvedColors(of: cell, in: snapshot)

                let isCursorCell = cursorIsBlock
                    && cursor?.column == UInt16(column)
                    && cursor?.row == UInt16(row)

                if background != defaultBackground {
                    instances.append(CellInstance(
                        origin: SIMD2(x, y),
                        size: SIMD2(cellWidth, cellHeight),
                        color: background.simd,
                        uvMin: .zero,
                        uvMax: .zero
                    ))
                }

                if isCursorCell, let cursor {
                    // Block cursor paints the cell, so the glyph on top of it has to
                    // switch to the background colour to stay readable.
                    instances.append(CellInstance(
                        origin: SIMD2(x, y),
                        size: SIMD2(cellWidth, cellHeight),
                        color: cursor.color.simd,
                        uvMin: .zero,
                        uvMax: .zero
                    ))
                    foreground = background
                }

                appendGlyph(for: cell, in: snapshot, x: x, y: y, color: foreground)
                appendDecorations(for: cell, x: x, y: y, cellWidth: cellWidth, color: foreground)
            }
        }

        if let cursor, !cursorIsBlock {
            appendThinCursor(cursor, cellWidth: cellWidth, cellHeight: cellHeight, padding: padding)
        }
    }

    private func resolvedColors(
        of cell: RenderCell,
        in snapshot: RenderSnapshot
    ) -> (foreground: TerminalColor, background: TerminalColor) {
        var foreground = cell.foreground
        var background = cell.background

        if cell.flags.contains(.inverse) { swap(&foreground, &background) }
        if cell.flags.contains(.selected) { background = selectionColor }
        if cell.flags.contains(.invisible) { foreground = background }
        // Faint is conventionally rendered as a dimmer foreground, not a separate
        // colour, so it composites correctly against any background.
        if cell.flags.contains(.faint) { foreground = foreground.dimmed() }

        return (foreground, background)
    }

    private func appendGlyph(
        for cell: RenderCell,
        in snapshot: RenderSnapshot,
        x: Float,
        y: Float,
        color: TerminalColor
    ) {
        guard !cell.isBlank else { return }

        let bold = cell.flags.contains(.bold)
        let italic = cell.flags.contains(.italic)

        // ASCII is the common case and resolves without building a String.
        let entry: GlyphEntry
        if cell.textLength == 1,
           let byte = snapshot.withText(of: cell, { $0[0] }), byte < 0x80 {
            guard byte != 0x20 else { return }
            entry = atlas.entry(ascii: byte, bold: bold, italic: italic)
        } else {
            guard let cluster = snapshot.text(of: cell) else { return }
            entry = atlas.entry(cluster: cluster, bold: bold, italic: italic)
        }
        guard !entry.isEmpty else { return }

        instances.append(CellInstance(
            origin: SIMD2(x + entry.bearingX, y + Float(metrics.baseline) - entry.bearingY),
            size: SIMD2(entry.width, entry.height),
            color: color.simd,
            uvMin: SIMD2(entry.u0, entry.v0),
            uvMax: SIMD2(entry.u1, entry.v1)
        ))
    }

    private func appendDecorations(
        for cell: RenderCell,
        x: Float,
        y: Float,
        cellWidth: Float,
        color: TerminalColor
    ) {
        let thickness = Float(metrics.underlineThickness)
        if cell.flags.contains(.underline) {
            instances.append(CellInstance(
                origin: SIMD2(x, y + Float(metrics.underlinePosition)),
                size: SIMD2(cellWidth, thickness),
                color: color.simd,
                uvMin: .zero,
                uvMax: .zero
            ))
        }
        if cell.flags.contains(.strikethrough) {
            instances.append(CellInstance(
                origin: SIMD2(x, y + Float(metrics.baseline) * 0.7),
                size: SIMD2(cellWidth, thickness),
                color: color.simd,
                uvMin: .zero,
                uvMax: .zero
            ))
        }
        if cell.flags.contains(.overline) {
            instances.append(CellInstance(
                origin: SIMD2(x, y),
                size: SIMD2(cellWidth, thickness),
                color: color.simd,
                uvMin: .zero,
                uvMax: .zero
            ))
        }
    }

    private func appendThinCursor(
        _ cursor: CursorSnapshot,
        cellWidth: Float,
        cellHeight: Float,
        padding: CGFloat
    ) {
        let x = Float(padding) + Float(cursor.column) * cellWidth
        let y = Float(padding) + Float(cursor.row) * cellHeight
        let thickness = max(1, Float(metrics.underlineThickness))

        func solid(_ origin: SIMD2<Float>, _ size: SIMD2<Float>) {
            instances.append(CellInstance(
                origin: origin,
                size: size,
                color: cursor.color.simd,
                uvMin: .zero,
                uvMax: .zero
            ))
        }

        switch cursor.style {
        case .bar:
            solid(SIMD2(x, y), SIMD2(thickness, cellHeight))
        case .underline:
            solid(SIMD2(x, y + cellHeight - thickness), SIMD2(cellWidth, thickness))
        case .blockHollow, .block:
            // Four edges. This is what an unfocused terminal shows, and drawing
            // it as an outline keeps the character underneath readable.
            solid(SIMD2(x, y), SIMD2(cellWidth, thickness))
            solid(SIMD2(x, y + cellHeight - thickness), SIMD2(cellWidth, thickness))
            solid(SIMD2(x, y), SIMD2(thickness, cellHeight))
            solid(SIMD2(x + cellWidth - thickness, y), SIMD2(thickness, cellHeight))
        }
    }

    // MARK: - Buffers

    private func uploadInstances() -> Bool {
        guard !instances.isEmpty else { return true }

        if instanceCapacity < instances.count {
            // Grow with headroom so a busy screen does not reallocate every frame.
            let capacity = max(instances.count * 2, 4096)
            guard let buffer = device.makeBuffer(
                length: capacity * MemoryLayout<CellInstance>.stride,
                options: .storageModeShared
            ) else { return false }
            instanceBuffer = buffer
            instanceCapacity = capacity
        }

        guard let buffer = instanceBuffer else { return false }
        instances.withUnsafeBytes { source in
            buffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        return true
    }
}

// MARK: - Colour conversion

extension TerminalColor {
    var simd: SIMD4<Float> {
        SIMD4(Float(red) / 255, Float(green) / 255, Float(blue) / 255, 1)
    }

    var clearColor: MTLClearColor {
        MTLClearColor(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            alpha: 1
        )
    }

    /// SGR 2 (faint): half intensity, the conventional rendering.
    func dimmed() -> TerminalColor {
        TerminalColor(red: red / 2, green: green / 2, blue: blue / 2)
    }
}

// MARK: - Offscreen image

public extension TerminalRenderer {
    /// Renders a snapshot to an image, with no window or drawable involved.
    ///
    /// This is how the terminal can be inspected and regression-tested from a
    /// headless process: the same code path that fills the screen also fills a
    /// bitmap.
    func renderImage(
        snapshot: RenderSnapshot,
        cursorOn: Bool = true,
        padding: CGFloat = 0
    ) -> CGImage? {
        let size = pixelSize(
            columns: Int(snapshot.columns),
            rows: Int(snapshot.rows),
            padding: padding
        )
        guard size.width >= 1, size.height >= 1 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else { return nil }

        render(snapshot: snapshot, cursorOn: cursorOn, padding: padding, into: target)

        let bytesPerRow = target.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * target.height)
        pixels.withUnsafeMutableBytes { buffer in
            target.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, target.width, target.height),
                mipmapLevel: 0
            )
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
