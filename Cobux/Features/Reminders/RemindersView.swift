import SwiftUI
import SwiftData
import UserNotifications

struct RemindersView: View {
    @Bindable var notificationManager: NotificationManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// How many highlights are in the rotation. `nil` until read.
    ///
    /// This screen used to hold `@Query(filter: isReminder == true)` -- and
    /// `isReminder` DEFAULTS TO TRUE (`Highlight.init`), so that query was
    /// essentially the whole table: ~33,000 rows, each carrying its 2 KB
    /// embedding, materialised on the main actor to show one integer, pick
    /// one preview line, and hand the entire array to the scheduler. Now a
    /// `COUNT` and a handful of one-row draws, off the main actor
    /// (`ReminderRotationProbe`).
    @State private var rotationCount: Int?

    @AppStorage("remindersEnabled") private var remindersEnabled = false
    @AppStorage("reviewNudgeEnabled") private var reviewNudgeEnabled = true
    // Defaults OFF. A red count on the app icon is to-do vocabulary on the
    // most prominent surface iOS has -- the same frame as the checkmark he
    // rejected on the journal widget, only louder, and handed to every user
    // unasked. It stays available for anyone who wants it (Reminders >
    // Due-Cards Icon Badge): someone studying for an exam genuinely chose a
    // task system. It is just no longer the default.
    @AppStorage("dueBadgeEnabled") private var dueBadgeEnabled = false
    /// Off by default -- flipping on an existing user's carefully-picked
    /// morning/evening times without asking would silently replace a real
    /// choice. New installs never had a choice to override in the first
    /// place, so a fresh-install default of `true` would be reasonable too,
    /// but `false` here is the safer single default until there's a real
    /// "new install" signal to key it off distinctly.
    // Default ON since 58. The paragraph above argued for `false` "until there's
    // a real new-install signal". Nine days of the weather stamp sitting behind
    // an off-by-default toggle (12 Sep: "no temperature yet in journals I don't
    // know what you have forgotten") settled it: a feature he asked for that
    // waits on a switch nobody is told about is a feature that does not exist.
    // Anyone who already chose keeps their value; `@AppStorage` only applies a
    // default when the key is absent.
    @AppStorage("smartTimingEnabled") private var smartTimingEnabled = true
    /// The two hand-picked reminder times, persisted as minutes past midnight.
    ///
    /// These were plain `@State`, which meant they were **not saved at all**.
    /// The doc comment above and the one at `scheduleReminders()` both talk
    /// about a user's "carefully-picked morning/evening times" as if they were
    /// durable; they were not. Setting Morning Reminder to 7 AM lasted exactly
    /// as long as this view stayed in memory -- and because `.onAppear`
    /// reschedules whenever the screen is opened, the next visit silently
    /// rewrote the 7 AM notification back to 8 AM. A repeating
    /// `UNCalendarNotificationTrigger` is written once and never revisited, so
    /// that overwrite then stuck (see the `.onAppear` comment below).
    ///
    /// Minutes-past-midnight rather than a `Date`: `@AppStorage` cannot store a
    /// `Date`, and persisting an absolute instant would move the reminder's
    /// hour when he changes timezone -- the one thing a "8 AM every day"
    /// reminder must never do. The defaults are the same 8:00/20:00 the old
    /// `@State` initialisers used, so nobody's current schedule changes.
    @AppStorage("reminderMorningMinutes") private var morningMinutes = 8 * 60
    @AppStorage("reminderEveningMinutes") private var eveningMinutes = 20 * 60

    /// `DatePicker` needs a `Binding<Date>`; the stored truth is an `Int`.
    private var morningTime: Binding<Date> { Self.timeBinding(for: $morningMinutes) }
    private var eveningTime: Binding<Date> { Self.timeBinding(for: $eveningMinutes) }
    /// What iOS actually says, read on appear and every return to the
    /// foreground (he may have just flipped it in iOS Settings). `nil` until
    /// read. The toggle used to flip on regardless and schedule 48 requests
    /// that a denied device silently dropped, while `isAuthorized` sat unread.
    @State private var authorizationStatus: UNAuthorizationStatus?

    private var notificationsDenied: Bool { authorizationStatus == .denied }

