import AppKit
import Metal
import QuartzCore
import VitraCore
import VitraRender

/// The terminal grid, drawn with Metal and driven entirely on demand.
///
/// There is no display link and no animation timer running at rest. A frame
/// happens only when the emulator reports the screen changed, when the cursor
/// blinks, or when the view resizes, which is what keeps the app at zero CPU
/// while idle.
final class TerminalView: NSView {
    let session: TerminalSession

    private var renderer: TerminalRenderer
    private let device: MTLDevice
    private let snapshot = RenderSnapshot()
    private var fontName: String
    private var fontSize: CGFloat
    private let padding: CGFloat = 8

    private var blinkTimer: DispatchSourceTimer?
    private var cursorOn = true

    /// The key event AppKit is currently interpreting, so `insertText` knows
    /// which physical key produced the text it is handed.
    private var pendingKeyEvent: NSEvent?
    private var keyWasHandledByInput = false
    private var markedText = ""

    init(session: TerminalSession, device: MTLDevice, fontName: String, fontSize: CGFloat) throws {
        self.session = session
        self.device = device
        self.fontName = fontName
        self.fontSize = fontSize
        // The renderer works in pixels throughout, so the font is loaded at the
        // backing scale and the grid math never has to think about points again.
        self.renderer = try TerminalRenderer(
            device: device,
            fonts: FontSet(name: fontName, size: fontSize * 2)
        )

        super.init(frame: .zero)

        wantsLayer = true
        // updateLayer() runs inside AppKit's own display cycle, which is already
        // aligned to the screen refresh. No CVDisplayLink needed.
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        session.onNeedsRedraw = { [weak self] in
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        blinkTimer?.cancel()
    }

    // MARK: - Layer

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        // Draw from the top-left so resizing does not scale stale content.
        layer.autoresizingMask = []
        layer.needsDisplayOnBoundsChange = false
        return layer
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let metalLayer, let drawable = metalLayer.nextDrawable() else { return }

        // Skip the frame only when nothing changed *and* a snapshot already
        // exists; the first frame must draw even though the terminal is empty.
        let changed = session.updateSnapshot(snapshot)
        if !changed && snapshot.columns == 0 { return }

        renderer.draw(
            snapshot: snapshot,
            cursorOn: cursorOn && (window?.isKeyWindow ?? false),
            padding: padding * scale,
            drawable: drawable,
            viewportSize: metalLayer.drawableSize
        )
    }

    // MARK: - Geometry

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        updateBlinkTimer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Moving between a Retina and a non-Retina display changes how many
        // pixels a point is worth, so the glyphs have to be rasterized again.
        if let renderer = try? TerminalRenderer(
            device: device,
            fonts: FontSet(name: fontName, size: fontSize * scale)
        ) {
            self.renderer = renderer
        }
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer, bounds.width > 0, bounds.height > 0 else { return }

        metalLayer.contentsScale = scale
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metalLayer.drawableSize = pixelSize

