import SwiftUI
import SwiftData

struct RemindersView: View {
    @Bindable var notificationManager: NotificationManager
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Highlight> { $0.isReminder == true }) private var reminderHighlights: [Highlight]

    @AppStorage("remindersEnabled") private var remindersEnabled = false
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
                                notificationManager.cancelAllReminders()
                            }
                        }
                } footer: {
                    Text("Get daily push notifications with random quotes and highlights from your books.")
                }

                if remindersEnabled {
                    Section("Schedule") {
                        DatePicker("Morning Reminder", selection: $morningTime, displayedComponents: .hourAndMinute)
                        DatePicker("Evening Reminder", selection: $eveningTime, displayedComponents: .hourAndMinute)
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
    }

    private func scheduleReminders() {
        guard remindersEnabled, !reminderHighlights.isEmpty else {
            notificationManager.cancelAllReminders()
            return
        }

        let morningComponents = Calendar.current.dateComponents([.hour, .minute], from: morningTime)
        let eveningComponents = Calendar.current.dateComponents([.hour, .minute], from: eveningTime)

        notificationManager.scheduleWisdomReminders(highlights: reminderHighlights, times: [morningComponents, eveningComponents])
    }
}
