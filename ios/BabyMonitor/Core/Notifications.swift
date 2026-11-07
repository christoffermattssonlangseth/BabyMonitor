import Foundation
import UserNotifications

enum Notifications {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Posts a local notification right away. `urgent` ones are Time Sensitive:
    /// if you allow it in Settings, they break through Focus modes such as Sleep.
    static func post(title: String, body: String, urgent: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "baby-monitor"
        content.interruptionLevel = urgent ? .timeSensitive : .active
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
