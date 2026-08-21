import Foundation
import UserNotifications

@Observable
class NotificationManager {
    var isAuthorized: Bool = false

    /// Every notification this app schedules carries one of these namespaced
    /// identifier prefixes, and every cancellation is scoped to a prefix.
    /// The old implementation called `removeAllPendingNotificationRequests()`
    /// on each wisdom reschedule, which would silently wipe any other
    /// notification type added later — that's the exact failure mode this
    /// namespace exists to prevent.
    private enum Namespace {
        static let wisdom = "cobux.wisdom."
        static let streakAtRisk = "cobux.streak.atRisk"
        static let morningReview = "cobux.review.morning"
        static let batchComplete = "cobux.batch.complete"
        /// Pre-2.3.0 identifier formats, swept once so upgraded installs don't
        /// hold slots of the 64-request system cap forever.
        static let legacyPrefixes = ["cobux_wisdom_", "cobux_batch_generation_complete"]
    }

    /// 48 wisdom + 1 at-risk + 1 morning review + 1 batch-complete = 51 of
    /// iOS's 64 pending-request cap, leaving headroom for future types. (Was
    /// 60 when wisdom reminders were the only notification in the app.)
    private static let maxWisdomNotifications = 48

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
            }
        }
    }

    /// The streak/review nudges shouldn't force a permission dialog on someone
    /// who never opted into notifications — provisional delivery goes quietly
    /// to Notification Center, and upgrades automatically if the user already
    /// granted full permission via the wisdom-reminders toggle.
    func requestProvisionalPermissionIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .provisional])
    }

    func checkAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.isAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }

    /// Removes pending requests whose identifier starts with any given prefix.
    /// Must be awaited BEFORE adding replacements — fetching pending requests
    /// is async, and a fire-and-forget removal can race the adds that follow.
    private func removePending(withPrefixes prefixes: [String]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let doomed = pending.map(\.identifier).filter { id in
            prefixes.contains { id.hasPrefix($0) }
        }
        guard !doomed.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: doomed)
    }

    /// Belt-and-suspenders for the Build-5 SwiftData relationship-fault crash
    /// class: the map below faults every `Highlight.book` relationship, which
    /// is lethal while the background seed/upgrade merge is mid-transaction.
    /// `RemindersView` doesn't gate its call on this today, so this stays safe
    /// the same way `WatchSyncService.sync(books:)` does. A skipped schedule
    /// self-heals — the next toggle flip, time change, or "Force Refresh"
    /// tap in Reminders re-triggers it.
    @MainActor
    func scheduleWisdomReminders(highlights: [Highlight], times: [DateComponents]) {
        guard !SeedingStatus.shared.isSeeding else { return }

        // Snapshot the model-object fields synchronously — the awaited removal
        // below suspends, and SwiftData objects shouldn't cross that boundary.
        let payloads: [(text: String, author: String)] = highlights.map {
            (Self.truncatedForNotification($0.text, maxLength: 280), Self.truncatedForNotification($0.book?.author ?? "Your Library", maxLength: 60))
        }

        Task {
            let center = UNUserNotificationCenter.current()
            await removePending(withPrefixes: [Namespace.wisdom] + Namespace.legacyPrefixes)

            guard !payloads.isEmpty, !times.isEmpty else { return }

            let notificationsPerTime = max(1, Self.maxWisdomNotifications / times.count)
            var scheduledCount = 0

            for timeComponents in times {
                guard scheduledCount < Self.maxWisdomNotifications else { break }

                let shuffled = payloads.shuffled()
                let payloadsForTime = Array(shuffled.prefix(notificationsPerTime))

                for (index, payload) in payloadsForTime.enumerated() {
                    guard scheduledCount < Self.maxWisdomNotifications else { break }

                    let content = UNMutableNotificationContent()
                    content.title = "Cobux"
                    content.subtitle = payload.author
                    content.body = payload.text
                    content.sound = .default

                    var triggerComponents = DateComponents()
                    triggerComponents.hour = timeComponents.hour
                    triggerComponents.minute = timeComponents.minute

                    let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: true)

                    let identifier = "\(Namespace.wisdom)\(timeComponents.hour ?? 0)_\(timeComponents.minute ?? 0)_\(index)"
                    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

                    try? await center.add(request)
                    scheduledCount += 1
                }
            }
        }
    }

    /// Scoped replacement for the old `cancelAllReminders()` — turning the
    /// wisdom toggle off must not take the streak/review nudges down with it.
    func cancelWisdomReminders() {
        Task {
            await removePending(withPrefixes: [Namespace.wisdom] + Namespace.legacyPrefixes)
        }
    }

    /// Schedules (or clears) the evening streak-at-risk nudge. Called from the
    /// app-lifecycle scenePhase handler: always cancels first, so showing up
    /// during the day silently disarms tonight's reminder on the next pass.
    /// One-shot, never repeating — a streak that's already safe (or already
    /// dead) must not produce a stale notification tomorrow.
    func updateStreakAtRiskReminder(currentStreak: Int, hasShownUpToday: Bool) {
        Task {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [Namespace.streakAtRisk])

            guard currentStreak >= 3, !hasShownUpToday else { return }

            var fireComponents = Calendar.current.dateComponents([.year, .month, .day], from: .now)
            fireComponents.hour = 20
            fireComponents.minute = 30
            guard let fireDate = Calendar.current.date(from: fireComponents), fireDate > .now else { return }

            await requestProvisionalPermissionIfNeeded()

            let content = UNMutableNotificationContent()
            content.title = "Cobux 🔥"
            content.body = "Your \(currentStreak)-day streak ends tonight — one quick review keeps it alive."
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false
            )
            let request = UNNotificationRequest(identifier: Namespace.streakAtRisk, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    /// Schedules (or clears) tomorrow-morning's "N cards ready" nudge.
    /// Recomputed on every backgrounding pass from the same due-dates data the
    /// Watch sync derives, so the count is honest as of the last time the app
    /// actually knew the queue.
    func updateMorningReviewReminder(dueCount: Int, enabled: Bool) {
        Task {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [Namespace.morningReview])

            guard enabled, dueCount > 0 else { return }

            await requestProvisionalPermissionIfNeeded()

            let content = UNMutableNotificationContent()
            content.title = "Cobux"
            content.body = dueCount == 1
                ? "1 card is ready for review."
                : "\(dueCount) cards are ready for review."
            content.sound = .default

            guard let nextNine = Calendar.current.nextDate(
                after: .now,
                matching: DateComponents(hour: 9, minute: 0),
                matchingPolicy: .nextTime
            ) else { return }

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: nextNine),
                repeats: false
            )
            let request = UNNotificationRequest(identifier: Namespace.morningReview, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    /// Mirrors the due-card count onto the app icon — the classic red-badge
    /// pull. Zero (or a disabled toggle) clears it; never left stale, since
    /// this runs on every foreground/background pass alongside the nudges.
    func updateDueBadge(dueCount: Int, enabled: Bool) {
        Task {
            let count = enabled ? dueCount : 0
            if count > 0 {
                await requestProvisionalPermissionIfNeeded()
            }
            try? await UNUserNotificationCenter.current().setBadgeCount(count)
        }
    }

    /// Batch generation can finish while the app is closed (Anthropic's Batch API takes up
    /// to ~24h) -- without this, the only way to know a book's questions are ready was
    /// remembering to open the app and manually tap "Check Status." Fires immediately
    /// (a 1-second trigger, the minimum `UNTimeIntervalNotificationTrigger` allows, rather
    /// than a calendar-scheduled one) since this is reporting something that already
    /// happened, not scheduling something for later.
    func notifyBatchGenerationComplete(bookTitle: String, questionsInserted: Int) {
        let title = Self.truncatedForNotification(bookTitle, maxLength: 60)
        let content = UNMutableNotificationContent()
        content.title = "Cobux"
        content.body = questionsInserted > 0
            ? "\(title)'s background quiz generation finished — \(questionsInserted) question\(questionsInserted == 1 ? "" : "s") ready."
            : "\(title)'s background quiz generation finished."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: Namespace.batchComplete, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func getPendingCount() async -> Int {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests.count
    }

    /// Notification content that echoes user data (a highlight's text, a
    /// book's title/author) has no natural upper bound — a highlight can be a
    /// full paragraph, a translated title can run long. iOS truncates the
    /// *display* gracefully, but an unbounded string still defeats the point
    /// of a glanceable nudge. Trim well before that, on a word boundary where
    /// one exists past the halfway point so short titles/quotes are untouched.
    static func truncatedForNotification(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let prefix = text.prefix(maxLength)
        if let lastSpace = prefix.lastIndex(of: " "),
           prefix.distance(from: prefix.startIndex, to: lastSpace) > maxLength / 2 {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }
}
