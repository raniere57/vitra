import AppKit
import CoreGraphics

/// `Cmd-Q` has to be held before it quits.
///
/// A terminal is the one app where the quit key is a keystroke away from the
/// keys that end a job — `Cmd-W`, and a shell's own `Ctrl-D` — and losing four
/// running sessions to a slip is not a trade anyone made on purpose. Held for a
/// second, with the plate on screen saying so, it is still one gesture.
@MainActor
final class HoldToQuit {
    /// How long the keys stay down before the app goes.
    static let hold: TimeInterval = 1.0

    private var monitor: Any?
    private var timer: Timer?
    private var startedAt: Date?
    private var plate: QuitPlate?

    /// Watches for `Cmd-Q` and answers it instead of the menu.
    ///
    /// A local monitor sees the key before the menu's own equivalent does, so
    /// swallowing it here is what keeps the press from quitting outright. The
    /// menu item is left alone: choosing Quit with the pointer is deliberate in
    /// a way a keystroke is not.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control),
                  event.charactersIgnoringModifiers?.lowercased() == "q"
            else { return event }
            self?.begin()
            return nil
        }
    }

    private func begin() {
        guard timer == nil else { return }
        startedAt = Date()
        plate = QuitPlate()
        plate?.show()

        // The keys are polled rather than waited on: macOS does not deliver a
        // key-up while Command is down, so the only honest answer to "is it
        // still held" comes from the keyboard itself.
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        guard let startedAt else { return }
        let held = Date().timeIntervalSince(startedAt)
        guard Self.isHeld else {
            cancel()
            return
        }
        plate?.progress = min(held / Self.hold, 1)
        guard held >= Self.hold else { return }
        cancel(lingering: false)
        NSApp.terminate(nil)
    }

    /// Whether Command and Q are both down, asked of the hardware.
    private static var isHeld: Bool {
        let q: CGKeyCode = 0x0C
        return NSEvent.modifierFlags.contains(.command)
            && CGEventSource.keyState(.combinedSessionState, key: q)
    }

    /// Stops watching. The plate stays a moment on a tap that let go too soon:
    /// the point of it is to teach the gesture, and a plate that vanishes with
    /// the keystroke is a flicker nobody reads.
    private func cancel(lingering: Bool = true) {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        plate?.dismiss(after: lingering ? Self.linger : 0)
        plate = nil
    }

    /// How long the plate stays after the keys are let go.
    private static let linger: TimeInterval = 1.1
}

/// The "hold to quit" plate, centred on the screen the pointer is on.
@MainActor
private final class QuitPlate {
    private let window: NSWindow
    private let bar = NSView()
    private var barWidth: NSLayoutConstraint?

    /// 0 to 1, filling the bar under the words.
    var progress: Double = 0 {
        didSet {
            barWidth?.constant = QuitPlate.size.width * 0.62 * progress
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private static let size = NSSize(width: 260, height: 92)

    init() {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: QuitPlate.size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.alphaValue = 0

        let content = NSView(frame: NSRect(origin: .zero, size: QuitPlate.size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.92).cgColor
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor

        let label = NSTextField(labelWithString: "Hold ⌘Q to quit")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let track = NSView()
        track.wantsLayer = true
        track.layer?.cornerRadius = 2
        track.layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        track.translatesAutoresizingMaskIntoConstraints = false

        bar.wantsLayer = true
        bar.layer?.cornerRadius = 2
        bar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(label)
        content.addSubview(track)
        track.addSubview(bar)
        let width = bar.widthAnchor.constraint(equalToConstant: 0)
        barWidth = width
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),

            track.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            track.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 14),
            track.widthAnchor.constraint(equalToConstant: QuitPlate.size.width * 0.62),
            track.heightAnchor.constraint(equalToConstant: 4),

            bar.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            bar.topAnchor.constraint(equalTo: track.topAnchor),
            bar.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            width,
        ])
        window.contentView = content
    }

    func show() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            window.setFrameOrigin(
                NSPoint(
                    x: frame.midX - QuitPlate.size.width / 2,
                    // A little below centre, where a HUD sits on this system.
                    y: frame.minY + frame.height * 0.22
                )
            )
        }
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }
    }

    func dismiss(after delay: TimeInterval = 0) {
        guard delay <= 0 else {
            // Strongly: whoever asked has already let go of this plate, and it
            // has to outlive them long enough to be read.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.dismiss() }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 0
        } completionHandler: { [window] in
            window.orderOut(nil)
        }
    }
}
