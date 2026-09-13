import Foundation
import UserNotifications

/// One line of the wisdom rotation, as values: what `RemindersView`'s sampler
/// returns and what `NotificationManager.scheduleWisdomReminders` consumes.
/// `author` is nil when the highlight has no book; each surface applies its
/// own fallback wording ("Unknown" on the preview card, "Your Library" in the
/// notification -- both unchanged).
struct WisdomReminderPayload: Equatable, Sendable {
    let text: String
    let author: String?
}

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
        static let creditsRestored = "cobux.credits.restored"
        /// Pre-2.3.0 identifier formats, swept once so upgraded installs don't
        /// hold slots of the 64-request system cap forever.
        static let legacyPrefixes = ["cobux_wisdom_", "cobux_batch_generation_complete"]
    }

    /// **The pile-up, and why counting pending requests hid it.**
    ///
    /// Every wisdom request is a `UNCalendarNotificationTrigger` with
    /// `repeats: true`. The old code took the 48-request budget and split it
    /// ACROSS THE TIME SLOTS -- `48 / times.count` requests per slot -- then
    /// gave every one of them the SAME hour and minute. `RemindersView` always
    /// passes exactly two times (morning + evening, or two smart hours), so
    /// twenty-four requests were armed for 08:00 and twenty-four for 20:00,
    /// and all twenty-four fired at once. Every day. Forever.
    ///
    /// The screen above them promises "Twice a day, a line from your own
    /// highlights arrives as a notification". The app delivered FORTY-EIGHT a
    /// day: 336 a week piling into Notification Center, which is exactly what
    /// he was looking at -- "it's just keeping getting collected".
    ///
    /// Nothing counted it, because the number that was being managed was
    /// PENDING REQUESTS (48, safely under the 64 cap) and the number that hurt
    /// was NOTIFICATIONS DELIVERED PER DAY (also 48). For a one-shot trigger
    /// those are the same figure; for a repeating one they are not remotely.
    ///
    /// The fix keeps the feature and drops the volume 24x: the rotation is
    /// keyed on WEEKDAY instead of on an index, so each request fires WEEKLY
    /// rather than daily, and the seven of them covering a slot deliver
    /// exactly one notification per slot per day -- what the screen says. See
    /// `scheduleWisdomReminders`.
    ///
    /// The budget below is now what it always claimed to be: a share of the
    /// 64-request cap. 28 wisdom + 1 morning review + 1 batch-complete +
    /// 1 credits-restored = 31, leaving over half the cap free.
    /// Internal, not private: `RemindersView` draws exactly this many
    /// highlights for the rotation, so the two numbers cannot drift.
    static let maxWisdomNotifications = 28

    /// Days of rotation per time slot. Seven, so the cycle is a week and the
    /// weekday component of the trigger is a natural key.
    private static let wisdomRotationDays = 7

    /// **How long a nudge is allowed to sit in Notification Center.**
    ///
    /// "It should be somehow smart, and maybe temporary -- we don't want it to
    /// be collecting." A quote that arrived this morning is worth seeing; the
    /// same quote eighteen hours later is litter, and forty of them stacked up
    /// is what made him ask. Twelve hours outlives the gap between the morning
    /// and evening slots, so a nudge is never swept before its own reply has
    /// had a full half-day to be read.
    private static let nudgeLifetime: TimeInterval = 12 * 60 * 60

    /// A hard ceiling on delivered nudges regardless of age, so a phone that
    /// has not been opened for a fortnight still shows a short list rather
    /// than a wall. Deliberately small: past a handful, a stack of quotes
    /// stops being a reminder and becomes a chore.
    private static let maxDeliveredNudges = 4

    /// The only notifications allowed to appear while Cobux is open.
    ///
    /// iOS shows a local notification in the foreground ONLY if the app's
    /// `UNUserNotificationCenterDelegate` asks it to; with no delegate at all
    /// it silently drops every one. Cobux had no delegate, which is why
    /// "Cobux AI is back" has never been seen by anyone: it fires one second
    /// after a request succeeds, and every path that can produce that success
    /// is a foreground screen. See `NotificationPresenter`.
    ///
    /// These two are here because each ANSWERS A QUESTION THE USER ALREADY
    /// ASKED — they tried and it failed, or they started a batch and walked
    /// away. The scheduled nudges (wisdom, streak, morning review) are
    /// deliberately absent: interrupting his own writing to suggest he write
    /// is precisely the push this app does not do. They still arrive in
    /// Notification Center, where he goes to them.
    ///
    /// **This set now has a second job, deliberately the same set.**
    /// `sweepDeliveredNudges` ages delivered notifications out of Notification
    /// Center, and the line it must not cross is exactly this one: an ANSWER
    /// stays until he dismisses it, a NUDGE has a shelf life. Two lists would
    /// have drifted the first time a notification type was added to one and
    /// not the other -- the same class of bug the `Namespace` enum above
    /// exists to prevent -- so a new notification is classified once, here,
    /// and both behaviours follow from it.
    static let foregroundPresentableIdentifiers: Set<String> = [
        Namespace.batchComplete,
        Namespace.creditsRestored,
    ]

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

    /// Takes plain values, never `Highlight` rows. This used to take
    /// `highlights: [Highlight]` -- the ENTIRE `isReminder == true` set, which
    /// is essentially the whole table (the flag defaults to true), so every
    /// reschedule mapped ~33,000 rows and faulted each one's `book`
    /// relationship on the main actor to build at most 28 notifications.
    /// `RemindersView` now samples `maxWisdomNotifications` of them off the
    /// main actor (`ReminderRotationProbe`) and hands the strings over; this
    /// class touches no model object and needs no seed-merge guard of its own
    /// (the sampler carries it).
    ///
    /// The rotation is the same kind of thing it always was: a highlight's
    /// text under its book's author, drawn at random from everything switched
    /// on for Reminders.
    @MainActor
    func scheduleWisdomReminders(payloads sampled: [WisdomReminderPayload], times: [DateComponents]) {
        let payloads: [(text: String, author: String)] = sampled.map {
            (Self.truncatedForNotification($0.text, maxLength: 280), Self.truncatedForNotification($0.author ?? "Your Library", maxLength: 60))
        }

        Task {
            let center = UNUserNotificationCenter.current()
            await removePending(withPrefixes: [Namespace.wisdom] + Namespace.legacyPrefixes)

            guard !payloads.isEmpty, !times.isEmpty else { return }

            // Days of rotation this slot count can afford. Two slots (the only
            // shape `RemindersView` actually produces) gets the full week at 14
            // requests; even four slots stays inside the budget at 28.
            let rotationDays = max(1, min(Self.wisdomRotationDays,
                                          Self.maxWisdomNotifications / times.count))
            var scheduledCount = 0

            for timeComponents in times {
                guard scheduledCount < Self.maxWisdomNotifications else { break }

                // Shuffled once per slot so the morning and evening lines are
                // drawn independently, then walked in order across the week --
                // `payloads` can be shorter than `rotationDays`, in which case
                // the modulo repeats the few he has rather than scheduling
                // nothing.
                let shuffled = payloads.shuffled()

                // `weekday` is 1...7 (Gregorian, Sunday-based). Adding it to the
                // trigger turns "every day at 08:00" into "every SUNDAY at
                // 08:00", so seven requests cover the slot with a different
                // line each day and exactly ONE arrives per day -- instead of
                // twenty-four arriving together every morning.
                for weekday in 1...rotationDays {
                    guard scheduledCount < Self.maxWisdomNotifications else { break }

                    let payload = shuffled[(weekday - 1) % shuffled.count]

                    let content = UNMutableNotificationContent()
                    content.title = "Cobux"
                    content.subtitle = payload.author
                    content.body = payload.text
                    content.sound = .default
                    // A quote is ambient. It should be the first thing dropped
                    // when iOS decides what a scheduled summary or a crowded
                    // lock screen has room for -- unlike the two answers below,
                    // which are pinned at 1.0 precisely so they surface ABOVE a
                    // week of accumulated wisdom.
                    content.relevanceScore = 0.25
                    // Deliberately `.active`, not `.passive`. `.passive` adds a
                    // notification to the list without lighting the screen or
                    // playing a sound, which for a quote whose entire job is to
                    // put a line in front of him at 08:00 would be the same as
                    // deleting it. The volume was the problem, not the arrival.
                    content.interruptionLevel = .active

                    var triggerComponents = DateComponents()
                    triggerComponents.weekday = weekday
                    triggerComponents.hour = timeComponents.hour
                    triggerComponents.minute = timeComponents.minute

                    let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: true)

                    // The `w` marks the weekday shape. `pruneOverscheduledWisdom`
                    // reads the TRIGGER rather than this string (identifier
                    // formats have changed twice), but keeping the shape legible
                    // makes a `getPendingCount()` dump readable by eye.
                    let identifier = "\(Namespace.wisdom)\(timeComponents.hour ?? 0)_\(timeComponents.minute ?? 0)_w\(weekday)"
                    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

                    try? await center.add(request)
                    scheduledCount += 1
                }
            }
        }
    }

    /// **Repairs an install that is already carrying the 24-per-slot backlog.**
    ///
    /// The rewrite above only runs when `RemindersView` reschedules -- a toggle
    /// flip, a time change, or a visit to that screen. Someone who set his
    /// reminders months ago and never went back has forty-eight repeating
    /// requests armed on his phone right now, and nothing would ever clear
    /// them. So the repair cannot live in the scheduler; it has to run on the
    /// ordinary foreground pass, which is why `cancelStreakAtRiskReminder`
    /// calls it.
    ///
    /// It does NOT reschedule (that needs the model context, which this class
    /// deliberately never touches outside `scheduleWisdomReminders`). It thins:
    /// for every distinct hour+minute the pending wisdom requests fire at, one
    /// request survives. Delivery drops from 48 a day to 2 the moment the app
    /// is next opened, and the full seven-line rotation arrives whenever
    /// Reminders is next visited.
    ///
    /// Grouped by the TRIGGER, not the identifier: the wisdom identifier format
    /// has now changed twice (`cobux_wisdom_*`, then `cobux.wisdom.h_m_i`, now
    /// `cobux.wisdom.h_m_wN`), and a repair keyed on a string shape is a repair
    /// that misses the installs it was written for.
    private func pruneOverscheduledWisdom() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()

        let wisdomPrefixes = [Namespace.wisdom, "cobux_wisdom_"]
        let wisdom = pending.filter { request in
            wisdomPrefixes.contains { request.identifier.hasPrefix($0) }
        }
        guard !wisdom.isEmpty else { return }

        // slot -> the requests armed for it, split by whether they carry a
        // weekday (the new shape, seven of which are correct) or not (the old
        // shape, of which exactly one may survive).
        var rotating: [String: [String]] = [:]
        var daily: [String: [String]] = [:]
        for request in wisdom {
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { continue }
            let parts = trigger.dateComponents
            let slot = "\(parts.hour ?? -1):\(parts.minute ?? -1)"
            if parts.weekday == nil {
                daily[slot, default: []].append(request.identifier)
            } else {
                rotating[slot, default: []].append(request.identifier)
            }
        }

        var doomed: [String] = []
        for (slot, identifiers) in daily {
            // A slot that already has the weekday rotation needs none of its
            // old every-day requests; one without it keeps a single line
            // arriving rather than going silent until Reminders is reopened.
            let survivors = rotating[slot] == nil ? 1 : 0
            doomed.append(contentsOf: identifiers.sorted().dropFirst(survivors))
        }
        // Belt and braces: a rotation slot should hold at most seven. More than
        // that means two schedulers raced, and the surplus is pure noise.
        for (_, identifiers) in rotating where identifiers.count > Self.wisdomRotationDays {
            doomed.append(contentsOf: identifiers.sorted().dropFirst(Self.wisdomRotationDays))
        }

        guard !doomed.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: doomed)
    }

    /// **Ages out the nudges he has already had a chance to read.**
    ///
    /// The other half of "we don't want it to be collecting". Scheduling two a
    /// day instead of forty-eight stops the flood; this stops the silt, because
    /// two a day is still sixty a month sitting in Notification Center with
    /// nothing to clear them.
    ///
    /// The taxonomy is `foregroundPresentableIdentifiers` -- the SAME set that
    /// decides which notifications may speak over the app, and for the same
    /// reason. Those two ANSWER something he did: he tried and the key was dry,
    /// or he started a batch and walked away. An answer is not litter and is
    /// never swept here, however old it is; it also cannot pile up, since each
    /// reuses one identifier and so replaces itself. Everything else is a
    /// scheduled nudge, and a nudge has a shelf life.
    ///
    /// Two rules, both conservative:
    /// - older than `nudgeLifetime` (12h, longer than the gap between slots);
    /// - or beyond the `maxDeliveredNudges` most recent, whatever its age.
    ///
    /// Nothing here touches PENDING requests, so no future reminder is lost --
    /// this only clears what has already been delivered.
    func sweepDeliveredNudges() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()

        let nudges = delivered
            .filter { !Self.foregroundPresentableIdentifiers.contains($0.request.identifier) }
            .sorted { $0.date > $1.date }
        guard !nudges.isEmpty else { return }

        let cutoff = Date.now.addingTimeInterval(-Self.nudgeLifetime)
        let doomed = nudges.enumerated()
            .filter { index, notification in
                index >= Self.maxDeliveredNudges || notification.date < cutoff
            }
            .map(\.element.request.identifier)

        guard !doomed.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: doomed)
    }

    /// Scoped replacement for the old `cancelAllReminders()` — turning the
    /// wisdom toggle off must not take the streak/review nudges down with it.
    func cancelWisdomReminders() {
        Task {
            await removePending(withPrefixes: [Namespace.wisdom] + Namespace.legacyPrefixes)
        }
    }

    /// **Deleted: the streak-at-risk reminder.**
    ///
    /// It fired at 20:30 with "Your N-day streak ends tonight — one quick
    /// review keeps it alive." That notification exists precisely BECAUSE the
    /// user has not done something, which is the exact frame Rajan rejected
    /// when he saw a checkmark on the journal widget: "the jounral streak is
    /// meant for fun info display... if they dont wanna they wont."
    ///
    /// Not reworded, deleted. An evening notification about an absence grades
    /// the user no matter how gently it is phrased -- softened guilt is still
    /// guilt. Two aggravating facts made it worse than the tick: it had no
    /// toggle anywhere (the changelog claimed one in Reminders; `RemindersView`
    /// has toggles for wisdom reminders, the morning nudge and the badge, and
    /// never had one for this), and it was unconditional for anyone with a
    /// streak of three or more.
    ///
    /// The morning "N cards are ready" nudge and the wisdom reminders stay:
    /// they report that something is READY, or deliver a quote. Neither tells
    /// anyone they are behind.
    ///
    /// This clears any already-scheduled request on devices that have one, so
    /// an installed copy stops firing rather than waiting for it to age out.
    ///
    /// **Also the app's notification-hygiene pass.** `ContentView`
    /// (`updateEngagementNudges`) calls this unconditionally on every
    /// foreground/background transition, which makes it the one place in the
    /// app guaranteed to run often enough to keep Notification Center honest,
    /// and it is already a sweep of something obsolete. So the two other
    /// sweeps ride here rather than waiting for a screen the user may never
    /// open again: the 24-per-slot backlog repair, and the ageing-out of
    /// nudges he has already had a chance to read.
    ///
    /// Both are `async` and idempotent, and neither reads the model context,
    /// so hanging them off a foreground pass costs a pending-request fetch.
    /// If this ever earns its own call site, `pruneOverscheduledWisdom` and
    /// `sweepDeliveredNudges` are both safe to call directly and this can go
    /// back to the one line it describes.
    func cancelStreakAtRiskReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Namespace.streakAtRisk])
        Task {
            await pruneOverscheduledWisdom()
            await sweepDeliveredNudges()
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
            // `.passive`, and no sound, because the screen that offers this
            // already promises exactly that: "The nudge is a single 9 AM
            // notification on days you have quiz cards waiting. The badge keeps
            // the number of due cards on the app icon -- BOTH DELIVERED
            // QUIETLY." The code set `.default` sound, so it was not quiet, and
            // the screen and the behaviour disagreed.
            //
            // `.passive` is also the honest level for what this says. It
            // reports a STATE ("cards are waiting"), not an event, and the icon
            // badge is already carrying that same number continuously -- so
            // nothing is lost by letting it appear in Notification Center
            // without lighting the screen at nine in the morning. That is the
            // opposite of the wisdom quote, whose whole value is the moment it
            // arrives, which is why that one stays `.active`.
            content.interruptionLevel = .passive
            content.relevanceScore = 0.5

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
        // An ANSWER, so it is pinned at the top of whatever iOS decides to
        // show. The batch can take a day to land, by which time a week of
        // quotes may be sitting above it; at 1.0 against their 0.25 this one
        // surfaces first, and `sweepDeliveredNudges` never clears it.
        content.relevanceScore = 1.0
        content.interruptionLevel = .active

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: Namespace.batchComplete, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// "Cobux AI is back." Fired by `CreditStatusMonitor` the first time a
    /// request succeeds after the key ran dry -- the app's own evidence that
    /// funds landed, since there is no server to tell it.
    ///
    /// Deliberately has no schedule, no repeat and no badge: it is a one-shot
    /// answer to a question the user already asked by trying and failing.
    func notifyCreditsRestored() {
        // Permission FIRST, and awaited, then the add — in one task rather
        // than two.
        //
        // Nothing on this path had ever asked for permission. The wisdom
        // toggle asks, and the nudges ask provisionally, but a user who has
        // touched neither sits at `.notDetermined`, where `add` reports
        // success and delivers nothing. Provisional is the right ask for this
        // moment and the only one that suits it: it raises no dialog, so
        // recovering from a dead key never becomes a permission prompt.
        //
        // Requesting on a detached task while adding synchronously would be a
        // race, and one that always loses: the one-second trigger would have
        // fired and been discarded before the authorisation resolved.
        Task {
            await requestProvisionalPermissionIfNeeded()

            let content = UNMutableNotificationContent()
            content.title = "Cobux AI is back"
            content.body = "Credits have been topped up — chat, Go Deeper and voice are working again."
            content.sound = .default
            // The other answer. Same reasoning as `notifyBatchGenerationComplete`:
            // top of the stack, and exempt from the nudge sweep, because he is
            // waiting on this one.
            content.relevanceScore = 1.0
            content.interruptionLevel = .active
            let request = UNNotificationRequest(
                identifier: Namespace.creditsRestored,
                content: content,
                // Not nil. A nil trigger fires the instant it is added, which
                // is mid-request on the screen that just recovered; one second
                // lets the UI settle first. The foreground banner itself is
                // `NotificationPresenter`'s doing — without that delegate this
                // notification was never shown at all, whatever the trigger.
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
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

/// Shows the two notifications that are answers, and only while Cobux is open.
///
/// iOS displays a local notification that fires in the FOREGROUND only if the
/// app's `UNUserNotificationCenterDelegate` says to. With no delegate assigned
/// it drops every one, silently, and reports nothing to the caller: `add`
/// still succeeds.
///
/// Cobux had no delegate. That is not a missing polish item, it is the reason
/// `notifyCreditsRestored` has never been seen by anybody. It fires one second
/// after a request succeeds, and every path that can produce that success runs
/// from a screen the user is looking at (`ChatView`, `VoiceSessionController`
/// through `ClaudeService.recordCreditOutcome`). There is no background
/// refresh in this app, so "one second after a success" is always foreground,
/// always suppressed. `notifyBatchComplete` had the same hole whenever a batch
/// finished while the app was still open, which is the common case.
///
/// What is deliberately NOT presented matters as much. The wisdom reminders,
/// the streak nudge and the morning review return no options here, so they
/// stay silent while he is in the app and wait in Notification Center. Cobux
/// does not interrupt someone's writing to recommend that they write; the
/// notifications that may speak are the two that finish a sentence the user
/// started.
///
/// Assigned in `CobuxApp.init()`. Apple requires the delegate to exist before
/// the app finishes launching, and `init()` is the only point that is
/// guaranteed to run before any `body` or any `.task` in the app.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    /// Immutable and stateless, so sharing it across the delegate callback's
    /// thread and the main actor is safe by construction rather than by lock.
    static let shared = NotificationPresenter()

    private override init() { super.init() }

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// The completion-handler form rather than the `async` one: this is called
    /// by UserNotifications on its own queue, and the closure form keeps the
    /// method free of actor isolation entirely, which is what lets a stateless
    /// singleton answer it without hopping anywhere.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let identifier = notification.request.identifier
        guard NotificationManager.foregroundPresentableIdentifiers.contains(identifier) else {
            // Not an error and not a drop: it still lands in Notification
            // Center. It just does not take over the screen.
            completionHandler([])
            return
        }
        // Banner and list, deliberately NOT sound. The success that triggers
        // "Cobux AI is back" can come from a live voice session, so a sound
        // here plays over an active `AVAudioSession` mid-conversation. The
        // notification still carries `content.sound`, which is what plays when
        // the app is in the BACKGROUND -- and `willPresent` is only consulted
        // in the foreground, so nothing is lost where it matters.
        completionHandler([.banner, .list])
    }
}
