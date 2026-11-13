import AppKit
import UserNotifications

/// The macOS side of "the maestro is waiting": a notification, a short sound,
/// and the click that brings the project back. What decides *when* is
/// `AttentionThrottle`.
@MainActor
final class AttentionAlerts: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let projectKey = "project"
    private static let soundName = "Glass"

    /// Called with a project's path when its notification is clicked.
    var onOpen: ((String) -> Void)?

    /// Notifications need an app bundle: from a bare `swift run` binary the
    /// system has no identity to post them under, and asking for the center
    /// raises.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func alert(project: String, name: String, body: String) {
        NSSound(named: Self.soundName)?.play()
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = body
        content.userInfo = [Self.projectKey: project]
        // One per project: a newer one replaces the older instead of stacking.
        let request = UNNotificationRequest(identifier: "attention-" + project, content: content, trigger: nil)
        // Asked the first time there is something to say, not at launch — and
        // the notification waits for the answer: posted before it, the system
        // drops it and the first wait goes by with a sound and no banner.
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(request) { _ in }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let project = response.notification.request.content.userInfo[Self.projectKey] as? String else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            onOpen?(project)
        }
    }

    /// The app may be in front on another project: the banner is still the point.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