    /// The one line shown under "Rotation", picked ONCE.
    ///
    /// A CORRECTNESS bug, not just a cost: this was
    /// `reminderHighlights.randomElement()` evaluated inside `body`, so the
    /// preview re-rolled on every body evaluation. Flipping any toggle on this
    /// screen -- Smart Timing, the icon badge, the review nudge, or moving
    /// either `DatePicker` by a minute -- silently swapped the quote he was
    /// reading, for no reason he could see and with no way to get it back. The
    /// same trap `suggestedPrompts` in chat was already fixed for.
    ///
    /// Held as plain values, not as the `Highlight`: the view keeps no model
    /// object alive across body passes, and drawing the card touches no
    /// relationship (`book?.author` was a fault, per row, per body).
    private struct ReminderPreview: Equatable {
        let text: String
        let author: String
    }

    @State private var preview: ReminderPreview?

    var body: some View {
        // Pushed from MoreView's own NavigationStack -- no nested stack here,
        // which used to produce a doubled navigation bar.
        Form {
                if notificationsDenied {
                    Section {
                        Label("Notifications are off for Cobux", systemImage: "bell.slash")
                            .font(.headline)
                        Text("iOS is blocking them, so nothing set up here can arrive. Turn them on for Cobux in iOS Settings and this screen picks up where it left off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            Link("Open iOS Settings", destination: url)
                        }
                    }
                }

                Section {
                    Toggle("Enable Wisdom Reminders", isOn: $remindersEnabled)
                        .onChange(of: remindersEnabled) { _, newValue in
                            if newValue {
                                Task { await enableReminders() }
                            } else {
                                notificationManager.cancelWisdomReminders()
                            }
                        }
                } footer: {
                    // Honest about the mechanism: these are local notifications
                    // scheduled on this phone. Cobux has no server and no push
                    // pipeline; the old footer promised "daily push
                    // notifications", which the app has never had.
                    Text("Twice a day, a line from your own highlights arrives as a notification, at the times you choose below. Scheduled on this phone — nothing is sent from anywhere.")
                }

                Section {
                    Toggle("Morning Review Nudge", isOn: $reviewNudgeEnabled)
                    Toggle("Due-Cards Icon Badge", isOn: $dueBadgeEnabled)
                } footer: {
                    Text("The nudge is a single 9 AM notification on days you have quiz cards waiting. The badge keeps the number of due cards on the app icon — both delivered quietly, and only when something is actually due.")
                }

                if remindersEnabled {
                    Section {
                        Toggle("Smart Timing", isOn: $smartTimingEnabled)
                            .onChange(of: smartTimingEnabled) { _, _ in scheduleReminders() }

                        if smartTimingEnabled {
                            if let hours = AppActivityTracker.smartHours() {
                                Text("Based on when you actually open Cobux, reminders go out around \(hours.map(Self.formattedHour).joined(separator: " and ")).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                // Names the times actually scheduled rather
                                // than a hardcoded pair. It used to read
                                // "using 8:00 AM and 8:00 PM"; the fallback
                                // below now uses his own picked times, so a
                                // fixed string here would be a lie the moment
                                // he changed one.
                                Text("Still learning your routine — using \(Self.formattedTime(minutes: morningMinutes)) and \(Self.formattedTime(minutes: eveningMinutes)) until there's enough to go on.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            DatePicker("Morning Reminder", selection: morningTime, displayedComponents: .hourAndMinute)
                            DatePicker("Evening Reminder", selection: eveningTime, displayedComponents: .hourAndMinute)
                        }
                    } header: {
                        Text("Schedule")
                    } footer: {
                        Text("Smart Timing learns the hours you tend to open Cobux and sends reminders then instead of a fixed time you have to set yourself.")
                    }
                    .onChange(of: morningMinutes) { _, _ in scheduleReminders() }
                    .onChange(of: eveningMinutes) { _, _ in scheduleReminders() }

                    Section {
                        HStack {
                            Text("Highlights in rotation")
                            Spacer()
                            // An en dash until the count is read, never a
                            // "0": a zero is a claim about his library.
                            Text(rotationCount.map(String.init) ?? "–")
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }

                        if let preview {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Preview:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\"\(preview.text)\"")
                                    .font(.subheadline)
                                    .italic()
                                Text("— \(preview.author)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    } header: {
                        Text("Rotation")
                    } footer: {
                        // Every other section on this screen explains itself in
                        // a footer; this one showed a bare number. A reader
                        // seeing "0" had no way to learn what puts a line in
                        // the rotation, or why the reminders they just switched
                        // on would have nothing to say.
                        Text("Reminders are drawn from the highlights you saved with Include in Reminders switched on — the toggle on Add Highlight.")
                    }

                    Section {
                        Button("Force Refresh Schedule") {
                            scheduleReminders()
                        }
                    }
                }
            }
            .navigationTitle("Reminders")
            // Smart Timing's whole point is that it keeps itself current --
            // the schedule actually sent to `NotificationManager` should
            // reflect this visit's fresh `AppActivityTracker.smartHours()`
            // result, not whatever was true the last time a toggle or
            // manual time changed. Cheap: a no-op reschedule (same hours)
            // is indistinguishable from not calling this at all.
            // No `smartTimingEnabled` condition. It defaults to FALSE, so for
            // anyone who never turned Smart Timing on, this never fired and
            // already-queued notifications kept their old text forever -- which
            // is why "Cobux 📚" survived the fix that removed the emoji from the
            // source. A repeating UNCalendarNotificationTrigger is written once
            // and never revisited unless something reschedules it.
            .onAppear {
                if remindersEnabled { scheduleReminders() }
            }
            .task { await refreshAuthorization() }
            // Read ONCE per visit: the count and one random line. Nothing on
            // this screen re-rolls the quote -- a toggle flip, a time change
            // or a reschedule leaves it exactly where it was. (The rotation
            // can only change from Add Highlight, which is another screen,
            // and this one is re-created on every push.)
            .task { await loadRotation() }
            // Coming back from iOS Settings is the whole point of the link
            // above: re-read, and if he turned them on, reschedule.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    let wasDenied = notificationsDenied
                    await refreshAuthorization()
                    if wasDenied, !notificationsDenied, remindersEnabled { scheduleReminders() }
                }
            }
    }

    /// Asks the system if it has never been asked, then reads back what it
    /// actually said. A denied device reverts the toggle and shows the
    /// denied state above instead of scheduling into the void.
    private func enableReminders() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        }
        await refreshAuthorization()
        guard !notificationsDenied else {
            remindersEnabled = false
            return
        }
        scheduleReminders()
    }

