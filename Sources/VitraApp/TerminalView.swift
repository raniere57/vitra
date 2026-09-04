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

final class TerminalView: NSView, NSMenuItemValidation, NSDraggingSource {
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
    var agentSession: String?

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
    private let closeButton = PaneCornerButton(kind: .close)
    private let zoomButton = PaneCornerButton(kind: .zoom)
    private let tabButton = PaneCornerButton(kind: .tab)
    private let gripButton = PaneCornerButton(kind: .grip)

    /// The pane was asked to close from its own corner.
    var onClose: (() -> Void)?

    /// The pane was asked for, or asked to give back, the whole window.
    var onToggleMaximized: (() -> Void)?

    /// The pane was asked to leave for a tab of its own.
    var onMoveToNewTab: (() -> Void)?

    /// A pane is being dragged over this point on screen, so whoever owns the
    /// windows can bring the tab under it to the front.
    var onPaneDragMoved: ((NSPoint) -> Void)?

    /// A pane was dropped on this one; it belongs here now.
    var onPaneDropped: ((TerminalView, PaneEdge) -> Void)?

    /// What a dragged pane puts on the pasteboard. The pane itself travels in
    /// `draggedPane`: it is a live view with a running shell, and nothing about
    /// it can be serialised.
    static let paneType = NSPasteboard.PasteboardType("dev.vitra.pane")
    private(set) static weak var draggedPane: TerminalView?

    /// Whether the corner offers the zoom button at all: one pane in a window
    /// already has the whole window.
    /// Whether the corner offers the arrange buttons at all: one pane in a
    /// window already has the window, and already is the tab.
    var canRearrange = false {
        didSet {
            guard canRearrange != oldValue else { return }
            // The pointer may already be in the pane — splitting it is how it
            // got a sibling — so the buttons appear without waiting for the
            // mouse to leave and come back.
            let hidden = !canRearrange || closeButton.isHidden
            zoomButton.isHidden = hidden
            tabButton.isHidden = hidden
            gripButton.isHidden = hidden
        }
    }

    /// Whether this pane currently holds the window on its own.
    var isMaximized: Bool {
        get { zoomButton.isOn }
        set { zoomButton.isOn = newValue }
    }
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

    /// The side a pane being dragged would land on, while it is over this one.
    private var dropEdge: PaneEdge?

    /// Paints the half a dropped pane would take, so the split is chosen with
    /// the eyes rather than guessed and undone.
    private let dropShade = PassthroughView()

    /// Whether the pane is being drawn at all. See `setDrawingActive`.
    private var isDrawingActive = true

    /// The narrowest a pane can get before its size stops reaching the program.
    /// Narrower than any split this window allows, so only a transient layout —
    /// or a hidden pane — ever falls under it.
    private static let minimumLiveWidth: CGFloat = 100

    /// How thick the focus ring is drawn, in points.
    private static let focusRingWidth: CGFloat = 1

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
        registerForDraggedTypes([.fileURL, TerminalView.paneType])

        blockGutter.autoresizingMask = [.width, .height]
        addSubview(blockGutter)

        scrollIndicator.autoresizingMask = [.width, .height]
        scrollIndicator.isHidden = true
        addSubview(scrollIndicator)
        closeButton.onClick = { [weak self] in self?.onClose?() }
        addSubview(closeButton)
        zoomButton.onClick = { [weak self] in self?.onToggleMaximized?() }
        addSubview(zoomButton)
        tabButton.onClick = { [weak self] in self?.onMoveToNewTab?() }
        addSubview(tabButton)
        gripButton.onDrag = { [weak self] event in self?.beginPaneDrag(with: event) }
        addSubview(gripButton)

        dropShade.wantsLayer = true
        dropShade.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        dropShade.layer?.borderColor = NSColor.controlAccentColor.cgColor
        dropShade.layer?.borderWidth = 2
        dropShade.isHidden = true
        addSubview(dropShade)

