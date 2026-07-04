import Foundation
import UserNotifications

enum CaptureReminderScheduler {
    private static let identifierPrefix = "capture-reminder-"

    static func scheduleReminder(for item: CaptureItem) {
        guard item.kind == .todo,
              !item.isCompleted,
              let reminderAt = item.reminderAt else { return }

        let interval = reminderAt.timeIntervalSinceNow
        guard interval > 1 else { return }

        let identifier = notificationIdentifier(for: item.id)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("[CaptureReminderScheduler] Authorization error: \(error)")
            }
            guard granted else {
                print("[CaptureReminderScheduler] Notification permission denied")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "待办提醒"
            content.body = item.text
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            center.add(request) { error in
                if let error {
                    print("[CaptureReminderScheduler] Schedule error: \(error)")
                }
            }
        }
    }

    static func cancelReminder(for id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [notificationIdentifier(for: id)]
        )
    }

    static func reschedulePendingReminders(for items: [CaptureItem]) {
        for item in items {
            scheduleReminder(for: item)
        }
    }

    private static func notificationIdentifier(for id: UUID) -> String {
        "\(identifierPrefix)\(id.uuidString)"
    }
}