    private func refreshAuthorization() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        // Keep the shared manager's flag honest for anything else that reads it.
        notificationManager.checkAuthorizationStatus()
    }

    /// The count and the preview line, from the probe. `@MainActor`
    /// explicitly, the way `WisdomGraphView.loadCounts` is: this assigns
    /// `@State`, and a bare `async` method makes no promise about which actor
    /// it resumes on (SE-0338). Only `Sendable` values come back.
    @MainActor
    private func loadRotation() async {
        // Never read the library mid seed/upgrade merge (the Build-5 crash
        // class). A skipped read self-heals on the next visit.
        guard !SeedingStatus.shared.isSeeding else { return }
        let probe = ReminderRotationProbe(modelContainer: modelContext.container)
        let rotation = await probe.rotation(sampleLimit: 1)
        rotationCount = rotation.count
        preview = rotation.sample.first.map {
            ReminderPreview(text: $0.text, author: $0.author ?? "Unknown")
        }
    }

    private func scheduleReminders() {
        // Denied means every request would be stored and never delivered --
        // while still holding 48 of the 64 pending slots iOS allows. Clear
        // rather than fill.
        guard remindersEnabled, !notificationsDenied else {
            notificationManager.cancelWisdomReminders()
            return
        }
        // The seed-merge guard that used to live in
        // `NotificationManager.scheduleWisdomReminders`, moved to the one
        // place that now reads the store. A skipped schedule self-heals --
        // the next toggle flip, time change, or "Force Refresh" tap
        // re-triggers it.
        guard !SeedingStatus.shared.isSeeding else { return }

        let times: [DateComponents]
        if smartTimingEnabled, let smartHours = AppActivityTracker.smartHours() {
            times = smartHours.map { DateComponents(hour: $0, minute: 0) }
        } else {
            // One fallback for both ways of getting here: Smart Timing off, and
            // Smart Timing on but without enough real opens to trust yet.
            //
            // It used to branch -- `smartTimingEnabled ? [8:00, 20:00] : his own
            // times` -- so turning Smart Timing on while the histogram was still
            // filling threw away a time he had deliberately set and replaced it
            // with a hardcoded pair. His own times ARE the right answer while
            // there is nothing smarter to say; the caption above now names them
            // so the screen and the schedule can never disagree.
            times = [Self.components(fromMinutes: morningMinutes),
                     Self.components(fromMinutes: eveningMinutes)]
        }

        // The draw runs off the main actor: a `COUNT`, then up to
        // `maxWisdomNotifications` one-row fetches at distinct random offsets
        // -- against a rotation that is essentially the whole highlight table.
        // An empty rotation clears the schedule, as the old
        // `!reminderHighlights.isEmpty` guard did.
        Task { @MainActor in
            let probe = ReminderRotationProbe(modelContainer: modelContext.container)
            let rotation = await probe.rotation(sampleLimit: NotificationManager.maxWisdomNotifications)
            rotationCount = rotation.count
            guard !rotation.sample.isEmpty else {
                notificationManager.cancelWisdomReminders()
                return
            }
            notificationManager.scheduleWisdomReminders(payloads: rotation.sample, times: times)
        }
    }

    /// Built once each. Both of these were constructed inside functions called
    /// straight from `body` -- `formattedHour` once per smart hour and
    /// `formattedTime` twice in one caption -- so every body evaluation of this
    /// screen allocated up to four `DateFormatter`s, each of which resolves the
    /// locale's calendar and symbols on construction. Neither is mutated after
    /// setup, which is the documented condition for reusing one.
    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static func formattedHour(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour, minute: 0)) ?? .now
        return hourFormatter.string(from: date)
    }

    private static func components(fromMinutes minutes: Int) -> DateComponents {
        DateComponents(hour: minutes / 60, minute: minutes % 60)
    }

    /// Locale-aware (`timeStyle: .short`), unlike `formattedHour` above -- this
    /// one has to render a time the user picked themselves, minutes included,
    /// and on a 24-hour phone "8 PM" is not what that phone calls 20:00.
    private static func formattedTime(minutes: Int) -> String {
        let date = Calendar.current.date(from: components(fromMinutes: minutes)) ?? .now
        return shortTimeFormatter.string(from: date)
    }

    /// Bridges the persisted minutes-past-midnight to the `Binding<Date>` a
    /// `DatePicker` requires, so there is still exactly one stored truth.
    private static func timeBinding(for minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: components(fromMinutes: minutes.wrappedValue)) ?? .now },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