        focusBar.wantsLayer = true
        focusBar.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        focusBar.layer?.borderWidth = TerminalView.focusRingWidth
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
            x: bounds.maxX - PaneCornerButton.size - PaneCornerButton.margin,
            // The view is flipped, so the top of the pane is the low y.
            y: bounds.minY + PaneCornerButton.margin,
            width: PaneCornerButton.size,
            height: PaneCornerButton.size
        )
        zoomButton.frame = closeButton.frame.offsetBy(dx: -(PaneCornerButton.size + 4), dy: 0)
        tabButton.frame = zoomButton.frame.offsetBy(dx: -(PaneCornerButton.size + 4), dy: 0)
        gripButton.frame = tabButton.frame.offsetBy(dx: -(PaneCornerButton.size + 4), dy: 0)
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
        agentSession = nil
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
        guard isDrawingActive else { return }
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

    /// Whether this pane is on a screen someone can see.
    ///
    /// A pane in a background tab, a minimised window or a hidden app is not
    /// drawn at all: the display link stops, and the window-sized surfaces the
    /// GPU composites from are handed back. Those surfaces are the single
    /// largest thing this app holds — 25 MB each, two per pane — and macOS
    /// keeps them per layer for as long as the layer has a size, whether or not
    /// anyone is looking. Eight tabs that had each been shown once held 409 MB
    /// of them.
    ///
    /// The shell keeps running and its output keeps being parsed. Only the
    /// drawing stops, and `becameVisible()` starts it again.
    func setDrawingActive(_ active: Bool) {
        guard active != isDrawingActive else { return }
        isDrawingActive = active

        guard active else {
            stopDisplayLink()
            // A one-pixel drawable is the smallest a layer can be asked for, and
            // asking releases the pool it was holding.
            metalLayer?.drawableSize = CGSize(width: 1, height: 1)
            return
        }
        becameVisible()
        startDisplayLink()
    }

    /// Brings the pane back after it was hidden — by the panel taking the whole
    /// window, say. It deliberately did not resize while it could not be seen,
    /// so the size and the drawable are caught up here in one go.
    func becameVisible() {
        updateDrawableSize()
        setNeedsRender()
    }

    private func updateDrawableSize() {
        // Nothing to size while the pane is not being drawn; setDrawingActive
        // puts the real size back on the way in.
        guard isDrawingActive else { return }

        // A hidden pane, or one momentarily squeezed to a sliver by a layout
        // pass, keeps the size it had: following it down would make the program
        // reflow every line it holds, and growing back does not undo that.
        guard let metalLayer, bounds.height > 0,
              bounds.width >= TerminalView.minimumLiveWidth,
              !isHiddenOrHasHiddenAncestor
        else { return }

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

    /// What this pane is called in the shell's environment (`VITRA_PANE`), so
    /// a tool call from an agent running in it finds its way back here.
    var paneID = ""

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
        let base = session.currentDirectory
        guard let url = TerminalLink.match(in: characters, at: Int(position.column), base: base)?.url
        else { return nil }
        // A token shaped like a path is a link only when the file is there:
        // the pointer turns into a hand for one stat, not for every word that
        // happens to carry a dot.
        if url.isFileURL {
            return PreviewTarget.resolve(path: url.path) == nil ? nil : url
        }
        return url
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking a pane focuses it; with splits there is more than one.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let position = cell(for: event)
        pressedCell = position
        // Shift-click extends what is already selected, from wherever it
        // started — the way a long selection is made in every other app, and
        // the way one longer than the pane is made here: click, scroll,
        // shift-click.
        guard !event.modifierFlags.contains(.shift) else {
            session.extendSelection(
                column: position.column,
                row: position.row,
                rectangle: event.modifierFlags.contains(.option)
            )
            return
        }
        session.beginSelection(column: position.column, row: position.row, clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        let position = cell(for: event)
        // Option turns the drag into a rectangular selection, the convention
        // every terminal that supports it uses.
        let rectangle = event.modifierFlags.contains(.option)
        session.extendSelection(column: position.column, row: position.row, rectangle: rectangle)
        updateAutoScroll(for: event, rectangle: rectangle)
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoScroll()
        session.endSelection()

        // A click, not a drag: the pointer never left the cell it went down in,
        // so nothing was being selected and a link under it was meant.
        let position = cell(for: event)
        let moved = pressedCell.map { $0 != position } ?? true
        pressedCell = nil
        guard !moved, event.clickCount == 1 else { return }
        if let url = link(for: event) {
            session.clearSelection()
            onOpenLink?(url, event.modifierFlags.contains(.command))
            return
        }
        placeCursor(at: position, event: event)
    }

    /// A click on the line being typed puts the program's cursor there.
    ///
    /// The terminal cannot move that cursor itself, but it can press the keys
    /// that do: one arrow per cell between where the cursor is and where the
    /// click landed, which every line editor understands. Only the cursor's
    /// own row on the live screen counts, for the same reason the selection
    /// edit stops there — a click in the transcript above is a click, not an
    /// instruction to walk the cursor up into someone else's history.
    private func placeCursor(at position: (column: UInt16, row: UInt16), event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.shift, .option, .command, .control]),
              snapshot.scroll.isAtBottom,
              let cursor = snapshot.cursor,
              cursor.row == position.row
        else { return }
        let delta: Int
        if cursor.row == position.row {
            delta = Int(position.column) - Int(cursor.column)
        } else if position.row < cursor.row, let back = stepsBack(to: position, from: cursor) {
            delta = -back
        } else {
            return
        }
        guard delta != 0, abs(delta) <= Self.cursorWalkLimit else { return }
        let arrow = delta < 0 ? Self.leftArrowKeyCode : Self.rightArrowKeyCode
        for _ in 0 ..< abs(delta) {
            session.send(KeyEvent(keyCode: arrow))
        }
    }

    /// More arrows than a prompt could need is a click somewhere else.
    private static let cursorWalkLimit = 4000

    /// Left presses from the cursor to a click on an earlier row of the same
    /// prompt, or nil when the row is not part of it.
    ///
    /// Up would be the obvious key and is the wrong one: at the first line of
    /// its prompt Claude Code turns Up into history. Left never does — at the
    /// start of a continuation line it steps to the end of the line above —
    /// so the walk is one Left per character, counted across the rows. The
    /// prompt is the row carrying the marker (`❯`) and every row from it down
    /// to the cursor; a wrap is taken as soft, which is what a long sentence
    /// is. A hard line break (Shift-Enter) costs one press more per break than
    /// this counts, and lands a character early.
    private func stepsBack(
        to position: (column: UInt16, row: UInt16),
        from cursor: CursorSnapshot
    ) -> Int? {
        let cursorRow = Int(cursor.row)
        let clickRow = Int(position.row)
        // The prompt's first row: the nearest row above (or the cursor's own)
        // that starts with a one-glyph marker and a space.
        var markerRow: Int?
        for row in stride(from: cursorRow, through: max(0, cursorRow - 60), by: -1) {
            if markerColumn(of: row) != nil { markerRow = row; break }
        }
        guard let markerRow, clickRow >= markerRow else { return nil }

        func textStart(_ row: Int) -> Int {
            if row == markerRow, let marker = markerColumn(of: row) { return marker + 2 }
            return rowCells(row).firstIndex { $0 != " " } ?? 0
        }
        func textEnd(_ row: Int) -> Int {
            rowCells(row).lastIndex { $0 != " " } ?? (textStart(row) - 1)
        }

        // Where on the clicked row the cursor should land: clamped to the
        // text, past-the-end allowed — it is the same place as the start of
        // the next row.
        let target = min(max(Int(position.column), textStart(clickRow)), textEnd(clickRow) + 1)
        var steps = textEnd(clickRow) + 1 - target
        for row in (clickRow + 1) ..< cursorRow {
            steps += max(0, textEnd(row) - textStart(row) + 1)
        }
        steps += max(0, Int(cursor.column) - textStart(cursorRow))
        return steps
    }

    /// The column of a prompt marker at the start of `row` — one glyph that is
    /// not a letter or digit, followed by a space — or nil.
    private func markerColumn(of row: Int) -> Int? {
        let cells = rowCells(row)
        guard let start = cells.firstIndex(where: { $0 != " " }),
              start + 1 < cells.count, cells[start + 1] == " ",
              cells[start].count == 1,
              let glyph = cells[start].first, !(glyph.isLetter || glyph.isNumber)
        else { return nil }
        return start
    }

    /// One string per column of `row`, a space for a blank cell.
    private func rowCells(_ row: Int) -> [String] {
        guard row >= 0, row < Int(snapshot.rows) else { return [] }
        return (0 ..< Int(snapshot.columns)).map { snapshot.text(of: snapshot[$0, row]) ?? " " }
    }

    /// Keeps the viewport moving while a selection drag sits past an edge.
    ///
    /// A drag stops sending events the moment the pointer stops moving, and a
    /// selection that needs three screens of scrollback is a drag that spends
    /// most of its time held still against the bottom of the pane. The anchor
    /// is a position in the screen, not in the viewport, so scrolling under a
    /// held selection extends it rather than moving it.
    private func updateAutoScroll(for event: NSEvent, rectangle: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        // A margin inside the pane as well as outside it: on a window that
        // fills the screen the pointer is stopped at the edge, so a drag that
        // wants more scrollback can never actually leave the pane, and waiting
        // for it to leave means waiting forever.
        let margin = TerminalView.autoScrollMargin
        let beyond: CGFloat
        if point.y < margin {
            beyond = point.y - margin
        } else if point.y > bounds.height - margin {
            beyond = point.y - (bounds.height - margin)
        } else {
            beyond = 0
        }
        guard beyond != 0 else {
            stopAutoScroll()
            return
        }

        // One line per tick at the edge, more the further out the pointer is:
        // a long transcript is unreachable at twenty lines a second.
        let cellHeight = max(renderer.metrics.cellHeight / scale, 1)
        let lines = min(Int(abs(beyond) / cellHeight) + 1, TerminalView.autoScrollMaxLines)
        autoScroll = (beyond < 0 ? -lines : lines, cell(for: event), rectangle)

        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepAutoScroll() }
        }
        // Common modes, because a mouse drag puts the run loop in event
        // tracking and a default-mode timer would never fire during one.
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func stepAutoScroll() {
        guard let state = autoScroll else { return }
        session.scroll(lines: state.lines)
        session.extendSelection(
            column: state.position.column,
            row: state.position.row,
            rectangle: state.rectangle
        )
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScroll = nil
    }

    /// The corner buttons' own cursor over them, the pointing hand over a link,
    /// the I-beam everywhere else.
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let button = cornerButtons.first(where: { !$0.isHidden && $0.frame.contains(point) }) {
            button.cursor.set()
            return
        }
        if link(for: event) != nil { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
    }

    private var cornerButtons: [PaneCornerButton] {
        [closeButton, zoomButton, tabButton, gripButton]
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
        zoomButton.isHidden = !canRearrange
        tabButton.isHidden = !canRearrange
        gripButton.isHidden = !canRearrange
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        closeButton.isHidden = true
        zoomButton.isHidden = true
        tabButton.isHidden = true
        gripButton.isHidden = true
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
        // Shift takes the wheel back from the program. Claude Code and every
        // other full-screen tool ask for the mouse and scroll their own view
        // with it, which leaves no way to reach the terminal's own scrollback —
        // and no way to select what has already scrolled off.
        if snapshot.mouseTracking, !event.modifierFlags.contains(.shift) {
            // The program is about to repaint the same cells with different
            // text, and a selection is a range of cells: left alone it would
            // sit there highlighting whatever landed under it. Ending it is
            // the honest answer — Shift on the wheel is how the terminal's own
            // scrollback is reached, and there a selection does follow its text.
            session.clearSelection()
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
    /// Where a selection drag is pulling the viewport, while it is held past an
    /// edge: how many lines a tick, and the cell the selection ends at.
    private var autoScroll: (lines: Int, position: (column: UInt16, row: UInt16), rectangle: Bool)?
    private var autoScrollTimer: Timer?
    /// Fast enough to cross a long transcript, slow enough to stop on a line.
    private static let autoScrollMaxLines = 6
    /// How far inside the edge a held drag starts pulling the viewport.
    private static let autoScrollMargin: CGFloat = 12
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
        // Inside a program — Claude Code, above all — "all" is the line being
        // typed, not the transcript around it: that is what you select to
        // replace or clear it. In a plain shell the whole screen still wins.
        if session.isRunningProgram, let line = inputLineSpan() {
            session.beginSelection(column: line.start, row: line.row, clickCount: 1)
            session.extendSelection(column: line.end, row: line.row)
            return
        }
        session.selectAll()
    }

    /// The typed text on the cursor's row: first to last non-blank cell, less
    /// a prompt marker in front (`❯`, `>`, `$` — one glyph and a space).
    private func inputLineSpan() -> (row: UInt16, start: UInt16, end: UInt16)? {
        guard snapshot.scroll.isAtBottom, let cursor = snapshot.cursor else { return nil }
        let row = Int(cursor.row)
        let columns = Int(snapshot.columns)
        guard row < Int(snapshot.rows), columns > 0 else { return nil }
        let text = rowCells(row)
        guard var start = text.firstIndex(where: { $0 != " " }),
              let end = text.lastIndex(where: { $0 != " " })
        else { return nil }
        if let marker = markerColumn(of: row) { start = marker + 2 }
        // The marker was the whole line: nothing typed yet.
        guard start <= end else { return nil }
        return (UInt16(row), UInt16(start), UInt16(end))
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
        if isPaneDrag(sender) {
            showDropHalf(for: sender)
            return .move
        }
        guard PasteboardAttachments.fileURLs(from: sender.draggingPasteboard)?.isEmpty == false else {
            return []
        }
        isDropTarget = true
        setNeedsRender()
        return .copy
    }

    /// The edge is answered continuously: a drag that crosses the middle of a
    /// pane means the other side, and the highlight has to say so as it happens.
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isPaneDrag(sender) else { return isDropTarget ? .copy : [] }
        showDropHalf(for: sender)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDropTarget = false
        hideDropHalf()
        setNeedsRender()
    }

    private func showDropHalf(for sender: any NSDraggingInfo) {
        isDropTarget = true
        let point = convert(sender.draggingLocation, from: nil)
        let edge = PaneEdge.nearest(to: point, in: bounds)
        if edge != dropEdge {
            dropEdge = edge
            dropShade.frame = edge.half(of: bounds)
        }
        dropShade.isHidden = false
        setNeedsRender()
    }

    private func hideDropHalf() {
        dropEdge = nil
        dropShade.isHidden = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        let edge = dropEdge ?? .trailing
        hideDropHalf()
        setNeedsRender()

        if isPaneDrag(sender), let dragged = TerminalView.draggedPane {
            onPaneDropped?(dragged, edge)
            return true
        }

        guard let urls = PasteboardAttachments.fileURLs(from: sender.draggingPasteboard), !urls.isEmpty
        else { return false }

        window?.makeFirstResponder(self)
        attach(urls.map { Attachment(url: $0, isTemporary: false) })
        return true
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    /// Where the pane is right now, in screen points.
    ///
    /// This is what makes dropping into another tab possible at all: the tab
    /// bar belongs to AppKit and answers nothing, but the pointer is ours to
    /// follow, and the tab under it can be brought to the front from here.
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        onPaneDragMoved?(screenPoint)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        TerminalView.draggedPane = nil
    }

    /// Whether the drag carries a pane of this app's own.
    private func isPaneDrag(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.availableType(from: [TerminalView.paneType]) != nil,
              let dragged = TerminalView.draggedPane
        else { return false }
        return dragged !== self
    }

    /// Starts carrying this pane, from the corner button that began the drag.
    private func beginPaneDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString("pane", forType: TerminalView.paneType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        // A plate the size of the pane, quarter scale: a Metal layer cannot be
        // asked for a bitmap, and what is being moved is the whole terminal.
        let size = NSSize(width: bounds.width / 4, height: bounds.height / 4)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.16, alpha: 0.92).setFill()
            let plate = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            plate.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            plate.lineWidth = 2
            plate.stroke()
            return true
        }
        let origin = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(
            NSRect(x: origin.x - size.width / 2, y: origin.y - size.height / 2, width: size.width, height: size.height),
            contents: image
        )
        TerminalView.draggedPane = self
        beginDraggingSession(with: [dragItem], event: event, source: self)
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

        // A word selected on the line being typed is replaced by what comes
        // next, the way it is in every other text field.
        if let edit = selectionEdit(for: event) {
            apply(edit)
            if event.keyCode == Self.backspaceKeyCode {
                // The selection *was* the deletion; passing the key on as well
                // would take the character before it too.
                session.clearSelection()
                return
            }
        }

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

    /// The backspace key, by keycode.
    private static let backspaceKeyCode: UInt16 = 0x33
    private static let leftArrowKeyCode: UInt16 = 0x7B
    private static let rightArrowKeyCode: UInt16 = 0x7C

    /// The keystrokes that would delete the selection out of the program's own
    /// line, when there is a selection on the line being typed and a key that
    /// means to replace it.
    private func selectionEdit(for event: NSEvent) -> SelectionEdit? {
        guard replacesSelection(event),
              // The alternate screen is not excluded: the agents this terminal
              // is for draw their prompt there, and their prompt is exactly the
              // line this is for.
              snapshot.scroll.isAtBottom,
              let cursor = snapshot.cursor,
              let span = selectedSpan(),
              span.row == Int(cursor.row)
        else { return nil }
        return SelectionEdit.replacing(
            selectionRow: span.row,
            start: span.start,
            end: span.end,
            cursorRow: Int(cursor.row),
            cursorColumn: Int(cursor.column)
        )
    }

    /// Whether this keystroke is one that would type over a selection: text, or
    /// the backspace that deletes it.
    private func replacesSelection(_ event: NSEvent) -> Bool {
        if event.keyCode == Self.backspaceKeyCode {
            return event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        }
        guard event.modifierFlags.isDisjoint(with: [.command, .control]),
              let characters = event.characters, !characters.isEmpty
        else { return false }
        // Control characters — return, tab, escape — mean something to the
        // program that has nothing to do with what is selected.
        return characters.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    /// The selected cells, when they are all on one row of the viewport.
    private func selectedSpan() -> (row: Int, start: Int, end: Int)? {
        var found: (row: Int, start: Int, end: Int)?
        for row in 0 ..< Int(snapshot.rows) {
            for column in 0 ..< Int(snapshot.columns) where snapshot[column, row].flags.contains(.selected) {
                guard var span = found else {
                    found = (row, column, column)
                    continue
                }
                // A selection reaching a second row is not one word on the line
                // being typed, and is left to the clipboard.
                guard span.row == row else { return nil }
                span.end = column
                found = span
            }
        }
        return found
    }

    /// Presses the arrows and backspaces the edit asks for.
    private func apply(_ edit: SelectionEdit) {
        let arrow = edit.move < 0 ? Self.leftArrowKeyCode : Self.rightArrowKeyCode
        for _ in 0 ..< abs(edit.move) {
            session.send(KeyEvent(keyCode: arrow))
        }
        for _ in 0 ..< edit.backspaces {
            session.send(KeyEvent(keyCode: Self.backspaceKeyCode))
        }
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
