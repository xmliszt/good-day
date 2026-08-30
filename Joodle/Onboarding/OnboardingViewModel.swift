import SwiftData
import SwiftUI
import Combine

// 1. The Steps: Easy to reorder or add new ones here.
enum OnboardingStep: Hashable, CaseIterable {
    case drawingEntry              // The greeting + drawing
    case valueProposition          // Confetti + Explanation
    case yearGridDemo              // Interactive tutorial in sandboxed environment
    case handednessSetup           // Pick dominant hand → camera zoom slider edge
    case featureIntroWidgets       // Feature intro: Widgets (kept - can't be interactive)
    case icloudConfig              // iCloud sync configuration
    case dailyReminder             // Daily reminder configuration
    case proPaywall                // Purchasable Joodle Pro paywall (buy now, or skip to Free)
    case onboardingCompletion      // Completion step
}

// 2. The Brain: Manages data and navigation logic
@MainActor
class OnboardingViewModel: ObservableObject {
    @Published var navigationPath = NavigationPath()

    // Data collected during onboarding
    // We store the raw JSON data representing [PathData]
    @Published var firstJoodleData: Data?
    @Published var shouldDismiss = false

    // iCloud sync preference set during onboarding
    @Published var userWantsCloudSync: Bool = false

    // Flag to indicate restart is needed after onboarding completes
    // This is checked by JoodleApp after onboarding dismisses
    @Published var needsRestartAfterOnboarding: Bool = false

    // Track if this is a revisit (user already completed onboarding before)
    // We use a separate flag because hasCompletedOnboarding is reset to false to trigger onboarding
    var isRevisitingOnboarding: Bool {
      UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") ||
      UserDefaults.standard.bool(forKey: "isRevisitFromSettings")
    }

    /// Check if this is a revisit triggered from Settings > Learn Core Features
    /// This flag ensures tutorials are shown even for users with active subscriptions
    var isRevisitFromSettings: Bool {
      UserDefaults.standard.bool(forKey: "isRevisitFromSettings")
    }

    var isReturnUser: Bool {
      // If revisiting from settings, never treat as return user (always show tutorials)
      if isRevisitFromSettings { return false }
      return !self.isRevisitingOnboarding && StoreKitManager.shared.hasActiveSubscription
    }

    /// Whether to show feature introduction steps
    /// Show for: first-time users, revisiting users from Settings
    /// Skip for: return users (reinstall with existing subscription)
    var shouldShowFeatureIntro: Bool {
        !isReturnUser
    }

    /// Whether to show the purchasable Joodle Pro paywall.
    /// Only genuine first-time users see it — revisits already know the offer,
    /// and subscribers have nothing to buy.
    var shouldShowProPaywall: Bool {
        !isRevisitingOnboarding && !StoreKitManager.shared.hasActiveSubscription
    }

    /// Advance from the final setup step to the Pro paywall (if eligible) or straight to completion.
    private func advanceAfterSetup() {
        if shouldShowProPaywall {
            navigationPath.append(OnboardingStep.proPaywall)
        } else {
            navigationPath.append(OnboardingStep.onboardingCompletion)
        }
    }

    var modelContext: ModelContext?
    private var cancellables = Set<AnyCancellable>()

    init() {
    }

    // Actions
    func completeStep(_ step: OnboardingStep) {
        // Play haptic feedback on step transition
        Haptic.play(with: .light)

        // Track step completion
        if let stepIndex = OnboardingStep.allCases.firstIndex(of: step) {
            AnalyticsManager.shared.trackOnboardingStep(stepName(for: step), stepIndex: stepIndex)
        }

        switch step {
        case .drawingEntry:
            // Track that user created a drawing during onboarding
            if firstJoodleData != nil {
                AnalyticsManager.shared.track(.onboardingDrawingCreated)
            }
            navigationPath.append(OnboardingStep.valueProposition)

        case .valueProposition:
            // After confirming first Joodle, decide next step based on user type
            if shouldShowFeatureIntro {
                // First-time user or revisiting from Settings: show interactive tutorial
                navigationPath.append(OnboardingStep.yearGridDemo)
            } else {
                // Return user (reinstall with subscription): skip feature intros
                // Go directly to iCloud config since they already have subscription
                navigationPath.append(OnboardingStep.icloudConfig)
            }

        case .yearGridDemo:
            // After interactive tutorial, let the user set their handedness
            navigationPath.append(OnboardingStep.handednessSetup)

        case .handednessSetup:
            // After choosing a slider edge, show widgets intro
            navigationPath.append(OnboardingStep.featureIntroWidgets)

        case .featureIntroWidgets:
            // After widgets intro, always go to iCloud config
            // (iCloud sync is free for all users, and grace period grants Pro access)
            navigationPath.append(OnboardingStep.icloudConfig)

        case .icloudConfig:
            // After iCloud config, go to daily reminder setup
            navigationPath.append(OnboardingStep.dailyReminder)

        case .dailyReminder:
            // After daily reminder config, show the Pro paywall (or skip to completion)
            advanceAfterSetup()

        case .proPaywall:
            // After the paywall (purchased or skipped to Free), finish up
            navigationPath.append(OnboardingStep.onboardingCompletion)

        case .onboardingCompletion:
            finishOnboarding()
        }
    }