/// Samples the wisdom rotation off the main actor -- `WisdomProbe`'s shape.
///
/// `isReminder == true` is nearly every highlight in the library (the flag
/// defaults to true), so "how many" is a `COUNT` and "give me N of them" is N
/// one-row fetches at distinct random offsets -- the primitive
/// `WatchSyncService.randomFeaturedHighlight` and `ContentView.
/// widgetInviteSample` already use. `propertiesToFetch` keeps each draw to
/// the text column rather than the row's 2 KB vector; the `book` to-one is
/// then faulted for that one row to read the author.
@ModelActor
actor ReminderRotationProbe {
    struct Rotation: Sendable {
        let count: Int
        let sample: [WisdomReminderPayload]
    }

    func rotation(sampleLimit: Int) -> Rotation {
        let inRotation = FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { $0.isReminder == true })
        let total = (try? modelContext.fetchCount(inRotation)) ?? 0
        guard total > 0, sampleLimit > 0 else { return Rotation(count: total, sample: []) }

        // Distinct offsets: a rotation smaller than the request is drawn
        // whole (in a shuffled order), a larger one is a true sample without
        // repeats. The scheduler's per-slot shuffle and modulo walk are
        // unchanged downstream.
        let wanted = min(sampleLimit, total)
        var offsets: [Int]
        if wanted == total {
            offsets = Array(0..<total).shuffled()
        } else {
            var chosen: Set<Int> = []
            while chosen.count < wanted { chosen.insert(Int.random(in: 0..<total)) }
            offsets = Array(chosen)
        }

        var sample: [WisdomReminderPayload] = []
        sample.reserveCapacity(wanted)
        for offset in offsets {
            var draw = inRotation
            draw.fetchOffset = offset
            draw.fetchLimit = 1
            draw.propertiesToFetch = [\.text]
            guard let highlight = try? modelContext.fetch(draw).first else { continue }
            sample.append(WisdomReminderPayload(text: highlight.text, author: highlight.book?.author))
        }
        return Rotation(count: total, sample: sample)
    }
}
