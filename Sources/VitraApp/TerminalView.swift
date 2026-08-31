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
final class TerminalView: NSView, NSMenuItemValidation {
    let session: TerminalSession

    private var renderer: TerminalRenderer
    private let device: MTLDevice
    private let snapshot = RenderSnapshot()
    private var fontName: String
    private var fontSize: CGFloat
    private var padding: CGFloat = 8
    private var opacity: CGFloat = 1

    private var blinkTimer: DispatchSourceTimer?
    private var cursorOn = true

    /// Paused whenever there is nothing to draw, which is most of the time.
    private var displayLink: CADisplayLink?
    private var needsRedraw = true

    /// The key event AppKit is currently interpreting, so `insertText` knows
    /// which physical key produced the text it is handed.
    private var pendingKeyEvent: NSEvent?
    private var keyWasHandledByInput = false
    private var markedText = ""

    private let attachments: AttachmentStore
    private let chips = AttachmentChipView()
    private var isDropTarget = false

    init(
        session: TerminalSession,
        device: MTLDevice,
        fontName: String,
        fontSize: CGFloat,
        attachments: AttachmentStore = AttachmentStore()
    ) throws {
        self.session = session
        self.attachments = attachments
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
        // A view that supplies its own CAMetalLayer owns that layer's contents:
        // AppKit will not call updateLayer() or draw(_:) for it, so redraws have
        // to be driven explicitly.
        layerContentsRedrawPolicy = .never

        session.onNeedsRedraw = { [weak self] in
            self?.setNeedsRender()
        }

        // Files dropped anywhere on the terminal become attachments.
        registerForDraggedTypes([.fileURL])

        chips.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chips)
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            chips.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padding),
            chips.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        blinkTimer?.cancel()
    }

    /// Stops all timers and the display link before the view is discarded.
    func prepareForRemoval() {
        blinkTimer?.cancel()
        blinkTimer = nil
        stopDisplayLink()
    }

    /// Tears down the display link, which cannot be touched from a nonisolated
    /// deinit. Called when the view leaves its window.
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Layer

    /// A border drawn while a drag hovers, so the drop target is obvious.
    private func updateDropHighlight() {
        layer?.borderWidth = isDropTarget ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    /// Takes a new configuration without being rebuilt.
    ///
    /// The font is the expensive part: a different face or size means a new
    /// glyph atlas and new cell metrics, so the renderer is replaced and the
    /// grid recomputed. Everything else is a value change and a redraw.
    func apply(_ config: Config) throws {
        padding = config.padding
        opacity = config.opacity
        session.apply(theme: config.theme)
        session.setScrollback(lines: config.scrollbackLines)

        if config.fontName != fontName || config.fontSize != Double(fontSize) {
            fontName = config.fontName
            fontSize = CGFloat(config.fontSize)
            renderer = try TerminalRenderer(
                device: device,
                fonts: FontSet(name: fontName, size: fontSize * scale)
            )
        }

        if let metalLayer {
            // A translucent window needs a layer that is not claiming to be
            // opaque, or the compositor keeps drawing over what is behind it.
            metalLayer.isOpaque = opacity >= 1
        }
        updateDrawableSize()
        setNeedsRender()
    }

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

    // MARK: - Rendering

    /// Asks for a frame on the next screen refresh.
    ///
    /// The display link is the clock, but it runs only while there is work: it
    /// starts here and pauses itself again as soon as a tick finds nothing
    /// changed. That is what keeps an idle terminal at zero CPU while still
    /// drawing in step with the display.
    func setNeedsRender() {
        needsRedraw = true
        displayLink?.isPaused = false
    }

    private func startDisplayLink() {
        guard displayLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(renderFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsRender()
    }

    @objc private func renderFrame() {
        if session.updateSnapshot(snapshot) { needsRedraw = true }

        guard needsRedraw else {
            // Nothing changed this tick, so stop asking for ticks.
            displayLink?.isPaused = true
            return
        }
        needsRedraw = false
        updateDropHighlight()

        guard let metalLayer, metalLayer.drawableSize.width > 0,
              let drawable = metalLayer.nextDrawable()
        else { return }

        // An unfocused terminal shows a hollow cursor rather than none: it still
        // marks the position without claiming to accept input.
        let focused = window?.isKeyWindow ?? false
        if !focused, var cursor = snapshot.cursor {
            cursor.style = .blockHollow
            snapshot.cursor = cursor
        }

        renderer.draw(
            snapshot: snapshot,
            cursorOn: focused ? cursorOn : true,
            padding: padding * scale,
            opacity: opacity,
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
        guard window != nil else {
            stopDisplayLink()
            return
        }
        updateDrawableSize()
        updateBlinkTimer()
        startDisplayLink()
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
        setNeedsRender()
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
        setNeedsRender()
        return true
    }

    override func resignFirstResponder() -> Bool {
        updateBlinkTimer()
        setNeedsRender()
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
            setNeedsRender()
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
            self.setNeedsRender()
        }
        timer.resume()
        blinkTimer = timer
    }

    // MARK: - Mouse

    /// The cell under a mouse event, clamped to the grid.
    ///
    /// Clamped rather than optional: a drag that leaves the window should extend
    /// the selection to the edge, not stop updating it.
    private func cell(for event: NSEvent) -> (column: UInt16, row: UInt16) {
        let point = convert(event.locationInWindow, from: nil)
        let cellWidth = renderer.metrics.cellWidth / scale
        let cellHeight = renderer.metrics.cellHeight / scale

        let column = Int(((point.x - padding) / cellWidth).rounded(.down))
        let row = Int(((point.y - padding) / cellHeight).rounded(.down))
        return (
            UInt16(clamping: min(max(0, column), Int(snapshot.columns) - 1)),
            UInt16(clamping: min(max(0, row), Int(snapshot.rows) - 1))
        )
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking a pane focuses it; with splits there is more than one.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let position = cell(for: event)
        session.beginSelection(column: position.column, row: position.row, clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        let position = cell(for: event)
        // Option turns the drag into a rectangular selection, the convention
        // every terminal that supports it uses.
        session.extendSelection(
            column: position.column,
            row: position.row,
            rectangle: event.modifierFlags.contains(.option)
        )
    }

    override func mouseUp(with event: NSEvent) {
        session.endSelection()
    }

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

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) {
        guard let text = session.selectedText(), !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        // Files and images on the clipboard become paths, never bytes on the pty.
        let found = PasteboardAttachments.read(from: .general, store: attachments)
        if !found.isEmpty {
            attach(found)
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session.paste(text)
    }

    /// Types the paths of `files` into the prompt and shows them as chips.
    private func attach(_ files: [Attachment]) {
        guard !files.isEmpty else { return }
        // Trailing space so the next thing typed does not run into the path.
        session.paste(ShellQuoting.join(files.map(\.path)) + " ")
        chips.show(files)
        setNeedsRender()
    }

    override func selectAll(_ sender: Any?) {
        session.selectAll()
    }

    /// Clears the screen and the scrollback, the way Cmd-K does everywhere else
    /// on macOS.
    @objc func clearScreen(_ sender: Any?) {
        session.clearScreen()
    }

    /// Greys out Copy when there is nothing selected.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return session.selectedText()?.isEmpty == false
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        default:
            return true
        }
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard PasteboardAttachments.fileURLs(from: sender.draggingPasteboard)?.isEmpty == false else {
            return []
        }
        isDropTarget = true
        setNeedsRender()
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDropTarget = false
        setNeedsRender()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        setNeedsRender()

        guard let urls = PasteboardAttachments.fileURLs(from: sender.draggingPasteboard), !urls.isEmpty
        else { return false }

        window?.makeFirstResponder(self)
        attach(urls.map { Attachment(url: $0, isTemporary: false) })
        return true
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    /// Top-left origin, matching the terminal grid and the renderer, so a mouse
    /// point converts to a cell without flipping y at every call site.
    override var isFlipped: Bool { true }

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

        // Any keystroke means the user wants the live screen back, and no longer
        // cares about whatever was selected.
        session.scrollToBottom()
        session.clearSelection()
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
