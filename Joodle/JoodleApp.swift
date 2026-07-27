//
//  JoodleApp.swift
//  Joodle
//
//  Created by Li Yuxuan on 10/8/25.
//

import CloudKit
import SwiftData
import SwiftUI
import UIKit
import Combine
import PostHog
import BackgroundTasks

// AppDelegate to enforce portrait orientation and handle notifications
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    // Set self as the notification center delegate to handle foreground notifications
    UNUserNotificationCenter.current().delegate = self

    // PostHog - Read from Info.plist (configured via Secrets.xcconfig)
    if let apiKey = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String,
       let host = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_HOST") as? String,
       !apiKey.isEmpty {
      let config = PostHogConfig(apiKey: apiKey, host: host)
      PostHogSDK.shared.setup(config)
      print("✅ PostHog configured successfully.")

      // Identify user with device vendor ID (persists across sessions, respects privacy)
      if let vendorId = UIDevice.current.identifierForVendor?.uuidString {
        AnalyticsManager.shared.identifyUser(anonymousId: vendorId)
        print("✅ PostHog user identified: \(vendorId)")
      }
    } else {
      print("⚠️ PostHog not configured. See Secrets.xcconfig.template for setup instructions.")
    }

    return true
  }

  func application(
    _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    return .portrait
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    config.delegateClass = SceneDelegate.self
    return config
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// Handle notifications when the app is in the foreground
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Show the notification even when app is in foreground
    completionHandler([.banner, .sound, .badge])
  }

  /// Handle user tapping on a notification
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let identifier = response.notification.request.identifier
    let userInfo = response.notification.request.content.userInfo
    print("📬 [AppDelegate] User tapped notification: \(identifier)")

    // Check if this is a daily reminder notification
    if let isDailyReminder = userInfo["isDailyReminder"] as? Bool, isDailyReminder {
      // Track navigation from daily reminder notification
      AnalyticsManager.shared.trackNavigatedFromNotification(notificationType: "daily_reminder")

      // Navigate to today's entry, then open the drawing canvas directly so the
      // user can capture today's moment without an extra tap.
      print("📬 [AppDelegate] Daily reminder tapped - navigating to today and opening canvas")
      Task { @MainActor in
        ShortcutActionState.navigateAndOpenCanvas(date: Date())
      }

    } else if let date = DayEntry.stringToLocalDate(identifier) {
      // Track navigation from anniversary reminder notification
      AnalyticsManager.shared.trackNavigatedFromNotification(notificationType: "anniversary_reminder")

      // Anniversary reminder - the identifier is the dateString
      NotificationCenter.default.post(
        name: .navigateToDateFromShortcut,
        object: nil,
        userInfo: ["date": date]
      )
    }

    completionHandler()
  }
}

/// Singleton manager for ModelContainer to prevent multiple CloudKit registrations
/// CloudKit can only have ONE active sync handler per store - creating multiple containers
/// causes "BUG IN CLIENT OF CLOUDKIT" errors due to duplicate handler registration
final class ModelContainerManager {
  static let shared = ModelContainerManager()

  /// The single ModelContainer instance for the entire app lifecycle
  let container: ModelContainer

  /// Track whether sync was enabled when container was created
  let wasCloudSyncEnabledAtLaunch: Bool

  /// Track if this is a detected reinstall with cloud data
  let isReinstallWithCloudData: Bool