    /// Called when user decides to skip iCloud sync setup
    func skipCloudSync() {
        Haptic.play(with: .light)
        userWantsCloudSync = false

        // Track that user skipped iCloud sync
        AnalyticsManager.shared.trackSettingChanged(name: "icloud_sync_onboarding", value: "skipped")

        advanceAfterSetup()
    }

    func goBack() {
        guard !navigationPath.isEmpty else { return }
        Haptic.play(with: .light)
        navigationPath.removeLast()
    }

    private func finishOnboarding() {
        // Track onboarding completion with user properties
        AnalyticsManager.shared.setUserProperties(
            isSubscribed: StoreKitManager.shared.hasActiveSubscription,
            hasCompletedOnboarding: true,
            entryCount: 1  // At least the onboarding drawing
        )

        // Save flags to UserDefaults to hide onboarding on next launch
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")

        // Suppress feature-discovery tooltips for genuine new installs — the
        // onboarding tutorial already taught these features. Skip when this is
        // a "Revisit Onboarding" run from Settings so existing users don't lose
        // pending new-feature tips. (Checked before the flag is cleared below.)
        let isRevisitFromSettings = UserDefaults.standard.bool(forKey: "isRevisitFromSettings")
        if !isRevisitFromSettings {
            FeatureTipManager.shared.markAllCurrentTipsAsSeen()

            // Start Pro users with auto-trace on so the button is there to
            // discover (the feature tip then teaches it); free users keep it off
            // since they can't use it.
            if SubscriptionManager.shared.hasPremiumAccess {
                UserPreferences.shared.isAutoTraceEnabled = true
            }
        }

        // Clear the revisit from settings flag
        UserDefaults.standard.removeObject(forKey: "isRevisitFromSettings")

        // Always save the drawing immediately to local database
        // This ensures the drawing is never lost, regardless of sync state
        saveOnboardingDrawing()

        // Enable iCloud sync if user opted in during onboarding
        enableCloudSyncIfRequested()

        // Check if restart is needed for iCloud sync to take effect
        if userWantsCloudSync && ModelContainerManager.shared.needsRestartForSyncChange {
            needsRestartAfterOnboarding = true
            // Save flag so JoodleApp knows to show restart alert
            UserDefaults.standard.set(true, forKey: "pending_icloud_sync_restart")
        }

        shouldDismiss = true
    }

    /// Save the onboarding drawing to the database immediately
    func saveOnboardingDrawing() {
        guard let data = firstJoodleData, !data.isEmpty, let context = modelContext else {
            print("OnboardingViewModel: No drawing data to save or no context")
            return
        }

        // Use CalendarDate for timezone-agnostic "today" determination
        let todayCalendarDate = CalendarDate.today()

        // Use findOrCreate to get the single entry for this date (merges duplicates if any)
        let entryToUpdate = DayEntry.findOrCreate(for: todayCalendarDate, in: context)
        let isNewJoodle = entryToUpdate.drawingData == nil || entryToUpdate.drawingData?.isEmpty == true

        // If this is a revisit onboarding, check Joodle limits
        if isRevisitingOnboarding {
            let allEntriesDescriptor = FetchDescriptor<DayEntry>()
            do {
                let allEntries = try context.fetch(allEntriesDescriptor)

                if isNewJoodle {
                    // User is trying to create a NEW Joodle via revisit onboarding
                    // Check if they're within their Joodle limit
                    let currentJoodleCount = SubscriptionManager.shared.totalJoodleCount(from: allEntries)

                    if !SubscriptionManager.shared.canCreateJoodle(currentTotalCount: currentJoodleCount) {
                        print("OnboardingViewModel: Joodle limit reached, skipping save during revisit onboarding")
                        return
                    }
                } else {
                    // User is trying to EDIT an existing entry via revisit onboarding
                    // Check if this Joodle is within the editable range for free users
                    let entriesWithDrawings = allEntries
                        .filter { $0.drawingData != nil }
                        .sorted { $0.dateString < $1.dateString }

                    if let index = entriesWithDrawings.firstIndex(where: { $0.id == entryToUpdate.id }) {
                        if !SubscriptionManager.shared.canEditJoodle(atIndex: index) {
                            print("OnboardingViewModel: Joodle #\(index + 1) is locked, skipping edit during revisit onboarding")
                            return
                        }
                    }
                }
            } catch {
                print("OnboardingViewModel: Failed to fetch entries for limit check: \(error)")
            }
        }

        // Update the entry with drawing data
        entryToUpdate.drawingData = data

        // Save immediately
        do {
            try context.save()
          print("OnboardingViewModel: Drawing saved successfully for \(todayCalendarDate.dateString)")
        } catch {
            print("OnboardingViewModel: Failed to save drawing: \(error)")
        }

        // Generate thumbnails asynchronously
        Task {
            let thumbnails = await DrawingThumbnailGenerator.shared.generateThumbnails(from: data)
            entryToUpdate.drawingThumbnail20 = thumbnails.0
            entryToUpdate.drawingThumbnail200 = thumbnails.1
            try? context.save()
            print("OnboardingViewModel: Thumbnails generated and saved")
        }
    }

