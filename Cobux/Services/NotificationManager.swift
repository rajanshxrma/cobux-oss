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

    /// Batch generation can finish while the app is closed (Anthropic's Batch API takes up
    /// to ~24h) -- without this, the only way to know a book's questions are ready was
    /// remembering to open the app and manually tap "Check Status." Fires immediately
    /// (a 1-second trigger, the minimum `UNTimeIntervalNotificationTrigger` allows, rather
    /// than a calendar-scheduled one) since this is reporting something that already
    /// happened, not scheduling something for later.
    func notifyBatchGenerationComplete(bookTitle: String, questionsInserted: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Cobux"
        content.body = questionsInserted > 0
            ? "\(bookTitle)'s background quiz generation finished — \(questionsInserted) question\(questionsInserted == 1 ? "" : "s") ready."
            : "\(bookTitle)'s background quiz generation finished."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "cobux_batch_generation_complete", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func getPendingCount() async -> Int {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests.count
    }
}
