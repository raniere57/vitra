import AppKit
import CoreGraphics

/// ⌘Q only quits when it is held.
///
/// ⌘Q sits beside ⌘W, and a slip there would end every project's maestro at
/// once. A tap shows what to do instead; holding the keys for a moment quits.
/// Choosing the menu item with the pointer is deliberate already and quits at
/// once.
@MainActor
final class QuitHold {
    static let holdFor: TimeInterval = 1.0
    private static let checkEvery: TimeInterval = 0.05
    private static let qKey: CGKeyCode = 12

    private var began: Date?
    private var timer: Timer?
    private var notice: NSView?

    /// Whether a hold that began at `began` has earned the quit by `now`.
    static func isLongEnough(from began: Date, to now: Date) -> Bool {
        now.timeIntervalSince(began) >= holdFor
    }

    /// The menu item's action.
    func requested(in window: NSWindow?) {
        guard NSApp.currentEvent?.type == .keyDown else {
            NSApp.terminate(nil)
            return
        }
        // The key repeats while it is held; the hold that is running counts.
        guard began == nil else { return }
        began = Date()
        show(in: window)
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard let began else { return }
        let isHeld = CGEventSource.keyState(.combinedSessionState, key: Self.qKey)
            && NSEvent.modifierFlags.contains(.command)
        guard isHeld else {
            stop()
            return
        }
        if Self.isLongEnough(from: began, to: Date()) {
            stop()
            NSApp.terminate(nil)
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        began = nil
        // Left up for a moment after a tap, or it would flash by unread.
        let notice = self.notice
        self.notice = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { notice?.removeFromSuperview() }
    }

    func show(in window: NSWindow?) {
        guard notice == nil, let content = window?.contentView else { return }
        let label = NSTextField.label("Segure ⌘Q para encerrar o Vitra", font: CockpitStyle.ui(13, .medium), color: CockpitStyle.text)
        let pill = NSView.filled(CockpitStyle.raised, cornerRadius: 12)
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = CockpitStyle.controlLine.cgColor
        pill.addSubview(label)
        content.addSubview(pill)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -18),
            pill.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        NSAccessibility.post(element: pill, notification: .announcementRequested, userInfo: [
            .announcement: label.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        notice = pill
    }
}
