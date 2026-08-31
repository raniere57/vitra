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
/// A view that is only ever decoration: it never takes a click, so a border
/// drawn over the terminal cannot swallow a selection drag.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

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
    private var cursorStyle: CursorStyleSetting = .bar

    /// The Claude Code session this pane was told to resume, while it is still
    /// running one. Set by whoever opened it, cleared when the program ends:
    /// this is what the sessions sidebar marks as "you are here".
    var claudeSession: String?

    /// The last title the program in this pane set, kept per pane rather than
    /// per window: an unfocused split has a title too, and it is how a session
    /// nobody launched from the sidebar is recognised.
    private(set) var programTitle = ""

    func recordTitle(_ title: String) { programTitle = title }

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

    /// One rail per command, drawn in the left padding.
    private let blockGutter = CommandBlockView()
    private let scrollIndicator = ScrollIndicator()
    private let closeButton = PaneCloseButton()

    /// The pane was asked to close from its own corner.
    var onClose: (() -> Void)?
    private var showsCommandBlocks = true

    /// How commands ended, newest first, as the shell reported them.
    ///
    /// Bounded because a session runs for days: only what can be on screen is
    /// ever drawn, and the rest is history nothing asks for.
    private var commandStatuses: [CommandStatus] = []

    /// When the command now running started, and the timer that ticks its clock.
    ///
    /// The timer exists only while something is running: an idle terminal is
    /// supposed to cost nothing, and a clock nobody is watching is exactly the
    /// kind of thing that keeps a laptop awake.
    private var commandStartedAt: Date?
    private var runningTimer: Timer?

    /// The width the marks take from the terminal, zero when they are off.
    private var gutterWidth: CGFloat { showsCommandBlocks ? CommandBlockView.width : 0 }

    /// Marks the pane holding the keyboard when a window has more than one.
    ///
    /// A ring around the whole pane, in the folder's colour, so the mark and the
    /// rail agree. It is a view of its own rather than a border on the terminal's
    /// layer, because that border belongs to the drag-and-drop highlight.
    private let focusBar = PassthroughView()

    /// The colour of that bar — the folder's, when the window has one.
    var focusTint: NSColor = .controlAccentColor {
        didSet {
            focusBar.layer?.borderColor = focusTint.withAlphaComponent(0.9).cgColor
            // The rail on the command you are running now takes the same colour
            // as the focus bar, so a pane's marks all say the same thing.
            blockGutter.currentRailColor = focusTint.withAlphaComponent(0.8)
            blockGutter.needsDisplay = true
        }
    }
    private var isDropTarget = false

    /// How thick the focus ring is drawn, in points.
    private static let focusRingWidth: CGFloat = 2

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

        blockGutter.autoresizingMask = [.width, .height]
        addSubview(blockGutter)

        scrollIndicator.autoresizingMask = [.width, .height]
        scrollIndicator.isHidden = true
        addSubview(scrollIndicator)
        closeButton.onClose = { [weak self] in self?.onClose?() }
        addSubview(closeButton)

        focusBar.wantsLayer = true
        focusBar.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        focusBar.layer?.borderWidth = TerminalView.focusRingWidth
        focusBar.layer?.cornerRadius = 5
        focusBar.autoresizingMask = [.width, .height]
        focusBar.isHidden = true
        addSubview(focusBar)

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
        runningTimer?.invalidate()
        runningTimer = nil
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

        // The rails take their colour from the theme, not from the system: a
        // grey that reads as quiet on one background is invisible on another.
        showsCommandBlocks = config.commandBlocks
        cursorStyle = config.cursorStyle
        blockGutter.isHidden = !config.commandBlocks
        let foreground = NSColor(hex: config.theme.foreground.hex) ?? .white
        scrollIndicator.color = foreground.withAlphaComponent(0.30)
        blockGutter.railColor = foreground.withAlphaComponent(0.22)
        blockGutter.labelColor = foreground.withAlphaComponent(0.45)
        blockGutter.separatorColor = foreground.withAlphaComponent(0.10)
        // Status colours come from the theme's own red and green, so a light
        // theme does not get a neon rail beside every failed command.
        blockGutter.failureColor = NSColor(hex: config.theme.palette[9].hex) ?? blockGutter.failureColor
        blockGutter.successColor = NSColor(hex: config.theme.palette[10].hex) ?? blockGutter.successColor
        blockGutter.runningColor = NSColor(hex: config.theme.palette[11].hex) ?? blockGutter.runningColor
        blockGutter.needsDisplay = true

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
        // Two drawables, not the default three. Each one is a full-window
        // IOSurface — 27 MB on this display — and a terminal that draws only
        // when the screen changes never has three frames in flight. Measured:
        // 106 MB of footprint for one window becomes 79 MB.
        layer.maximumDrawableCount = 2
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
        updateCommandBlocks()

        guard let metalLayer, metalLayer.drawableSize.width > 0,
              let drawable = metalLayer.nextDrawable()
        else { return }

        // An unfocused terminal shows a hollow cursor rather than none: it still
        // marks the position without claiming to accept input.
        let focused = window?.isKeyWindow ?? false
        if var cursor = snapshot.cursor {
            // Unfocused wins over both: a hollow cursor still marks the position
            // without claiming to accept input.
            if let style = focused ? cursorStyle.style : .blockHollow {
                cursor.style = style
                snapshot.cursor = cursor
            }
        }

        renderer.draw(
            snapshot: snapshot,
            cursorOn: focused ? cursorOn : true,
            padding: padding * scale,
            gutter: gutterWidth * scale,
            opacity: opacity,
            drawable: drawable,
            viewportSize: metalLayer.drawableSize
        )
    }

    /// Hands the gutter this frame's command blocks.
    private func updateCommandBlocks() {
        scrollIndicator.frame = bounds
        closeButton.frame = NSRect(
            x: bounds.maxX - PaneCloseButton.size - PaneCloseButton.margin,
            // The view is flipped, so the top of the pane is the low y.
            y: bounds.minY + PaneCloseButton.margin,
            width: PaneCloseButton.size,
            height: PaneCloseButton.size
        )
        scrollIndicator.update(snapshot.scroll)
        guard showsCommandBlocks else { return }
        blockGutter.frame = bounds
        blockGutter.update(
            blocks: snapshot.commandBlocks,
            statuses: commandStatuses,
            running: commandStartedAt.map { Date().timeIntervalSince($0) },
            cellHeight: renderer.metrics.cellHeight / scale,
            padding: padding
        )
    }

    /// Records how the command that just finished ended.
    func record(_ status: CommandStatus) {
        // The command that ended is the one that was resuming a session, so the
        // pane is in no session now. Cleared here rather than on every refresh:
        // a shell takes a moment to start what it was handed, and a mark that
        // clears itself in that gap never appears at all.
        claudeSession = nil
        commandStatuses.insert(status, at: 0)
        if commandStatuses.count > 200 { commandStatuses.removeLast() }
        commandStartedAt = nil
        runningTimer?.invalidate()
        runningTimer = nil
        setNeedsRender()
    }

    /// Drops the running clock to one tick a second, once the command is long.
    private func slowRunningTimer() {
        guard runningTimer?.timeInterval != 1 else { return }
        runningTimer?.invalidate()
        runningTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCommandBlocks() }
        }
    }

    /// Starts the clock shown beside a command while it runs.
    func commandStarted() {
        commandStartedAt = Date()
        runningTimer?.invalidate()
        // Tenths while the command is short enough for tenths to matter, then
        // once a second: a shell left open inside ssh should not wake the CPU
        // ten times a second for an hour.
        runningTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateCommandBlocks()
                if let started = self.commandStartedAt, Date().timeIntervalSince(started) > 15 {
                    self.slowRunningTimer()
                }
            }
        }
        setNeedsRender()
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

        let grid = renderer.gridSize(for: pixelSize, padding: padding * scale, gutter: gutterWidth * scale)
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
        updateFocusIndicator()
        setNeedsRender()
        onFocused?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        updateBlinkTimer()
        // The border is drawn after the responder change lands, because AppKit
        // asks the old responder to resign before the new one becomes first and
        // reading `firstResponder` here would still name this pane.
        DispatchQueue.main.async { [weak self] in self?.updateFocusIndicator() }
        setNeedsRender()
        return true
    }

    /// Called when this pane takes the keyboard, so the window can point the
    /// sidebars at the folder this shell is in rather than the last one's.
    var onFocused: (() -> Void)?
    /// A link the user clicked: the flag is true when they held Command, which
    /// means their browser rather than the panel.
    var onOpenLink: ((URL, Bool) -> Void)?

    /// Whether this pane should show which one has the keyboard.
    ///
    /// Off for a lone pane: a border around the only thing on screen says
    /// nothing, and a terminal has little enough chrome as it is.
    var showsFocusIndicator = false {
        didSet { updateFocusIndicator() }
    }

    private func updateFocusIndicator() {
        focusBar.frame = bounds.insetBy(dx: TerminalView.focusRingWidth / 2, dy: TerminalView.focusRingWidth / 2)
        focusBar.isHidden = !(showsFocusIndicator && window?.firstResponder === self)
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

        let column = Int(((point.x - padding - gutterWidth) / cellWidth).rounded(.down))
        let row = Int(((point.y - padding) / cellHeight).rounded(.down))
        return (
            UInt16(clamping: min(max(0, column), Int(snapshot.columns) - 1)),
            UInt16(clamping: min(max(0, row), Int(snapshot.rows) - 1))
        )
    }

    /// The link under a mouse event, if the pointer is on one.
    private func link(for event: NSEvent) -> URL? {
        let position = cell(for: event)
        let row = Int(position.row)
        guard row < Int(snapshot.rows) else { return nil }

        // One character per column, blanks included, so what comes back is in
        // the same coordinates the click arrived in.
        var characters: [Character] = []
        characters.reserveCapacity(Int(snapshot.columns))
        for column in 0 ..< Int(snapshot.columns) {
            let cell = snapshot[column, row]
            characters.append(snapshot.text(of: cell)?.first ?? " ")
        }
        return TerminalLink.match(in: characters, at: Int(position.column))?.url
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking a pane focuses it; with splits there is more than one.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let position = cell(for: event)
        pressedCell = position
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

        // A click, not a drag: the pointer never left the cell it went down in,
        // so nothing was being selected and a link under it was meant.
        let position = cell(for: event)
        let moved = pressedCell.map { $0 != position } ?? true
        pressedCell = nil
        guard !moved, event.clickCount == 1, let url = link(for: event) else { return }
        session.clearSelection()
        onOpenLink?(url, event.modifierFlags.contains(.command))
    }

    /// The pointing hand over a link, the I-beam everywhere else.
    override func mouseMoved(with event: NSEvent) {
        if link(for: event) != nil { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
    }

    override func layout() {
        super.layout()
        // The overlays follow the pane's size; the button lives in the corner
        // whether or not a frame has been drawn since the last resize.
        updateCommandBlocks()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTracking { removeTrackingArea(linkTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        linkTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        closeButton.isHidden = true
    }

    /// What the viewport is doing right now, for a measured run to print.
    var scrollState: String {
        "alt=\(snapshot.isAlternateScreen) mouse=\(snapshot.mouseTracking)"
            + " sgr=\(snapshot.sgrMouse) total=\(snapshot.scroll.total)"
            + " offset=\(snapshot.scroll.offset) visible=\(snapshot.scroll.visible)"
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
        guard lines != 0 else { return }

        // Who the wheel belongs to depends on what the program asked for.
        //
        // A program watching the mouse gets the wheel as a mouse report: that is
        // how a full-screen tool scrolls its own transcript, and it is the only
        // thing that works on the alternate screen, which has no scrollback of
        // its own to move through. A full-screen program that never asked about
        // the mouse gets arrow keys instead — xterm's alternate scroll, and what
        // makes a pager follow the wheel. Everything else scrolls the viewport.
        if ProcessInfo.processInfo.environment["VITRA_DEBUG_WHEEL"] != nil {
            FileHandle.standardError.write(Data(
                "[wheel] lines=\(lines) mouse=\(snapshot.mouseTracking) alt=\(snapshot.isAlternateScreen)\n".utf8
            ))
        }
        if snapshot.mouseTracking {
            report(wheel: lines, at: cell(for: event))
        } else if snapshot.isAlternateScreen {
            // Up is 126 and Down is 125; the encoder is what knows whether the
            // program wants the application-cursor form of them.
            let keyCode: UInt16 = lines > 0 ? 126 : 125
            for _ in 0 ..< min(abs(lines), 24) {
                session.send(KeyEvent(keyCode: keyCode))
            }
        } else {
            session.scroll(lines: -lines)
        }
    }

    /// Sends the wheel to the program as a mouse report.
    ///
    /// Button 64 is a notch up and 65 a notch down, and both are reported as
    /// presses: the wheel has no release. SGR is preferred because the legacy
    /// encoding runs out of room at column 223.
    private func report(wheel lines: Int, at position: (column: UInt16, row: UInt16)) {
        let button = lines > 0 ? 64 : 65
        let column = Int(position.column) + 1
        let row = Int(position.row) + 1

        let report: String
        if snapshot.sgrMouse {
            report = "\u{1b}[<\(button);\(column);\(row)M"
        } else {
            // 32 is the offset the original encoding adds to every field, and
            // the fields are single bytes, so anything past 223 cannot be said.
            guard column <= 223, row <= 223 else { return }
            report = "\u{1b}[M"
                + String(UnicodeScalar(UInt8(32 + button)))
                + String(UnicodeScalar(UInt8(32 + column)))
                + String(UnicodeScalar(UInt8(32 + row)))
        }

        for _ in 0 ..< min(abs(lines), 24) { session.send(text: report) }
    }

    private var scrollAccumulator: CGFloat = 0
    private var pressedCell: (column: UInt16, row: UInt16)?
    private var linkTracking: NSTrackingArea?

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

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateFocusIndicator()
    }

    /// Top-left origin, matching the terminal grid and the renderer, so a mouse
    /// point converts to a cell without flipping y at every call site.
    override var isFlipped: Bool { true }

    /// The macOS line-editing chords, in the bytes a shell understands.
    ///
    /// Command is not a terminal modifier - there is no escape sequence for it -
    /// so a terminal either translates these or the whole Mac convention stops
    /// working inside it. Every shell's line editor already has the moves;
    /// these are the keys the rest of the system uses to ask for them.
    private static let commandChords: [UInt16: String] = [
        51: "\u{15}",   // Backspace: kill to the start of the line (Ctrl-U)
        117: "\u{0B}",  // Forward delete: kill to the end of it (Ctrl-K)
        123: "\u{01}",  // Left: start of the line (Ctrl-A)
        124: "\u{05}",  // Right: end of the line (Ctrl-E)
    ]

    /// Page keys that scroll the terminal instead of reaching the program.
    ///
    /// Shift is what every terminal uses to say "this one is for you, not for
    /// what is running", and it is the only way back through the scrollback
    /// that does not need a hand on the trackpad.
    private func scrolled(by event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.shift) else { return false }
        let page = max(1, Int(snapshot.rows) - 2)
        switch event.keyCode {
        case 116: session.scroll(lines: -page)   // Page Up
        case 121: session.scroll(lines: page)    // Page Down
        case 115: session.scroll(lines: -Int(snapshot.scroll.total))  // Home
        case 119: session.scrollToBottom()       // End
        default: return false
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if scrolled(by: event) { return }

        // Command belongs to the app, not the terminal: it drives the menu.
        if event.modifierFlags.contains(.command) {
            let others: NSEvent.ModifierFlags = [.option, .control, .shift]
            if event.modifierFlags.isDisjoint(with: others),
               let chord = Self.commandChords[event.keyCode] {
                session.send(text: chord)
                session.scrollToBottom()
                session.clearSelection()
                return
            }
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
            x: padding + gutterWidth + CGFloat(cursor.column) * cellWidth,
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
