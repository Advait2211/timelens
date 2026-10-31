import AppKit
import UserNotifications

/// Local notifications: limit warnings, break reminders, focus endings and summaries.
/// Clicking one opens the dashboard on the page it's about.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private(set) var isAvailable = false
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// Notifications need a real bundle; `swift run` has none.
    func setUp() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        isAvailable = true
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        guard isAvailable else { return }
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        return granted
    }

    func send(id: String = UUID().uuidString, title: String, body: String, section: String? = nil, sound: Bool = true) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        if let section { content.userInfo = ["section": section] }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            if authorization == .notDetermined { await requestAuthorization() }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let section = response.notification.request.content.userInfo["section"] as? String
        await MainActor.run {
            NotificationCenter.default.post(name: .openDashboard, object: nil, userInfo: section.map { ["section": $0] })
        }
    }
}

extension Notification.Name {
    static let openDashboard = Notification.Name("com.advait.timelens.openDashboard")
}