  private init() {
    let systemCloudEnabled = FileManager.default.ubiquityIdentityToken != nil

    // Check local preference first
    let localSyncPreference = UserPreferences.shared.isCloudSyncEnabled

    // Check iCloud KVS for reinstall detection (survives app deletion)
    // This allows us to restore sync immediately for reinstalling users
    let cloudStore = NSUbiquitousKeyValueStore.default
    cloudStore.synchronize()
    let cloudSyncBackup = cloudStore.bool(forKey: "is_cloud_sync_enabled_backup") ||
                          cloudStore.bool(forKey: "cloud_sync_was_enabled")

    // Determine if this is a reinstall scenario:
    // - Local preference is OFF (fresh install/reinstall clears UserDefaults)
    // - But iCloud KVS says sync WAS enabled (user had sync before)
    // - And system iCloud is available
    let isReinstall = !localSyncPreference && cloudSyncBackup && systemCloudEnabled
    isReinstallWithCloudData = isReinstall

    // Decide whether to enable CloudKit:
    // 1. User's local preference says YES, OR
    // 2. This is a reinstall with previous sync history
    // AND system iCloud must be available
    let shouldUseCloud = (localSyncPreference || isReinstall) && systemCloudEnabled
    wasCloudSyncEnabledAtLaunch = shouldUseCloud

    if isReinstall {
      print("ModelContainerManager: Detected reinstall with iCloud data - enabling CloudKit sync")
      // Restore the local preference to match what we're doing
      UserPreferences.shared.isCloudSyncEnabled = true
    }

    // Create the container once with the determined configuration
    container = Self.createContainer(shouldUseCloud: shouldUseCloud)

    // Backup preference to iCloud if sync is enabled
    if shouldUseCloud {
      cloudStore.set(true, forKey: "is_cloud_sync_enabled_backup")
      cloudStore.synchronize()
    }

    print("ModelContainerManager: Container created with CloudKit=\(shouldUseCloud), isReinstall=\(isReinstall)")
  }

  private static func createContainer(shouldUseCloud: Bool) -> ModelContainer {
    let schema = Schema([DayEntry.self])

    let config = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: false,
      cloudKitDatabase: shouldUseCloud ? .private("iCloud.dev.liyuxuan.joodle") : .none
    )

    do {
      return try ModelContainer(for: schema, configurations: [config])
    } catch {
      fatalError("Could not create ModelContainer: \(error)")
    }
  }

  /// Check if sync preference has changed since app launch (requires restart)
  var needsRestartForSyncChange: Bool {
    let userWantsCloud = UserPreferences.shared.isCloudSyncEnabled
    let systemCloudEnabled = FileManager.default.ubiquityIdentityToken != nil
    let currentDesiredState = userWantsCloud && systemCloudEnabled
    return currentDesiredState != wasCloudSyncEnabledAtLaunch
  }
}

