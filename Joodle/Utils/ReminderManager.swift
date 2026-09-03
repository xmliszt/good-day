import Foundation
@preconcurrency import UserNotifications
import SwiftUI
import SwiftData
import Combine

// MARK: - Daily Reminder Constants
private enum DailyReminderConstants {
    static let notificationIdentifier = "daily_joodle_reminder"
}

struct Reminder: Codable, Identifiable, Equatable {
    var id: String { dateString }
    let dateString: String
    let reminderDate: Date
    let entryBody: String?

    static func == (lhs: Reminder, rhs: Reminder) -> Bool {
        lhs.dateString == rhs.dateString &&
        lhs.reminderDate == rhs.reminderDate &&
        lhs.entryBody == rhs.entryBody
    }
}

@MainActor
class ReminderManager: ObservableObject {
    static let shared = ReminderManager()

    @Published private(set) var reminders: [Reminder] = []

    private let localStorageKey = "joodle_reminders"
    private let cloudStorageKey = "joodle_reminders_cloud"
    private var cancellables = Set<AnyCancellable>()

    // iCloud Key-Value Store
    private let cloudStore = NSUbiquitousKeyValueStore.default
    private var cloudChangeObserver: NSObjectProtocol?

    private init() {
        loadReminders()
        cleanupOutdatedReminders()
        setupForegroundObserver()
        setupCloudObserver()

        // Perform initial sync from cloud
        syncFromCloud()
    }

    deinit {
        // Remove observer directly in deinit since it's nonisolated
        if let observer = cloudChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Persistence

    private func loadReminders() {
        if let data = UserDefaults.standard.data(forKey: localStorageKey),
           let decoded = try? JSONDecoder().decode([Reminder].self, from: data) {
            self.reminders = decoded
        }
    }

    private func saveReminders() {
        if let encoded = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(encoded, forKey: localStorageKey)
        }

        // Also sync to iCloud if cloud sync is enabled
        syncToCloud()
    }

    // MARK: - iCloud Sync