    /// Update iCloud sync preference based on user's choice during onboarding
    private func enableCloudSyncIfRequested() {
        // During revisit onboarding, user can disable iCloud sync
        if !userWantsCloudSync && isRevisitingOnboarding && UserPreferences.shared.isCloudSyncEnabled {
            print("OnboardingViewModel: User opted to disable iCloud sync during revisit onboarding")

            // Use CloudSyncManager to properly disable sync
            CloudSyncManager.shared.disableSync()
            return
        }

        // Only enable if user explicitly opted in
        guard userWantsCloudSync else {
            print("OnboardingViewModel: User did not opt in for iCloud sync")
            return
        }

        // iCloud sync is free for all users - no subscription check needed

        // Check if iCloud sync is already enabled
        guard !UserPreferences.shared.isCloudSyncEnabled else {
            print("OnboardingViewModel: iCloud sync already enabled")
            return
        }

        // Check system requirements
        let syncManager = CloudSyncManager.shared
        guard syncManager.isCloudAvailable && syncManager.systemCloudEnabled else {
            print("OnboardingViewModel: iCloud sync not enabled - system requirements not met")
            print("   isCloudAvailable: \(syncManager.isCloudAvailable)")
            print("   systemCloudEnabled: \(syncManager.systemCloudEnabled)")
            return
        }

        print("OnboardingViewModel: Enabling iCloud sync preference")

        // Enable the sync preference
        UserPreferences.shared.isCloudSyncEnabled = true

        // Save sync state to iCloud KVS for future reinstall recovery
        let cloudStore = NSUbiquitousKeyValueStore.default
        cloudStore.set(true, forKey: "is_cloud_sync_enabled_backup")
        cloudStore.set(true, forKey: "cloud_sync_was_enabled")
        cloudStore.synchronize()

        // Check if container was created with different sync state
        if ModelContainerManager.shared.needsRestartForSyncChange {
            print("OnboardingViewModel: Container needs restart for sync to take effect")
        } else {
            print("OnboardingViewModel: Container already configured for sync, no restart needed")
        }
    }

    /// Check if iCloud sync can be enabled (system requirements met)
    var canEnableCloudSync: Bool {
        let syncManager = CloudSyncManager.shared
        return syncManager.isCloudAvailable && syncManager.systemCloudEnabled
    }

    /// Reason why iCloud sync cannot be enabled
    var cloudSyncBlockedReason: LocalizedStringResource? {
        let syncManager = CloudSyncManager.shared
        if !syncManager.systemCloudEnabled {
            return "iCloud is disabled in Settings"
        }
        if !syncManager.isCloudAvailable {
            return "No iCloud account found"
        }
        return nil
    }

    /// Helper to get step name for analytics
    private func stepName(for step: OnboardingStep) -> String {
        switch step {
        case .drawingEntry: return "drawing_entry"
        case .valueProposition: return "value_proposition"
        case .yearGridDemo: return "year_grid_demo"
        case .handednessSetup: return "handedness_setup"
        case .featureIntroWidgets: return "feature_intro_widgets"
        case .icloudConfig: return "icloud_config"
        case .dailyReminder: return "daily_reminder"
        case .proPaywall: return "pro_paywall"
        case .onboardingCompletion: return "completion"
        }
    }
}
