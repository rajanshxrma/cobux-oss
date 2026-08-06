import Foundation
import UserNotifications

@Observable
class NotificationManager {
    var isAuthorized: Bool = false

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
            }
        }
    }

    func checkAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.isAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }

    func scheduleWisdomReminders(highlights: [Highlight], times: [DateComponents]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        guard !highlights.isEmpty, !times.isEmpty else { return }

        let maxNotifications = 60
        let notificationsPerTime = max(1, maxNotifications / times.count)

        var scheduledCount = 0

        for timeComponents in times {
            guard scheduledCount < maxNotifications else { break }

            let shuffledHighlights = highlights.shuffled()
            let highlightsForTime = Array(shuffledHighlights.prefix(notificationsPerTime))

            for (index, highlight) in highlightsForTime.enumerated() {
                guard scheduledCount < maxNotifications else { break }

                let content = UNMutableNotificationContent()
                content.title = "Cobux 📚"
                content.subtitle = highlight.book?.author ?? "Your Library"
                content.body = highlight.text
                content.sound = .default

                var triggerComponents = DateComponents()
                triggerComponents.hour = timeComponents.hour
                triggerComponents.minute = timeComponents.minute

                let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: true)

                let identifier = "cobux_wisdom_\(timeComponents.hour ?? 0)_\(timeComponents.minute ?? 0)_\(index)"
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

                center.add(request) { _ in }
                scheduledCount += 1
            }
        }
    }

    func cancelAllReminders() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    func getPendingCount() async -> Int {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests.count
    }
}
