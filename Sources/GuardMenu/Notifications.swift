import AppKit
import UserNotifications
import GuardKit

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private var seen = Set<String>()
    private var initialized = false

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("通知授权失败：%@", error.localizedDescription) }
        }
    }

    func notifyCritical(_ snapshot: Snapshot) {
        let events: [GuardEvent]
        if initialized {
            events = snapshot.events.filter { !seen.contains($0.id) }
        } else {
            // Do not replay historical activity when the app relaunches.
            events = []
            initialized = true
        }
        seen = Set(snapshot.events.map(\.id))
        guard snapshot.settings.notificationsEnabled else { return }
        for event in events where event.title.contains("不满足要求") || event.title.contains("关闭了") || event.title == "代理已恢复" {
            deliver(id: event.id, title: event.title, body: event.detail)
        }
    }

    private func deliver(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Route Guard · \(title)"
        content.body = body
        content.sound = .default
        content.threadIdentifier = "route-guard.protection"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("发送通知失败：%@", error.localizedDescription) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
