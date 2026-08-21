import SwiftUI
import SwiftData

struct RemindersView: View {
    @Bindable var notificationManager: NotificationManager
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Highlight> { $0.isReminder == true }) private var reminderHighlights: [Highlight]

    @AppStorage("remindersEnabled") private var remindersEnabled = false
    @AppStorage("reviewNudgeEnabled") private var reviewNudgeEnabled = true
    @AppStorage("dueBadgeEnabled") private var dueBadgeEnabled = true
    /// Off by default -- flipping on an existing user's carefully-picked
    /// morning/evening times without asking would silently replace a real
    /// choice. New installs never had a choice to override in the first
    /// place, so a fresh-install default of `true` would be reasonable too,
    /// but `false` here is the safer single default until there's a real
    /// "new install" signal to key it off distinctly.
    @AppStorage("smartTimingEnabled") private var smartTimingEnabled = false
    @State private var morningTime = Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()
    @State private var eveningTime = Calendar.current.date(from: DateComponents(hour: 20, minute: 0)) ?? Date()

    var body: some View {
        // Pushed from MoreView's own NavigationStack -- no nested stack here,
        // which used to produce a doubled navigation bar.
        Form {
                Section {
                    Toggle("Enable Wisdom Reminders", isOn: $remindersEnabled)
                        .onChange(of: remindersEnabled) { _, newValue in
                            if newValue {
                                notificationManager.requestPermission()
                                scheduleReminders()
                            } else {
                                notificationManager.cancelWisdomReminders()
                            }
                        }
                } footer: {
                    Text("Get daily push notifications with random quotes and highlights from your books.")
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
                                Text("Still learning your routine — using 8:00 AM and 8:00 PM until there's enough to go on.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            DatePicker("Morning Reminder", selection: $morningTime, displayedComponents: .hourAndMinute)
                            DatePicker("Evening Reminder", selection: $eveningTime, displayedComponents: .hourAndMinute)
                        }
                    } header: {
                        Text("Schedule")
                    } footer: {
                        Text("Smart Timing learns the hours you tend to open Cobux and sends reminders then instead of a fixed time you have to set yourself.")
                    }
                    .onChange(of: morningTime) { _, _ in scheduleReminders() }
                    .onChange(of: eveningTime) { _, _ in scheduleReminders() }

                    Section("Rotation") {
                        HStack {
                            Text("Highlights in rotation")
                            Spacer()
                            Text("\(reminderHighlights.count)")
                                .foregroundStyle(.secondary)
                        }

                        if let random = reminderHighlights.randomElement() {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Preview:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\"\(random.text)\"")
                                    .font(.subheadline)
                                    .italic()
                                Text("— \(random.book?.author ?? "Unknown")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
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
            .onAppear {
                if remindersEnabled, smartTimingEnabled {
                    scheduleReminders()
                }
            }
    }

    private func scheduleReminders() {
        guard remindersEnabled, !reminderHighlights.isEmpty else {
            notificationManager.cancelWisdomReminders()
            return
        }

        let times: [DateComponents]
        if smartTimingEnabled, let smartHours = AppActivityTracker.smartHours() {
            times = smartHours.map { DateComponents(hour: $0, minute: 0) }
        } else {
            // Smart Timing with not-enough-data-yet falls back to the same
            // 8/20 defaults `morningTime`/`eveningTime` start at, matching
            // the "using 8:00 AM and 8:00 PM until there's enough to go on"
            // message shown above -- not the user's own picked times, which
            // stay hidden (and irrelevant) while Smart Timing is on.
            let morningComponents = Calendar.current.dateComponents([.hour, .minute], from: morningTime)
            let eveningComponents = Calendar.current.dateComponents([.hour, .minute], from: eveningTime)
            times = smartTimingEnabled ? [DateComponents(hour: 8, minute: 0), DateComponents(hour: 20, minute: 0)] : [morningComponents, eveningComponents]
        }

        notificationManager.scheduleWisdomReminders(highlights: reminderHighlights, times: times)
    }

    private static func formattedHour(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        let date = Calendar.current.date(from: DateComponents(hour: hour, minute: 0)) ?? .now
        return formatter.string(from: date)
    }
}
