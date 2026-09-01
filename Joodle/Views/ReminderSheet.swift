import SwiftUI

struct ReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let dateString: String
    let entryBody: String?

    /// Optional mock store for tutorial mode - when provided, uses mock data instead of real ReminderManager
    var mockStore: MockDataStore?

    @StateObject private var reminderManager = ReminderManager.shared
    @State private var selectedTime: Date
    @State private var showPastTimeAlert = false
    @State private var showNotificationDeniedAlert = false

    private var isMockMode: Bool {
        mockStore != nil
    }

    private var hasExistingReminder: Bool {
        if let mockStore = mockStore {
            return mockStore.hasReminder(for: dateString)
        }
        return reminderManager.getReminder(for: dateString) != nil
    }

    init(dateString: String, entryBody: String? = nil, mockStore: MockDataStore? = nil) {
        self.dateString = dateString
        self.entryBody = entryBody
        self.mockStore = mockStore

        // Default to 9 AM on the entry date if no reminder exists
        if let mockStore = mockStore {
            // Mock mode - check mock store for existing reminder
            if let existing = mockStore.getReminder(for: dateString) {
                _selectedTime = State(initialValue: existing.reminderTime)
            } else if let entryDate = DayEntry.stringToLocalDate(dateString) {
                var components = Calendar.current.dateComponents([.year, .month, .day], from: entryDate)
                components.hour = 9
                components.minute = 0
                _selectedTime = State(initialValue: Calendar.current.date(from: components) ?? Date())
            } else {
                _selectedTime = State(initialValue: Date())
            }
        } else {
            // Real mode - check ReminderManager
            if let existing = ReminderManager.shared.getReminder(for: dateString) {
                _selectedTime = State(initialValue: existing.reminderDate)
            } else if let entryDate = DayEntry.stringToLocalDate(dateString) {
                // Set to 9 AM on that day
                var components = Calendar.current.dateComponents([.year, .month, .day], from: entryDate)
                components.hour = 9
                components.minute = 0
                _selectedTime = State(initialValue: Calendar.current.date(from: components) ?? Date())
            } else {
                _selectedTime = State(initialValue: Date())
            }
        }
    }

    /// Combines the entry date with the selected time
    private var combinedReminderDate: Date {
        guard let entryDate = DayEntry.stringToLocalDate(dateString) else {
            return selectedTime
        }

        let timeComponents = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
        var dateComponents = Calendar.current.dateComponents([.year, .month, .day], from: entryDate)
        dateComponents.hour = timeComponents.hour
        dateComponents.minute = timeComponents.minute

        return Calendar.current.date(from: dateComponents) ?? selectedTime
    }

    /// Whether the combined reminder date is in the past
    private var isReminderInPast: Bool {
        // In mock mode, skip past time validation for tutorial
        if isMockMode { return false }
        return combinedReminderDate <= Date()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                // Time picker
                DatePicker("Anniversary Alarm Time", selection: $selectedTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(height: 120)

                // Set/Update button
                Button {
                    // Debug logging
                    let formatter = DateFormatter()
                    formatter.dateStyle = .full
                    formatter.timeStyle = .long
                    formatter.timeZone = .current

                    // Check if reminder time is in the past (skip in mock mode)
                    if isReminderInPast {
                        showPastTimeAlert = true
                        return
                    }

                    if isMockMode {
                        // Mock mode - store in mock store without real notification
                        mockStore?.setReminder(for: dateString, at: combinedReminderDate)
                        dismiss()
                    } else {
                        // Real mode - check notification permission first, then use ReminderManager
                        Task {
                            // Check notification permission status
                            let status = await reminderManager.checkNotificationStatus()

                            switch status {
                            case .notDetermined:
                                // Request permission
                                let granted = await reminderManager.requestNotificationPermissionAsync()
                                if !granted {
                                    await MainActor.run {
                                        showNotificationDeniedAlert = true
                                    }
                                    return
                                }
                            case .denied:
                                // Permission was denied - show alert
                                await MainActor.run {
                                    showNotificationDeniedAlert = true
                                }
                                return
                            case .authorized, .provisional, .ephemeral:
                                // Already authorized - continue
                                break
                            @unknown default:
                                break
                            }

                            // Now add the reminder
                            await reminderManager.addReminder(for: dateString, at: combinedReminderDate, entryBody: entryBody)
                            await MainActor.run {
                                dismiss()
                            }
                        }
                    }
                } label: {
                    Text(hasExistingReminder ? "Update Alarm" : "Set Alarm")
                        .frame(maxWidth: .infinity)
                        .font(.appHeadline())
                }
                .reminderButtonStyle()
                .padding(.horizontal)
            }
            .padding(.top, 20)
            .navigationTitle(CalendarDate(dateString: dateString)?.displayStringWithoutYear ?? dateString)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(.appTextPrimary)
                }

                if hasExistingReminder {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) {
                            if isMockMode {
                                mockStore?.removeReminder(for: dateString)
                            } else {
                                reminderManager.removeReminder(for: dateString)
                            }
                            dismiss()
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .alert("Invalid Alarm Time", isPresented: $showPastTimeAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The selected time has already passed. Please choose a future time for your anniversary alarm.")
            }
            .alert("Notifications Disabled", isPresented: $showNotificationDeniedAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Please enable notifications in Settings to receive notifications for the anniversary alarms.")
            }
        }
        .postHogScreenView("Reminder Sheet")

    }
}

// MARK: - Reminder Button Style

private struct ReminderButtonStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .foregroundColor(.appBackground)
                .frame(height: 48)
                .background(.appAccent)
                .clipShape(Capsule())
                .glassEffect(.regular.interactive())
        } else {
            content
                .foregroundColor(.appBackground)
                .frame(height: 48)
                .background(.appAccent)
                .clipShape(Capsule())
                .shadow(color: .appBackground.opacity(0.15), radius: 8, x: 0, y: 4)
        }
    }
}

private extension View {
    func reminderButtonStyle() -> some View {
        self.modifier(ReminderButtonStyleModifier())
    }
}

// MARK: - Preview

#Preview("No Reminder") {
    ReminderSheet(dateString: CalendarDate.today().dateString)
}

#Preview("With Entry Body") {
    ReminderSheet(dateString: CalendarDate.from(Date().addingTimeInterval(86400)).dateString, entryBody: "Meeting with the team to discuss project updates")
}

#Preview("Mock Mode - Tutorial") {
    struct MockPreview: View {
        @StateObject private var mockStore = MockDataStore()

        var body: some View {
            ReminderSheet(
                dateString: CalendarDate.from(Date().addingTimeInterval(86400)).dateString,
                entryBody: "Test entry for tutorial",
                mockStore: mockStore
            )
        }
    }
    return MockPreview()
}