@main
struct JoodleApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
  @State private var colorScheme: ColorScheme? = UserPreferences.shared.preferredColorScheme
  @State private var accentColor: ThemeColor = UserPreferences.shared.accentColor
  @StateObject private var chrome = AppChrome.shared
  @State private var selectedDateFromWidget: Date?
  @State private var showPaywallFromWidget = false
  @State private var showLimitedTimeOffer = false
  @State private var showLaunchScreen = true
  @State private var hasSetupObservers = false
  @State private var showPendingRestartAlert = false
  @State private var changelogEntry: ChangelogEntry?
  @State private var appLocale: Locale

  /// Remote alert service for displaying server-pushed announcements
  @StateObject private var remoteAlertService = RemoteAlertService.shared

  /// Use the singleton container - never recreate during app lifecycle
  private let modelContainer = ModelContainerManager.shared.container

  init() {
    // Initialize app environment detection (TestFlight vs App Store)
    AppEnvironment.initialize()

    // Resolve appLocale from UserPreferences (system language sync already
    // happened inside UserPreferences.init() when .shared was first accessed).
    let code = UserPreferences.shared.appLanguage
    _appLocale = State(initialValue: code.isEmpty ? .current : Locale(identifier: code))

    // Run migrations using the singleton container
    let container = ModelContainerManager.shared.container

    // Run startup data maintenance sequentially to avoid overlapping database writes.
    Self.runStartupDataMaintenance(container: container)

    // Sync theme color to widgets on startup
    Self.syncThemeColorToWidgets()

    // Sync start-of-week preference to widgets on startup
    Self.syncStartOfWeekToWidgets()

    // Sync app language preference to widgets on startup
    Self.syncAppLanguageToWidgets()

    // Restore daily reminder if it was enabled
    ReminderManager.shared.restoreDailyReminderIfNeeded()

    // Resolve the conversion-funnel cohort (legacy 30-doodle installs vs new
    // 7-doodle installs) before anything reads the free limit, then reconcile
    // trial state. Trials are claim-based now — nothing auto-starts here.
    TrialOfferManager.migrateFunnelStateIfNeeded()
    GracePeriodManager.shared.onAppLaunch()

    // DEBUG: Seed test entries for 2023 and 2024
    #if DEBUG
    DebugDataSeeder.shared.seedTestEntriesIfNeeded(container: container)
    #endif

    BackupScheduler.shared.register()
    BackupScheduler.shared.schedulePeriodicBackup()
  }

  /// Syncs the current theme color preference to widgets via App Group
  private static func syncThemeColorToWidgets() {
    Task { @MainActor in
      WidgetHelper.shared.updateThemeColor()
    }
  }

  /// Syncs the current start-of-week preference to widgets via App Group
  private static func syncStartOfWeekToWidgets() {
    Task { @MainActor in
      WidgetHelper.shared.updateStartOfWeek()
    }
  }

  /// Syncs the current app language preference to widgets via App Group
  private static func syncAppLanguageToWidgets() {
    Task { @MainActor in
      WidgetHelper.shared.updateAppLanguage()
    }
  }

  /// Runs startup data maintenance sequentially on a utility-priority background task.
  /// Keeping writes in one pipeline reduces lock contention with CloudKit mirroring.
  private static func runStartupDataMaintenance(container: ModelContainer) {
    Task.detached(priority: .utility) {
      await Self.performStartupDataMaintenance(container: container)
    }
  }

  /// One pipeline for startup data maintenance.
  /// Order matters: normalize date keys first, then content cleanups, then thumbnail work.
  private static func performStartupDataMaintenance(container: ModelContainer) async {
    runDateStringNormalization(container: container)
    runDuplicateEntryCleanup(container: container)
    runEmptyEntryCleanup(container: container)
    runLegacyThumbnailCleanup(container: container)
    await CanvasSizeMigration.runIfNeeded(container: container)
    await runDualThumbnailRegeneration(container: container)
    await runThinStrokeThumbnailRegeneration(container: container)
  }

  /// Cleans up duplicate entries (same dateString) by merging content and deleting duplicates
  /// This runs on EVERY app launch to ensure no duplicates exist (handles iCloud sync conflicts)
  private static func runDuplicateEntryCleanup(container: ModelContainer) {
    let context = ModelContext(container)
    // Use forceCleanupDuplicates to always run regardless of previous cleanup flag
    // This ensures duplicates created by iCloud sync conflicts are cleaned up
    let result = DuplicateEntryCleanup.shared.forceCleanupDuplicates(modelContext: context, markAsCompleted: false)
    if result.merged > 0 || result.deleted > 0 {
      print("DuplicateEntryCleanup: Completed - merged \(result.merged), deleted \(result.deleted)")
    }
  }

  /// Deletes entries that have no content (no text and no drawing)
  /// These serve no purpose and waste storage space
  /// This runs on EVERY app launch to clean up any accidentally created empty entries
  private static func runEmptyEntryCleanup(container: ModelContainer) {
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<DayEntry>()

    do {
      let allEntries = try context.fetch(descriptor)
      var deletedCount = 0

      for entry in allEntries {
        let hasDrawing = entry.drawingData != nil && !entry.drawingData!.isEmpty
        let hasText = !entry.body.isEmpty

        if !hasDrawing && !hasText {
          context.delete(entry)
          deletedCount += 1
        }
      }

      if deletedCount > 0 {
        try context.save()
        print("EmptyEntryCleanup: Deleted \(deletedCount) empty entries")
      }
    } catch {
      print("EmptyEntryCleanup: Failed - \(error)")
    }
  }

  /// Normalizes dateString for all entries in one pass.
  /// Handles both empty and malformed values to avoid redundant startup scans.
  private static func runDateStringNormalization(container: ModelContainer) {
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<DayEntry>()

    do {
      let allEntries = try context.fetch(descriptor)
      var normalizedCount = 0

      for entry in allEntries {
        if entry.dateString.isEmpty || CalendarDate(dateString: entry.dateString) == nil {
          entry.dateString = CalendarDate.from(entry.createdAt).dateString
          normalizedCount += 1
        }
      }

      if normalizedCount > 0 {
        try context.save()
        print("DateStringNormalization: Normalized \(normalizedCount) entries")
      }
    } catch {
      print("DateStringNormalization: Failed - \(error)")
    }
  }

  /// Cleans up legacy 1080px thumbnail data to reclaim storage
  private static func runLegacyThumbnailCleanup(container: ModelContainer) {
    let context = ModelContext(container)
    let cleanupKey = "hasCleanedLegacy1080Thumbnails_v1"

    // Only run once
    guard !UserDefaults.standard.bool(forKey: cleanupKey) else {
      return
    }

    let descriptor = FetchDescriptor<DayEntry>()

    do {
      let allEntries = try context.fetch(descriptor)
      var cleanedCount = 0

      for entry in allEntries {
        // Only clear legacy 1080px thumbnail
        if entry.drawingThumbnail1080 != nil {
          entry.drawingThumbnail1080 = nil
          cleanedCount += 1
        }
      }

      if cleanedCount > 0 {
        try context.save()
        print("LegacyThumbnailCleanup: Cleaned up \(cleanedCount) entries with 1080px thumbnails on startup")
      }

      UserDefaults.standard.set(true, forKey: cleanupKey)
    } catch {
      print("LegacyThumbnailCleanup: Failed during startup: \(error)")
    }
  }

  /// Regenerates all thumbnails with dual sizes (20px thicker strokes + 200px normal)
  private static func runDualThumbnailRegeneration(container: ModelContainer) async {
    let regenerationKey = "hasRegeneratedDualThumbnails_v1"

    // Only run once
    guard !UserDefaults.standard.bool(forKey: regenerationKey) else {
      return
    }

    let context = ModelContext(container)
    let descriptor = FetchDescriptor<DayEntry>()

    do {
      let allEntries = try context.fetch(descriptor)
      var regeneratedCount = 0

      for entry in allEntries {
        if let drawingData = entry.drawingData, !drawingData.isEmpty {
          let thumbnails = await DrawingThumbnailGenerator.shared.generateThumbnails(
            from: drawingData)
          entry.drawingThumbnail20 = thumbnails.0
          entry.drawingThumbnail200 = thumbnails.1
          regeneratedCount += 1

          // Save periodically to avoid memory buildup
          if regeneratedCount % 10 == 0 {
            try? context.save()
          }
        }
      }

      if regeneratedCount > 0 {
        try context.save()
        print("DualThumbnailRegeneration: Regenerated \(regeneratedCount) entries with 20px + 200px thumbnails on startup")
      }

      UserDefaults.standard.set(true, forKey: regenerationKey)
    } catch {
      print("DualThumbnailRegeneration: Failed during startup: \(error)")
    }
  }

  /// Regenerates thumbnails to use the unified thin stroke (1.0× multiplier)
  /// instead of the previous 3× thick-stroke variant baked into 20px thumbnails.
  private static func runThinStrokeThumbnailRegeneration(container: ModelContainer) async {
    let regenerationKey = "hasRegeneratedThinStrokeThumbnails_v4"

    guard !UserDefaults.standard.bool(forKey: regenerationKey) else {
      print("ThinStrokeThumbnailRegeneration: Skipping — \(regenerationKey) already set")
      return
    }

    print("ThinStrokeThumbnailRegeneration: Starting…")
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<DayEntry>()

    do {
      let allEntries = try context.fetch(descriptor)
      print("ThinStrokeThumbnailRegeneration: Fetched \(allEntries.count) entries; scanning for ones with drawing data")
      var regeneratedCount = 0
      var skippedCount = 0

      for entry in allEntries {
        if let drawingData = entry.drawingData, !drawingData.isEmpty {
          let thumbnails = await DrawingThumbnailGenerator.shared.generateThumbnails(
            from: drawingData)
          entry.drawingThumbnail20 = thumbnails.0
          entry.drawingThumbnail200 = thumbnails.1
          regeneratedCount += 1

          if regeneratedCount % 10 == 0 {
            try? context.save()
            print("ThinStrokeThumbnailRegeneration: Progress — \(regeneratedCount) regenerated so far")
          }
        } else {
          skippedCount += 1
        }
      }

      try context.save()
      print("ThinStrokeThumbnailRegeneration: Done — regenerated \(regeneratedCount), skipped \(skippedCount) entries with no drawing data")

      UserDefaults.standard.set(true, forKey: regenerationKey)
      print("ThinStrokeThumbnailRegeneration: Set \(regenerationKey) = true")

      // Push refreshed thumbnails to the widget shared store so the year grid
      // widget picks up the new 1× stroke renders instead of the cached 3× ones.
      if regeneratedCount > 0 {
        await MainActor.run {
          WidgetHelper.shared.updateWidgetData(in: ModelContext(container))
        }
      }
    } catch {
      print("ThinStrokeThumbnailRegeneration: Failed during startup: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        // Opaque base so the brief window between the launch screen dismissing
        // and the main content's first render reads as the app background
        // rather than a flash of the bare window.
        Color.appBackground.ignoresSafeArea()

        if !hasCompletedOnboarding {
          OnboardingFlowView()
            .environment(\.userPreferences, UserPreferences.shared)
            .preferredColorScheme(colorScheme)
            .font(.appFont(size: 17))
            .onChange(of: hasCompletedOnboarding) { _, completed in
              if completed {
                // Track onboarding completion
                AnalyticsManager.shared.trackOnboardingCompleted()

                // Check if restart is pending for iCloud sync
                checkPendingRestartAfterOnboarding()
              }
            }
        } else if !showLaunchScreen {
          // Defer mounting the main content until the launch screen dismisses.
          // On cold launch straight into the grid, mounting ContentView as the
          // very first content — while the scene is still settling and the launch
          // overlay is up — made its whole subtree fail to render on non-DI
          // devices (iPhone SE / iOS 26). Mounting it after the launch screen is
          // gone reproduces the always-working onboarding→content path.
          //
          // On cold launch iOS 26's NavigationStack lays its content out at the
          // content's collapsed "ideal" size (≈72×355 on iPhone SE) instead of its
          // own full bounds, leaving the UI rendered into a sliver. The stack's
          // outer frame is correct, so measure it with a GeometryReader placed
          // above the stack and pin ContentView to that size — a fixed frame both
          // overrides the bad proposal and makes ContentView's ideal size full, so
          // the stack proposes the full size back with no clipping.
          GeometryReader { navProxy in
          NavigationStack {
            ContentView(selectedDateFromWidget: $selectedDateFromWidget)
              .frame(width: navProxy.size.width, height: navProxy.size.height)
              .environment(\.userPreferences, UserPreferences.shared)
              .environment(\.cloudSyncManager, CloudSyncManager.shared)
              .environment(\.networkMonitor, NetworkMonitor.shared)
              .environment(\.preferencesSyncManager, PreferencesSyncManager.shared)
              .preferredColorScheme(colorScheme)
              .font(.appFont(size: 17))
              .onAppear {
                // Only setup observers once to prevent duplicate notifications
                if !hasSetupObservers {
                  setupColorSchemeObserver()
                  hasSetupObservers = true
                  // PostHog automatically tracks "Application Opened" event
                }
              }
              .onOpenURL { url in
                handleWidgetURL(url)
              }
              .onReceive(NotificationCenter.default.publisher(for: .navigateToDateFromShortcut)) { notification in
                // Handle navigation from App Shortcut (Siri/Spotlight) or push notifications
                let date = (notification.userInfo?["date"] as? Date) ?? Date()

                // Track navigation from shortcut (if not already tracked by notification handler)
                if notification.userInfo?["source"] as? String == "shortcut" {
                  AnalyticsManager.shared.track(.navigatedFromShortcut)
                }

                NavigationHelper.navigateToDate(date, selectedDateBinding: $selectedDateFromWidget)
              }
              .onReceive(NotificationCenter.default.publisher(for: .dismissToRootAndNavigate)) { _ in
                // Dismiss any presented sheets (e.g., paywall from Settings)
                NavigationHelper.dismissAllPresentedViews()
                Haptic.play()
              }
              .sheet(isPresented: $showPaywallFromWidget) {
                StandalonePaywallView(source: "widget")
                  .presentationDetents([.large])
              }
              .sheet(isPresented: $showLimitedTimeOffer, onDismiss: {
                LimitedTimeOfferManager.shared.markCurrentCampaignSeen()
              }) {
                StandalonePaywallView(source: "lto_auto", context: .limitedTimeOffer)
                  .presentationDetents([.large])
              }
              .task {
                // Auto-present the limited-time offer once per campaign, only after
                // the main content is mounted (this branch already runs post-launch-
                // screen, honoring the cold-launch render-abort constraint). Defer to
                // any changelog so we never stack two sheets on the same launch.
                await LimitedTimeOfferManager.shared.refresh()
                guard hasCompletedOnboarding, changelogEntry == nil else { return }
                // A pending post-trial sheet or claim-offer auto-present owns
                // the launch (ContentView presents those and consumes our
                // auto-present); racing them here would stack two sheets from
                // different presenters.
                guard !TrialOfferManager.shared.shouldPresentPostTrialSheet else { return }
                if LimitedTimeOfferManager.shared.shouldAutoPresent {
                  try? await Task.sleep(for: .milliseconds(400))
                  if changelogEntry == nil && !showPaywallFromWidget {
                    showLimitedTimeOffer = true
                  }
                }
              }
              .alert("Enable iCloud Sync", isPresented: $showPendingRestartAlert) {
                Button("Later", role: .cancel) {
                  // Clear the flag - user can enable later in settings
                  UserDefaults.standard.removeObject(forKey: "pending_icloud_sync_restart")
                }
                Button("Restart Now") {
                  UserDefaults.standard.removeObject(forKey: "pending_icloud_sync_restart")
                  // Small delay to ensure data is saved
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    exit(0)
                  }
                }
              } message: {
                Text("To start syncing your Joodles to iCloud, Joodle needs to restart.\n\nYour Joodle has been saved and will sync after restart.")
              }
              .onAppear {
                // Check for pending restart when main content appears
                checkPendingRestartAfterOnboarding()
              }
          }
          // Non-blocking feature-discovery tooltips for already-onboarded
          // users. Lives only in this branch so it never covers onboarding.
          .overlay {
            FeatureTipOverlayView()
          }
          }
        }

        if showLaunchScreen {
          LaunchScreenView()
            .onAppear {
              DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showLaunchScreen = false
                // Check for changelog after launch screen dismisses
                // Remote alerts will be checked after changelog check completes (if no changelog shown)
                checkForChangelogThenRemoteAlerts()
              }
            }
        }
      }
      // A screen that commits to one scheme (the paywall) takes the window with
      // it, so the status bar and other system chrome match what it renders.
      .preferredColorScheme(chrome.forcedColorScheme ?? colorScheme)
      .tint(accentColor.color)
      .environment(\.locale, appLocale)
      // One-time per build: force save-to-album ON for everyone. The Photos
      // add-only permission is resolved lazily at the next capture (not here),
      // so brand-new users aren't prompted out of context on launch.
      .onAppear {
        UserPreferences.shared.forceSaveToAlbumOnIfNeeded()
      }
      .remoteAlertOverlay(service: remoteAlertService)
      .sheet(item: $changelogEntry, onDismiss: {
        changelogEntry = nil
      }) { entry in
        NavigationStack {
          ChangelogDetailView(entry: entry)
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.large)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
      }
      .onChange(of: changelogEntry) { oldValue, newValue in
        // Mark as seen when changelog is dismissed (newValue is nil, oldValue was shown)
        if newValue == nil && oldValue != nil {
          ChangelogManager.shared.markCurrentVersionAsSeen()
        }
      }
    }
    .modelContainer(modelContainer)
  }

  private func setupColorSchemeObserver() {
    NotificationCenter.default.addObserver(
      forName: .didChangeColorScheme,
      object: nil,
      queue: .main
    ) { [self] _ in
      colorScheme = UserPreferences.shared.preferredColorScheme
    }

    NotificationCenter.default.addObserver(
      forName: .didChangeAccentColor,
      object: nil,
      queue: .main
    ) { [self] _ in
      accentColor = UserPreferences.shared.accentColor
    }

    NotificationCenter.default.addObserver(
      forName: .didChangeAppLanguage,
      object: nil,
      queue: .main
    ) { [self] _ in
      let code = UserPreferences.shared.appLanguage
      appLocale = code.isEmpty ? .current : Locale(identifier: code)
      Task { @MainActor in
        WidgetHelper.shared.updateAppLanguage()
      }
    }
  }

  /// Check if a restart is pending after onboarding for iCloud sync
  private func checkPendingRestartAfterOnboarding() {
    if UserDefaults.standard.bool(forKey: "pending_icloud_sync_restart") {
      // Small delay to let the UI settle after onboarding dismisses
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        showPendingRestartAlert = true
      }
    }
  }

  /// Checks for changelog first, then remote alerts if no changelog is shown.
  /// Remote alerts are skipped during onboarding or when changelog is displayed.
  private func checkForChangelogThenRemoteAlerts() {
    // Skip everything during onboarding - user should complete onboarding first
    guard hasCompletedOnboarding else { return }

    // Small delay to ensure app is fully ready, then fetch async
    // Fetch remote prompts independently — fire-and-forget, no UI dependency
    Task {
      await PromptsManager.shared.fetchRemotePrompts()
    }

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      await ChangelogManager.shared.checkAndPrepareChangelog()
      if let entry = ChangelogManager.shared.changelogToShow {
        // Show changelog - skip remote alerts for this launch
        // (user will see remote alert on next launch if conditions are met)
        changelogEntry = entry
      } else {
        // No changelog to show - safe to check for remote alerts
        await remoteAlertService.checkForAlert()
      }
    }
  }

  private func handleWidgetURL(_ url: URL) {
    guard url.scheme == "joodle" else { return }

    // Track deep link opened
    AnalyticsManager.shared.trackDeepLinkOpened(url: url.absoluteString, source: "widget")

    // Handle URL scheme: joodle://paywall
    if url.host == "paywall" {
      // Check subscription status before showing paywall
      Task {
        await SubscriptionManager.shared.updateSubscriptionStatus()

        // If not subscribed, show the paywall
        if !SubscriptionManager.shared.hasPremiumAccess {
          showPaywallFromWidget = true
        }
      }
      return
    }

    // Handle URL scheme: joodle://date/{dateString or timestamp}
    // Track navigation from widget
    // Supports both new dateString format (yyyy-MM-dd) and legacy timestamp format
    if url.host == "date" {
      let pathComponents = url.pathComponents
      if pathComponents.count >= 2 {
        let identifier = pathComponents[1]

        // Try parsing as dateString (yyyy-MM-dd) first
        if let calendarDate = CalendarDate(dateString: identifier) {
          AnalyticsManager.shared.trackNavigatedFromWidget(widgetType: "date")
          NavigationHelper.navigateToDate(calendarDate.displayDate, selectedDateBinding: $selectedDateFromWidget)
        }
        // Fall back to legacy timestamp format
        else if let timestamp = TimeInterval(identifier) {
          AnalyticsManager.shared.trackNavigatedFromWidget(widgetType: "date_legacy")
          let date = Date(timeIntervalSince1970: timestamp)
          NavigationHelper.navigateToDate(date, selectedDateBinding: $selectedDateFromWidget)
        }
      }
    }

    // Handle URL scheme: joodle://today
    if url.host == "today" {
      AnalyticsManager.shared.trackNavigatedFromWidget(widgetType: "today")
      NavigationHelper.navigateToDate(Date(), selectedDateBinding: $selectedDateFromWidget)
    }
  }
}