    private func setupCloudObserver() {
        // Observe changes from other devices
        cloudChangeObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleCloudChange(notification)
            }
        }

        // Start observing iCloud KVS
        cloudStore.synchronize()
    }

    private func removeCloudObserver() {
        if let observer = cloudChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            cloudChangeObserver = nil
        }
    }

    private func handleCloudChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonForChange = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
            return
        }

        switch reasonForChange {
        case NSUbiquitousKeyValueStoreServerChange,
             NSUbiquitousKeyValueStoreInitialSyncChange,
             NSUbiquitousKeyValueStoreAccountChange:
            syncFromCloud()
        default:
            break
        }
    }

    /// Push local reminders to iCloud
    private func syncToCloud() {
        guard UserPreferences.shared.isCloudSyncEnabled else { return }

        guard let encoded = try? JSONEncoder().encode(reminders) else { return }

        cloudStore.set(encoded, forKey: cloudStorageKey)
        cloudStore.synchronize()
    }

    /// Pull reminders from iCloud and merge with local
    private func syncFromCloud() {
        guard UserPreferences.shared.isCloudSyncEnabled else { return }

        cloudStore.synchronize()

        guard let data = cloudStore.data(forKey: cloudStorageKey),
              let cloudReminders = try? JSONDecoder().decode([Reminder].self, from: data) else {
            return
        }

        mergeReminders(from: cloudReminders)
    }

    /// Merge reminders from cloud with local reminders
    /// Strategy: Keep the most recent version of each reminder (by reminderDate)
    /// and add any reminders that exist only in cloud
    private func mergeReminders(from cloudReminders: [Reminder]) {
        var merged: [String: Reminder] = [:]

        // Add all local reminders first
        for reminder in reminders {
            merged[reminder.dateString] = reminder
        }

        // Merge cloud reminders - prefer the one with the later reminderDate
        var hasChanges = false
        for cloudReminder in cloudReminders {
            if let existing = merged[cloudReminder.dateString] {
                if cloudReminder.reminderDate > existing.reminderDate {
                    merged[cloudReminder.dateString] = cloudReminder
                    hasChanges = true
                }
            } else {
                merged[cloudReminder.dateString] = cloudReminder
                hasChanges = true
            }
        }

        if hasChanges {
            let newReminders = Array(merged.values)

            // Cancel all existing notifications
            for reminder in reminders {
                cancelNotification(for: reminder)
            }

            reminders = newReminders

            // Save to local storage (but don't trigger another cloud sync)
            if let encoded = try? JSONEncoder().encode(reminders) {
                UserDefaults.standard.set(encoded, forKey: localStorageKey)
            }

            // Reschedule notifications for all reminders
            for reminder in reminders {
                scheduleNotification(for: reminder)
            }
        }
    }

    /// Force a full sync (pull then push)
    func performFullSync() {
        guard UserPreferences.shared.isCloudSyncEnabled else { return }
        syncFromCloud()
        syncToCloud()
    }

    // MARK: - Foreground Observer

    private func setupForegroundObserver() {
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.cleanupOutdatedReminders()
                    self?.syncFromCloud()
                    // Ensure daily reminder is scheduled (uses repeating trigger)
                    self?.refreshDailyReminderIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Reminder Management

    @discardableResult
    func addReminder(for dateString: String, at date: Date, entryBody: String? = nil) async -> Bool {
        // Debug logging
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .long
        formatter.timeZone = .current

        // Remove existing reminder for this dateString if any
        removeReminder(for: dateString, notify: false)

        let reminder = Reminder(dateString: dateString, reminderDate: date, entryBody: entryBody)
        reminders.append(reminder)
        saveReminders()
        scheduleNotification(for: reminder)

        // Track anniversary reminder created
        AnalyticsManager.shared.trackAnniversaryReminderCreated(forDate: date)

        return true
    }

    func removeReminder(for dateString: String, notify: Bool = true) {
        if let reminder = reminders.first(where: { $0.dateString == dateString }) {
            cancelNotification(for: reminder)
            reminders.removeAll { $0.dateString == dateString }
            if notify {
                saveReminders()
                // Track anniversary reminder deleted
                AnalyticsManager.shared.trackAnniversaryReminderDeleted()
            }
        }
    }

    func getReminder(for dateString: String) -> Reminder? {
        return reminders.first(where: { $0.dateString == dateString })
    }

    func cleanupOutdatedReminders() {
        let now = Date()
        let outdated = reminders.filter { $0.reminderDate < now }

        guard !outdated.isEmpty else { return }

        for reminder in outdated {
            cancelNotification(for: reminder)
        }
        reminders.removeAll { $0.reminderDate < now }
        saveReminders()
    }

    // MARK: - Notifications

    private func scheduleNotification(for reminder: Reminder) {
        let now = Date()

        // Debug logging
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .long
        formatter.timeZone = .current

        // Check if the reminder date is in the past
        if reminder.reminderDate <= now {
            print("⚠️ [ReminderManager] WARNING: Reminder date is in the PAST! Skipping notification.")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Joodle Reminder")
        content.body = formatNotificationBody(for: reminder)
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: reminder.reminderDate
        )

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        print("   - Next trigger date: \(String(describing: trigger.nextTriggerDate()))")

        let request = UNNotificationRequest(
            identifier: reminder.id,
            content: content,
            trigger: trigger
        )

        // Check authorization status first
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus != .authorized {
                print("❌ [ReminderManager] Notifications NOT authorized!")
                return
            }

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("❌ [ReminderManager] Error scheduling notification: \(error)")
                } else {
                    print("✅ [ReminderManager] Notification scheduled successfully for \(reminder.id)")
                }
            }
        }
    }

    private func cancelNotification(for reminder: Reminder) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [reminder.id]
        )
    }

    private func formatNotificationBody(for reminder: Reminder) -> String {
        // Use entry body if available and not empty
        if let body = reminder.entryBody, !body.isEmpty {
            // Truncate if too long for notification
            let maxLength = 100
            if body.count > maxLength {
                return String(body.prefix(maxLength)) + "..."
            }
            return body
        }

        // Fallback to default text with formatted date
        guard let date = DayEntry.stringToLocalDate(reminder.dateString) else {
            return String(localized: "Time to check your Joodle!")
        }

        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let formattedDate = formatter.string(from: date)

        return String(localized: "Time to check your Joodle for \(formattedDate)")
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error = error {
                print("Error requesting notification permission: \(error)")
            }
            if granted {
                print("Notification permission granted")
            }
        }
    }

    /// Check current notification authorization status
    func checkNotificationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - Daily Reminder

    /// Request notification permission and return whether it was granted
    func requestNotificationPermissionAsync() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            print("Error requesting notification permission: \(error)")
            return false
        }
    }

    /// Enable daily reminder with permission check
    /// - Parameter time: The time for the daily reminder
    /// - Returns: True if enabled successfully, false if permission was denied
    func enableDailyReminder(at time: Date) async -> Bool {
        // Check current authorization status
        let status = await checkNotificationStatus()

        switch status {
        case .notDetermined:
            // Request permission
            let granted = await requestNotificationPermissionAsync()
            if !granted {
                return false
            }
        case .denied:
            // Permission was denied - can't enable
            return false
        case .authorized, .provisional, .ephemeral:
            // Already authorized
            break
        @unknown default:
            break
        }

        // Schedule the notification
        scheduleDailyReminder(at: time)

        // Track daily reminder enabled
        AnalyticsManager.shared.trackDailyReminderEnabled(time: time)

        return true
    }

    /// Disable daily reminder
    func disableDailyReminder() {
        cancelDailyReminder()
        // Track daily reminder disabled
        AnalyticsManager.shared.trackDailyReminderDisabled()
    }

    /// Update daily reminder time (reschedules if enabled)
    func updateDailyReminderTime(_ time: Date) {
        if UserPreferences.shared.isDailyReminderEnabled {
            // Reschedule with new time
            scheduleDailyReminder(at: time)
            // Track daily reminder time changed
            AnalyticsManager.shared.trackDailyReminderTimeChanged(newTime: time)
        }
    }

    /// Schedule the daily reminder notification
    private func scheduleDailyReminder(at time: Date) {
        // Cancel existing daily reminder first
        cancelDailyReminder()

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time to Joodle 🌸")
        content.body = String(localized: "Capture today's moment in Joodle.")
        content.sound = .default

        // Use userInfo to indicate this is a daily reminder that should navigate to today
        content.userInfo = ["isDailyReminder": true]

        // Extract hour and minute from the time
        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute], from: time)

        // Use a repeating trigger with only hour and minute components
        // This ensures the notification fires every day at the same time,
        // regardless of whether the user opens the app or taps the notification
        var triggerComponents = DateComponents()
        triggerComponents.hour = timeComponents.hour
        triggerComponents.minute = timeComponents.minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: true)

        let request = UNNotificationRequest(
            identifier: DailyReminderConstants.notificationIdentifier,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ [ReminderManager] Error scheduling daily reminder: \(error)")
            } else {
                print("✅ [ReminderManager] Daily reminder scheduled for \(timeComponents.hour ?? 0):\(String(format: "%02d", timeComponents.minute ?? 0)) (repeating daily)")
            }
        }
    }

    /// Refresh the daily reminder if needed
    /// With repeating triggers, this is mainly used to ensure the reminder is scheduled
    /// after preference changes or app updates
    func refreshDailyReminderIfNeeded() {
        guard UserPreferences.shared.isDailyReminderEnabled else { return }

        // Reschedule the repeating daily reminder
        scheduleDailyReminder(at: UserPreferences.shared.dailyReminderTime)
    }

    /// Cancel the daily reminder notification
    private func cancelDailyReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [DailyReminderConstants.notificationIdentifier]
        )
        print("🗑️ [ReminderManager] Daily reminder cancelled")
    }

    /// Restore daily reminder on app launch if it was enabled
    func restoreDailyReminderIfNeeded() {
        if UserPreferences.shared.isDailyReminderEnabled {
            scheduleDailyReminder(at: UserPreferences.shared.dailyReminderTime)
        }
    }
}
