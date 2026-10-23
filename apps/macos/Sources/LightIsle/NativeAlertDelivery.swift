import Foundation
import UserNotifications

/// Explicit opt-in, low-volume local notifications for important NAS failures.
/// No Web API, notification server, or extra background process is installed.
@MainActor
final class NativeAlertDelivery {
    private var lastDelivered: [String: Date] = [:]

    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func deliver(key: String, title: String, description: String) {
        let now = Date()
        if let last = lastDelivered[key], now.timeIntervalSince(last) < 3600 { return }
        lastDelivered[key] = now
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = description
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("LightIsle local notification unavailable: %@", error.localizedDescription) }
        }
    }

    func clear(key: String) {
        lastDelivered.removeValue(forKey: key)
    }
}