        let grid = renderer.gridSize(for: pixelSize, padding: padding * scale)
        session.resize(to: TerminalSize(
            columns: UInt16(grid.columns),
            rows: UInt16(grid.rows),
            // Programs that draw inline images read cell pixel dimensions from
            // the window size, so they have to be real numbers.
            pixelWidth: UInt16(clamping: Int(pixelSize.width)),
            pixelHeight: UInt16(clamping: Int(pixelSize.height))
        ))
        needsDisplay = true
    }

    /// The window size that shows exactly `columns` x `rows` cells.
    func idealSize(columns: Int, rows: Int) -> NSSize {
        let pixels = renderer.pixelSize(columns: columns, rows: rows, padding: padding * scale)
        return NSSize(width: pixels.width / scale, height: pixels.height / scale)
    }

    var backgroundColor: NSColor {
        let background = snapshot.defaultBackground
        return NSColor(
            srgbRed: CGFloat(background.red) / 255,
            green: CGFloat(background.green) / 255,
            blue: CGFloat(background.blue) / 255,
            alpha: 1
        )
    }

    // MARK: - Cursor blink

    override func becomeFirstResponder() -> Bool {
        updateBlinkTimer()
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        updateBlinkTimer()
        needsDisplay = true
        return true
    }

    /// Runs the blink timer only while the window has focus.
    ///
    /// A background window with a blinking cursor would wake the CPU twice a
    /// second forever, which is exactly the idle cost this design exists to avoid.
    func updateBlinkTimer() {
        blinkTimer?.cancel()
        blinkTimer = nil
        cursorOn = true

        guard window?.isKeyWindow == true else {
            needsDisplay = true
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Only blink when the terminal asked for a blinking cursor; plenty of
            // programs turn it off, and honouring that keeps the app idle.
            guard self.snapshot.cursor?.isBlinking == true else { return }
            self.cursorOn.toggle()
            self.needsDisplay = true
        }
        timer.resume()
        blinkTimer = timer
    }

    // MARK: - Mouse

    override func scrollWheel(with event: NSEvent) {
        let lines: Int
        if event.hasPreciseScrollingDeltas {
            // Trackpad deltas are in points; convert with the cell height so a
            // gesture scrolls the same distance it looks like it should.
            scrollAccumulator += event.scrollingDeltaY
            let cellHeight = renderer.metrics.cellHeight / scale
            lines = Int((scrollAccumulator / cellHeight).rounded(.towardZero))
            scrollAccumulator -= CGFloat(lines) * cellHeight
        } else {
            lines = Int(event.scrollingDeltaY.rounded())
        }
        // ponytail: always scrolls the viewport. Forwarding to the application in
        // alternate-screen mode comes with mouse reporting in the next phase.
        session.scroll(lines: -lines)
    }

    private var scrollAccumulator: CGFloat = 0

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Command belongs to the app, not the terminal: it drives the menu.
        guard !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }

        pendingKeyEvent = event
        keyWasHandledByInput = false

        // Let the input context run first so dead keys and IMEs compose. It calls
        // back into insertText/setMarkedText, which is where the real send happens.
        _ = inputContext?.handleEvent(event)

        if !keyWasHandledByInput && markedText.isEmpty {
            send(event: event, text: "")
        }
        pendingKeyEvent = nil

        // Any keystroke means the user wants to see the live screen again.
        session.scrollToBottom()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
    }

    private func send(event: NSEvent, text: String) {
        session.send(KeyEvent(
            action: event.isARepeat ? .repeated : .press,
            keyCode: event.keyCode,
            modifiers: KeyModifiers(event.modifierFlags),
            text: text,
            unshiftedCodepoint: Self.unshiftedCodepoint(of: event)
        ))
    }

    /// The codepoint the key produces with no modifiers, which the Kitty keyboard
    /// protocol reports as the base key.
    private static func unshiftedCodepoint(of event: NSEvent) -> UInt32 {
        guard let characters = event.charactersIgnoringModifiers,
              let scalar = characters.unicodeScalars.first
        else { return 0 }
        return scalar.value
    }
}

// MARK: - Text input

// NSTextInputClient predates Swift concurrency; the protocol is not annotated,
// but AppKit only ever calls it on the main thread.
extension TerminalView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        keyWasHandledByInput = true
        guard !text.isEmpty else { return }

        if let event = pendingKeyEvent {
            // Still a keystroke: let the encoder apply modifiers to it.
            send(event: event, text: text)
        } else {
            // Committed IME text with no originating key, e.g. a candidate chosen
            // from the input method's own window.
            session.send(text: text)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        keyWasHandledByInput = true
    }

    func unmarkText() {
        markedText = ""
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.count)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the input method should place its candidate window: at the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window, let cursor = snapshot.cursor else { return .zero }
        let cellWidth = renderer.metrics.cellWidth / scale
        let cellHeight = renderer.metrics.cellHeight / scale
        let local = NSRect(
            x: padding + CGFloat(cursor.column) * cellWidth,
            y: bounds.height - padding - CGFloat(cursor.row + 1) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    override func doCommand(by selector: Selector) {
        // The terminal encodes its own control keys; AppKit's editing commands
        // (moveUp:, deleteBackward:, insertNewline:) must not swallow them.
        keyWasHandledByInput = false
    }
}

extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        self = modifiers
    }
}
