import CoreHaptics
import Observation
import Photos
import SwiftData
import SwiftUI

// MARK: - Navigation Coordinator for Swipe Back Gesture
struct NavigationGestureEnabler: UIViewControllerRepresentable {
  var isEnabled: Bool = true
  
  func makeUIViewController(context: Context) -> UIViewController {
    let controller = UIViewController()
    return controller
  }
  
  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
    DispatchQueue.main.async {
      if let navigationController = uiViewController.navigationController {
        navigationController.interactivePopGestureRecognizer?.isEnabled = isEnabled
        navigationController.interactivePopGestureRecognizer?.delegate = context.coordinator
      }
    }
  }
  
  func makeCoordinator() -> Coordinator {
    Coordinator()
  }
  
  class Coordinator: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      return true
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      return false
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      return false
    }
  }
}

// MARK: - Settings Icon View
struct SettingsIconView: View {
  let systemName: String
  let backgroundColor: Color
  
  var body: some View {
    Image(systemName: systemName)
      .font(.appFont(size: 12, weight: .semibold))
      .foregroundColor(.white)
      .frame(width: 24, height: 24)
      .background(backgroundColor)
      .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}

// MARK: - Settings Row View
struct SettingsRowView: View {
  let icon: String
  let iconColor: Color
  let title: LocalizedStringResource
  var trailingText: String? = nil
  var trailingView: AnyView? = nil
  var isExternal: Bool = false
  
  var body: some View {
    HStack {
      SettingsIconView(systemName: icon, backgroundColor: iconColor)
      Text(title)
        .foregroundColor(.primary)
      Spacer()
      if let text = trailingText {
        Text(text)
          .font(.appSubheadline())
          .foregroundColor(.secondary)
      }
      if let view = trailingView {
        view
      }
      if isExternal {
        Image(systemName: "arrow.up.right")
          .font(.appCaption())
          .foregroundColor(.secondary)
      }
    }
    .contentShape(Rectangle())
  }
}

// MARK: - Membership Banner View (Reusable Component)

struct MembershipBannerView: View {
  let hasPremiumAccess: Bool
  let isInGracePeriod: Bool
  let gracePeriodDaysRemaining: Int
  let statusMessage: String?
  let onTap: () -> Void

  private func localizedDayCount(_ count: Int) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .full
    formatter.maximumUnitCount = 1
    formatter.zeroFormattingBehavior = .dropAll
    formatter.allowedUnits = [.day]

    var components = DateComponents()
    components.day = count

    return formatter.string(from: components) ?? String(count)
  }
  
  var body: some View {
    Button(action: onTap) {
      ZStack(alignment: .topLeading) {
        // Background image (1200x600 = 2:1 aspect ratio)
        // Pro Banner for subscribed and grace period, Free Banner otherwise
        Image(hasPremiumAccess ? "Others/Pro Banner" : "Others/Free Banner")
          .resizable()
          .aspectRatio(2/1, contentMode: .fit)
        
        // Content overlay - positioned at top to avoid mushroom glow at bottom
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(hasPremiumAccess ? "Joodle Pro" : "Keep your Joodle Pro")
              .font(.appHeadline())
              .fontWeight(.bold)
              .foregroundColor(hasPremiumAccess ? .white : .black)
            Spacer()
            Image(systemName: "chevron.right")
              .font(.appCaption())
              .foregroundColor(hasPremiumAccess ? .white.opacity(0.8) : .black.opacity(0.8))
          }
          
          if hasPremiumAccess {
            if isInGracePeriod {
              Text(String(localized: "Pro Trial · \(localizedDayCount(gracePeriodDaysRemaining)) left"))
                .font(.appSubheadline())
                .foregroundColor(.white.opacity(0.9))
            } else if let statusMessage = statusMessage {
              Text(statusMessage)
                .font(.appSubheadline())
                .foregroundColor(.white.opacity(0.9))
            } else {
              Text("Thanks for supporting Joodle!")
                .font(.appSubheadline())
                .foregroundColor(.white.opacity(0.9))
            }
          } else {
            Text("Doodle today free — Pro fills any day")
              .font(.appSubheadline())
              .foregroundColor(.black.opacity(0.8))
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
      }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
  }
}

struct SettingsView: View {
  @Environment(\.userPreferences) private var userPreferences
  @Environment(\.cloudSyncManager) private var cloudSyncManager
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.modelContext) private var modelContext
  @Environment(\.openURL) private var openURL
  @StateObject private var subscriptionManager = SubscriptionManager.shared
  @StateObject private var storeKitManager = StoreKitManager.shared
  @StateObject private var reminderManager = ReminderManager.shared
  @StateObject private var ltoManager = LimitedTimeOfferManager.shared
  @StateObject private var trialOfferManager = TrialOfferManager.shared
  
  /// When true, auto-navigates to Customization and scrolls to note prompt setting
  @Binding var navigateToNotePromptSetting: Bool
  
  init(navigateToNotePromptSetting: Binding<Bool> = .constant(false)) {
    self._navigateToNotePromptSetting = navigateToNotePromptSetting
  }
  @State private var showOnboarding = false
  @State private var showNotificationDeniedAlert = false
  @State private var showPaywall = false
  @State private var paywallSource = "settings"
  @State private var showSubscriptions = false
  @State private var showTrialStatus = false
  @State private var showLimitedTimeOffer = false
  @State private var showTrialClaim = false

  @State private var showRedeemCode = false
  @State private var showFaq = false
  @State private var showShareSheet = false
  @State private var showDeviceIdentifierAlert = false
  @State private var isAppUpdateAvailable = false

  
  /// Check if restart is needed for sync to work
  private var needsRestartForSync: Bool {
    userPreferences.isCloudSyncEnabled && ModelContainerManager.shared.needsRestartForSyncChange
  }
  
  // Debug: Simulate production environment - bound to AppEnvironment
  @State private var simulateProductionEnvironment = AppEnvironment.simulateProductionEnvironment

  // Navigation state for sub-pages
  @State private var showExperimentalFeatures = false
  @State private var showCustomization = false
  @State private var scrollToNotePromptSetting = false

  // Language change state
  @State private var showLanguageRestartAlert = false
  @State private var selectedLanguage: AppLanguage = {
    if let lang = AppLanguage.from(code: UserPreferences.shared.appLanguage) {
      return lang
    }
    return AppLanguage.from(code: LocaleProvider.currentLanguageCode) ?? .en
  }()
  
  // MARK: - Computed Bindings
  private var viewModeBinding: Binding<ViewMode> {
    Binding(
      get: { userPreferences.defaultViewMode },
      set: { userPreferences.defaultViewMode = $0 }
    )
  }
  
  private var colorSchemeBinding: Binding<ColorScheme?> {
    Binding(
      get: { userPreferences.preferredColorScheme },
      set: { newValue in
        let previousValue = userPreferences.preferredColorScheme
        userPreferences.preferredColorScheme = newValue
        // Force UI update immediately
        NotificationCenter.default.post(name: .didChangeColorScheme, object: nil)
        // Track color scheme change
        let newSchemeString = newValue == nil ? "system" : (newValue == .light ? "light" : "dark")
        let previousSchemeString = previousValue == nil ? "system" : (previousValue == .light ? "light" : "dark")
        if newSchemeString != previousSchemeString {
          AnalyticsManager.shared.trackColorSchemeChanged(to: newSchemeString)
        }
      }
    )
  }
  
  private var hapticBinding: Binding<Bool> {
    Binding(
      get: { userPreferences.enableHaptic },
      set: { userPreferences.enableHaptic = $0 }
    )
  }
  
  private var dailyReminderTimeBinding: Binding<Date> {
    Binding(
      get: { userPreferences.dailyReminderTime },
      set: { newTime in
        userPreferences.dailyReminderTime = newTime
        reminderManager.updateDailyReminderTime(newTime)
      }
    )
  }
  
  private var startOfWeekBinding: Binding<String> {
    Binding(
      get: { userPreferences.startOfWeek },
      set: {
        userPreferences.startOfWeek = $0
        WidgetHelper.shared.updateStartOfWeek()
      }
    )
  }

  private var languageRestartAlertTitle: String {
    localizedString("Language Changed", for: selectedLanguage.code)
  }

  private var languageRestartAlertMessage: String {
    localizedString("Please restart Joodle for the change to take full effect.", for: selectedLanguage.code)
  }

  private var languageRestartAlertConfirmLabel: String {
    localizedString("OK", for: selectedLanguage.code)
  }

  /// Resolves a string in a specific target language rather than the app's
  /// current language — used to show the language-change alert in the language
  /// the user is switching *to*.
  ///
  /// Takes a `LocalizedStringResource` (not a raw `String`) so the literal at the
  /// call site is auto-extracted into the String Catalog. That keeps these keys
  /// from silently going missing, and stops Xcode flagging them as stale.
  private func localizedString(_ resource: LocalizedStringResource, for languageCode: String) -> String {
    var localized = resource
    localized.locale = Locale(identifier: languageCode)
    return String(localized: localized)
  }
  
  var body: some View {
    Form {
      if isNonProductionEnvironment {
        betaTesterSection
      }
      membershipBannerSection
      generalSection
      labSection
      externalSettingsSection
      needHelpSection
      getInvolvedSection
      legalSection
      footerSection
      developerOptionsSection
    }
    .background(NavigationGestureEnabler(isEnabled: true))
    // Scope for the Wiggly Strokes feature tip — shows on landing (before the
    // Labs row scrolls into view) and reliably hides when any child is pushed.
    .featureTipScope(FeatureTipDefinitions.ScopeID.settings)
    .navigationDestination(isPresented: $showExperimentalFeatures) {
      ExperimentalFeaturesView()
        .postHogScreenView("Experimental Features")
    }
    .navigationDestination(isPresented: $showCustomization) {
      CustomizationSettingsView(
        showPaywall: $showPaywall,
        paywallSource: $paywallSource,
        scrollToNotePromptSetting: scrollToNotePromptSetting
      )
      .postHogScreenView("Customization")
      .onDisappear {
        // Reset the scroll flag when leaving
        scrollToNotePromptSetting = false
      }
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .postHogScreenView("Settings")
    .preferredColorScheme(userPreferences.preferredColorScheme)
    .onChange(of: userPreferences.preferredColorScheme) { _, _ in
      NotificationCenter.default.post(name: .didChangeColorScheme, object: nil)
    }
    .fullScreenCover(isPresented: $showOnboarding) {
      OnboardingFlowView()
    }
    .sheet(isPresented: $showPaywall) {
      StandalonePaywallView(source: paywallSource)
    }
    .sheet(isPresented: $showTrialStatus) {
      StandalonePaywallView(
        source: "trial_status",
        context: .trialStatus(daysLeft: GracePeriodManager.shared.gracePeriodDaysRemaining)
      )
    }
    .sheet(isPresented: $showLimitedTimeOffer, onDismiss: {
      ltoManager.markCurrentCampaignSeen()
    }) {
      StandalonePaywallView(source: "lto_settings", context: .limitedTimeOffer)
        .presentationDetents([.large])
    }
    .sheet(isPresented: $showTrialClaim) {
      TrialClaimPaywallView(source: "settings_claim_banner")
        .presentationDetents([.large])
    }
    .navigationDestination(isPresented: $showSubscriptions) {
      SubscriptionsView()
        .postHogScreenView("Subscriptions")
    }
    .alert(languageRestartAlertTitle, isPresented: $showLanguageRestartAlert) {
      Button(languageRestartAlertConfirmLabel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          exit(0)
        }
      }
    } message: {
      Text(languageRestartAlertMessage)
    }
    .offerCodeRedemption(isPresented: $showRedeemCode) { _ in
      Task {
        await storeKitManager.updatePurchasedProducts()
        await subscriptionManager.updateSubscriptionStatus()
      }
    }
    .onAppear {
      Task {
        await StoreKitManager.shared.updatePurchasedProducts()
        await subscriptionManager.updateSubscriptionStatus()

        // Check if app update is available
        await checkForAppUpdate()
      }
      
      // Auto-navigate to Customization if requested
      if navigateToNotePromptSetting {
        scrollToNotePromptSetting = true
        navigateToNotePromptSetting = false  // Reset flag to avoid re-navigating
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          showCustomization = true
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .subscriptionDidExpire)) { _ in
      Task {
        await subscriptionManager.updateSubscriptionStatus()
      }
    }
  }
  
  // MARK: - Beta Tester Section
  @ViewBuilder
  private var betaTesterSection: some View {
    Section {
      Button {
        openURL(URL(string: "https://apps.apple.com/sg/app/joodle-journaling-with-doodle/id6756204776")!)
      } label: {
        HStack {
          if #available(iOS 18.0, *) {
            Image(systemName: "fireworks")
              .font(.appFont(size: 14, weight: .semibold))
              .frame(width: 28, height: 28)
              .symbolRenderingMode(.palette)
              .symbolEffect(.bounce)
              .foregroundStyle(.accent, .red, .yellow)
              .background(.gray.opacity(0.1))
              .clipShape(RoundedRectangle(cornerRadius: 6))
          } else {
            // Fallback on earlier versions
            Image(systemName: "fireworks")
              .font(.appFont(size: 14, weight: .semibold))
              .frame(width: 28, height: 28)
              .symbolRenderingMode(.palette)
              .foregroundStyle(.accent, .red, .yellow)
              .background(.gray.opacity(0.1))
              .clipShape(RoundedRectangle(cornerRadius: 6))
          }
          
          Text("Download in App Store")
            .font(.appBody(weight: .medium))
            .foregroundColor(.primary)
          Spacer()
          Image(systemName: "arrow.up.right")
            .font(.appCaption())
            .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
      }
    } footer: {
      Text("Joodle is now available in App Store!")
    }
  }
  
  // MARK: - Membership Banner Section
  
  @ViewBuilder
  private var membershipBannerSection: some View {
    Section {
      // Countdown banner slot — the persistent re-entry point while a clock
      // is running. The claim window and the 50%-off offer are mutually
      // exclusive funnel phases, so at most one banner renders here.
      if case .claimWindow(let end) = trialOfferManager.phase {
        LimitedTimeOfferBanner(
          icon: "crown.fill",
          headline: String(localized: "Your 7 free days are waiting"),
          endDate: end,
          onTap: { showTrialClaim = true }
        )
      } else if ltoManager.isActive, let endDate = ltoManager.endDate {
        LimitedTimeOfferBanner(
          headline: ltoManager.headline,
          endDate: endDate,
          onTap: { showLimitedTimeOffer = true }
        )
      }

      // Membership Banner - only this should trigger paywall
      // A purchase outranks the grace period: owners who buy mid-trial see
      // their owned status, not the trial countdown.
      MembershipBannerView(
        hasPremiumAccess: subscriptionManager.hasPremiumAccess,
        isInGracePeriod: !subscriptionManager.isSubscribed && GracePeriodManager.shared.isInGracePeriod,
        gracePeriodDaysRemaining: GracePeriodManager.shared.gracePeriodDaysRemaining,
        statusMessage: subscriptionManager.subscriptionStatusMessage,
        onTap: {
          if subscriptionManager.isSubscribed {
            showSubscriptions = true
          } else if GracePeriodManager.shared.isInGracePeriod {
            showTrialStatus = true
          } else {
            showPaywall = true
          }
        }
      )
      
      // Redeem Promo Code
      Button {
        showRedeemCode = true
      } label: {
        HStack {
          SettingsIconView(systemName: "ticket.fill", backgroundColor: .orange)
          Text("Redeem Promo Code")
            .foregroundColor(.primary)
          Spacer()
          Image(systemName: "arrow.up.right")
            .font(.appCaption())
            .foregroundColor(.secondary)
        }
      }
      
      // Tutorial for TestFlight users only - how to redeem promo code
      if isNonProductionEnvironment {
        NavigationLink {
          TutorialView(
            title: TutorialDefinitions.testFlightUserRedeemPromoCode.title,
            screenshots: TutorialDefinitions.testFlightUserRedeemPromoCode.screenshots,
            description: TutorialDefinitions.testFlightUserRedeemPromoCode.description
          )
        } label: {
          HStack {
            SettingsIconView(systemName: TutorialDefinitions.testFlightUserRedeemPromoCode.icon, backgroundColor: .indigo)
            Text("How to Get Promo Code")
              .foregroundColor(.primary)
          }
        }
      }
    }
  }
  
  // MARK: - General Section
  
  @ViewBuilder
  private var generalSection: some View {
    Section {
      // iCloud Sync
      NavigationLink {
        iCloudSyncView()
      } label: {
        HStack {
          SettingsIconView(systemName: "icloud.fill", backgroundColor: .cyan)
          Text("iCloud Sync")
            .foregroundColor(.primary)
          Spacer()
          iCloudSyncStatusView
        }
      }
      
      // Daily Reminder
      NavigationLink {
        DailyReminderSettingsView()
      } label: {
        HStack {
          SettingsIconView(systemName: "bell.fill", backgroundColor: .red)
          Text("Daily Reminder")
            .foregroundColor(.primary)
          Spacer()
          if userPreferences.isDailyReminderEnabled {
            Text(userPreferences.dailyReminderTime.formatted(date: .omitted, time: .shortened))
              .font(.appSubheadline())
              .foregroundColor(.secondary)
          } else {
            Text("Off")
              .font(.appSubheadline())
              .foregroundColor(.secondary)
          }
        }
      }
      
      // Anniversary Alarms
      NavigationLink {
        AnniversaryAlarmsSettingsView()
      } label: {
        HStack {
          SettingsIconView(systemName: "alarm.fill", backgroundColor: .orange)
          Text("Anniversary Alarms")
            .foregroundColor(.primary)
          Spacer()
          if !reminderManager.reminders.isEmpty {
            Text(reminderManager.reminders.count, format: .number.grouping(.never))
              .font(.appSubheadline())
              .foregroundColor(.secondary)
          }
        }
      }
      
      // Customization
      NavigationLink {
        CustomizationSettingsView(
          showPaywall: $showPaywall,
          paywallSource: $paywallSource
        )
      } label: {
        HStack {
          SettingsIconView(systemName: "paintbrush.fill", backgroundColor: .purple)
          Text("Customization")
            .foregroundColor(.primary)
          Spacer()
        }
      }
      // Stage 1 of the Wiggly Strokes discovery. Tapping only advances into the
      // Customization screen (resolution: .none); the toggle there resolves the tip.
      .featureTip(FeatureTipDefinitions.AnchorID.wigglyCustomizationRow, resolution: .none)
      // Stage 1 of the rainbow theme discovery, sharing this same row. Advances
      // into the Customization screen; the rainbow swatch there resolves the tip.
      .featureTip(FeatureTipDefinitions.AnchorID.rainbowCustomizationRow, resolution: .none)

      // Interactions
      NavigationLink {
        InteractionsSettingsView()
      } label: {
        HStack {
          SettingsIconView(systemName: "hand.tap.fill", backgroundColor: .blue)
          Text("Interactions")
            .foregroundColor(.primary)
          Spacer()
        }
      }

      // Auto Trace. No longer Pro-gated at the switch — everyone can toggle it
      // and open the detail settings. Free users get a daily allowance and meet
      // the paywall on the camera button itself once it's spent.
      NavigationLink {
        AutoTraceSettingsView()
          // Navigating in resolves the tip. Done here rather than via a `.tap`
          // resolution because a tap gesture on the row competes with the
          // NavigationLink's own hit testing (see FeatureTipAnchorModifier),
          // leaving the row not fully tappable.
          .onAppear {
            FeatureTipManager.shared.markSeen(FeatureTipDefinitions.TipID.autoTraceSettingsRow)
          }
      } label: {
        autoTraceRowLabel
      }
      // Frame-reporting only (`.none`) — the row stays fully tappable.
      .featureTip(FeatureTipDefinitions.AnchorID.autoTraceSettingsRow, resolution: .none)

      // Backup & Restore
      NavigationLink {
        BackupRestoreSettingsView()
      } label: {
        HStack {
          SettingsIconView(systemName: "externaldrive.fill", backgroundColor: .gray)
          Text("Backup & Restore")
            .foregroundColor(.primary)
          Spacer()
        }
      }

      // Language
      HStack {
        SettingsIconView(systemName: "globe", backgroundColor: .indigo)
        Text("Language")
          .foregroundColor(.primary)
        Spacer()
        Picker(selection: $selectedLanguage) {
          ForEach(AppLanguage.allCases) { language in
            Text(language.displayName).tag(language)
          }
        } label: {
          // Hidden via .labelsHidden(); retained as the picker's VoiceOver label.
          Text("Language")
        }
        .labelsHidden()
        .onChange(of: selectedLanguage) { oldValue, newValue in
          guard oldValue != newValue else { return }
          let previousCode = userPreferences.appLanguage.isEmpty
            ? LocaleProvider.currentLanguageCode
            : userPreferences.appLanguage
          userPreferences.appLanguage = newValue.code
          AnalyticsManager.shared.trackSettingChanged(
            name: "app_language",
            value: newValue.code,
            previousValue: previousCode
          )
          showLanguageRestartAlert = true
        }
      }
      
      // Announcements
      NavigationLink {
        AnnouncementsSettingsView()
      } label: {
        HStack {
          SettingsIconView(systemName: "megaphone.fill", backgroundColor: .blue)
          Text("Announcements")
            .foregroundColor(.primary)
          Spacer()
          if !userPreferences.announcementsEnabled {
            Text("Off")
              .font(.appSubheadline())
              .foregroundColor(.secondary)
          }
        }
      }
    } header: {
      Text("General")
    }
  }

  @ViewBuilder
  private var autoTraceRowLabel: some View {
    HStack {
      SettingsIconView(systemName: "lasso.and.sparkles", backgroundColor: .pink)
      Text("Auto Trace")
        .foregroundColor(.primary)
      Spacer()
    }
  }

  @ViewBuilder
  private var iCloudSyncStatusView: some View {
    if needsRestartForSync {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .font(.appCaption())
    } else if cloudSyncManager.isSyncing {
      HStack(spacing: 6) {
        Text("Syncing")
          .font(.appCaption())
          .foregroundStyle(.secondary)
        ProgressView()
          .scaleEffect(0.6)
      }
    } else if !cloudSyncManager.canSync {
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
        .font(.appCaption())
    } else if userPreferences.isCloudSyncEnabled && CloudSyncManager.shared.isCloudAvailable {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.appCaption())
    }
  }
  
  // MARK: - Labs Section
  
  @ViewBuilder
  private var labSection: some View {
    Section {
      Button {
        showExperimentalFeatures = true
      } label: {
        HStack {
          SettingsIconView(systemName: "flask.fill", backgroundColor: .purple)
          Text("Experimental Features")
            .foregroundColor(.primary)
          Spacer()
          Image(systemName: "chevron.right")
            .font(.appCaption())
            .foregroundColor(.secondary)
        }
      }
    } header: {
      Text("Labs")
    }
  }
  
  // MARK: - External Settings Section
  
  @ViewBuilder
  private var externalSettingsSection: some View {
    Section {
      Button {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
          UIApplication.shared.open(url)
        }
      } label: {
        SettingsRowView(
          icon: "bell.badge.fill",
          iconColor: .red,
          title: "Notifications",
          isExternal: true
        )
      }
      
      Button {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      } label: {
        SettingsRowView(
          icon: "gear",
          iconColor: .gray,
          title: "App Settings",
          isExternal: true
        )
      }
    } header: {
      Text("External Settings")
    } footer: {
      Text("Manage photos permission, Siri and search, and notification appearance in the system Settings app.")
    }
  }
  
  // MARK: - Need Help Section
  
  private var contactUsMailURL: URL? {
    let email = "joodle@liyuxuan.dev"
    let subject = "Feedback on Joodle"
    let iOSVersion = UIDevice.current.systemVersion
    let body = "\n\n\n\n\nJoodle \(AppEnvironment.fullVersionDisplayString) - iOS \(iOSVersion)\nID: \(deviceIdentifier)"
    
    let subjectEncoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let bodyEncoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    
    return URL(string: "mailto:\(email)?subject=\(subjectEncoded)&body=\(bodyEncoded)")
  }

  private var translationFeedbackMailURL: URL? {
    guard selectedLanguage != .en else {
      return nil
    }

    let email = "joodle@liyuxuan.dev"
    let subject = "Translation Feedback for Joodle"
    let iOSVersion = UIDevice.current.systemVersion
    let promptLine = String(localized: "Please describe the translation issue you found.", comment: "Prompt in translation feedback email body asking users to describe the issue.")
    let languageLine = String(localized: "Language", comment: "Label in translation feedback email body indicating the language where issue was found.")
    let screenOrFeatureLine = String(localized: "Screen or feature", comment: "Label in translation feedback email body asking where the issue appears.")
    let currentTranslationLine = String(localized: "Current translation", comment: "Label in translation feedback email body asking what text is currently shown.")
    let suggestedCorrectionLine = String(localized: "Suggested correction", comment: "Label in translation feedback email body asking for suggested corrected text.")
    let additionalContextLine = String(localized: "Additional context", comment: "Label in translation feedback email body asking for any extra details.")
    let body = """
\(promptLine)

\(languageLine): \(selectedLanguage.displayName) (\(selectedLanguage.code))
\(screenOrFeatureLine):
\(currentTranslationLine):
\(suggestedCorrectionLine):
\(additionalContextLine):

Joodle \(AppEnvironment.fullVersionDisplayString) - iOS \(iOSVersion)
ID: \(deviceIdentifier)
"""

    let subjectEncoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let bodyEncoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

    return URL(string: "mailto:\(email)?subject=\(subjectEncoded)&body=\(bodyEncoded)")
  }
  
  @ViewBuilder
  private var needHelpSection: some View {
    Section {
      NavigationLink {
        ChangelogListView()
      } label: {
        SettingsRowView(
          icon: "sparkles",
          iconColor: .indigo,
          title: "What's New",
          trailingView: isAppUpdateAvailable ? AnyView(
            Text("UPDATE")
              .font(.appFont(size: 10, weight: .bold))
              .fontWeight(.semibold)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(
                LinearGradient(
                  colors: [.appAccent, .appAccent.opacity(0.7)],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                )
              )
              .foregroundStyle(.appAccentContrast)
              .clipShape(Capsule())
          ) : nil
        )
      }
      
      NavigationLink {
        LearnCoreFeaturesView()
      } label: {
        SettingsRowView(
          icon: "book.fill",
          iconColor: .indigo,
          title: "Learn Core Features"
        )
      }
      
      NavigationLink {
        FaqView()
      } label: {
        SettingsRowView(
          icon: "questionmark.circle.fill",
          iconColor: .indigo,
          title: "Frequently Asked Questions"
        )
      }
      
      if let mailURL = contactUsMailURL {
        Button {
          openURL(mailURL)
        } label: {
          SettingsRowView(
            icon: "envelope.fill",
            iconColor: .indigo,
            title: "Contact Us",
            isExternal: true
          )
        }
      }
    } header: {
      Text("Need Help?")
    }
  }
  
  // MARK: - Get Involved Section
  
  /// Returns true if the app is running in a production App Store environment
  private var isProductionEnvironment: Bool {
    AppEnvironment.isAppStore
  }
  
  @ViewBuilder
  private var getInvolvedSection: some View {
    Section {
      Button {
        AnalyticsManager.shared.trackExternalLinkOpened(url: "x.com/xmliszt", type: "social")
        openURL(URL(string: "https://x.com/xmliszt")!)
      } label: {
        HStack {
          Image("Social/twitter")
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6))
          Text("Follow on X")
            .foregroundColor(.primary)
          Spacer()
          Image(systemName: "arrow.up.right")
            .font(.appCaption())
            .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
      }

      Button {
        AnalyticsManager.shared.trackExternalLinkOpened(url: "liyuxuan.dev/apps/joodle", type: "website")
        openURL(URL(string: "https://liyuxuan.dev/apps/joodle")!)
      } label: {
        SettingsRowView(
          icon: "globe.americas.fill",
          iconColor: .pink,
          title: "Visit Developer Website",
          isExternal: true
        )
      }
      
      Button {
        AnalyticsManager.shared.trackExternalLinkOpened(url: "feedback", type: "feedback")
        openFeedback()
      } label: {
        SettingsRowView(
          icon: AppEnvironment.feedbackButtonIcon,
          iconColor: .pink,
          title: AppEnvironment.feedbackButtonTitle,
          isExternal: true
        )
      }
      
      if isProductionEnvironment {
        Button {
          AnalyticsManager.shared.trackExternalLinkOpened(url: "joodle-feedback", type: "feedback")
          openURL(URL(string: "https://tinyurl.com/joodle-feedback")!)
        } label: {
          SettingsRowView(
            icon: "bubble.left.and.bubble.right.fill",
            iconColor: .pink,
            title: "Feature Request",
            isExternal: true
          )
        }
      }

      if let mailURL = translationFeedbackMailURL {
        Button {
          AnalyticsManager.shared.trackExternalLinkOpened(url: "translation_feedback", type: "feedback")
          openURL(mailURL)
        } label: {
          SettingsRowView(
            icon: "character.bubble.fill",
            iconColor: .pink,
            title: "Spot A Translation Error?",
            isExternal: true
          )
        }
      }

      
      Button {
        AnalyticsManager.shared.trackExternalLinkOpened(url: "share_sheet", type: "recommend")
        showShareSheet = true
      } label: {
        SettingsRowView(
          icon: "heart.fill",
          iconColor: .pink,
          title: "Recommend Joodle",
          trailingView: AnyView(
            Image(systemName: "square.and.arrow.up")
              .font(.appCaption())
              .foregroundColor(.secondary)
          )
        )
      }
      .sheet(isPresented: $showShareSheet) {
        let shareText = "Hey! I've found a gem journaling app that allows you to draw your days! Joodle, that's what it's called, is made for people like you and I. Check it out here:"
        let shareURL = URL(string: "https://apps.apple.com/sg/app/joodle-journaling-with-doodle/id6756204776")!
        ShareSheet(items: [shareText, shareURL])
      }
    } header: {
      Text("Get Involved")
    }
  }
  
  // MARK: - Legal Section
  
  @ViewBuilder
  private var legalSection: some View {
    Section {
      Button {
        AnalyticsManager.shared.trackExternalLinkOpened(url: "privacy-policy", type: "legal")
        openURL(URL(string: "https://liyuxuan.dev/apps/joodle/privacy-policy")!)
      } label: {
        SettingsRowView(
          icon: "hand.raised.fill",
          iconColor: .gray,
          title: "Privacy Policy",
          isExternal: true
        )
      }

      Button {
        AnalyticsManager.shared.trackExternalLinkOpened(url: "terms-of-service", type: "legal")
        openURL(URL(string: "https://liyuxuan.dev/apps/joodle/terms-of-service")!)
      } label: {
        SettingsRowView(
          icon: "doc.text.fill",
          iconColor: .gray,
          title: "Terms of Service",
          isExternal: true
        )
      }
    } header: {
      Text("Legal")
    }
  }
  
  // MARK: - Footer Section
  
  private var currentYear: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy"
    return formatter.string(from: Date())
  }
  
  private var deviceIdentifier: String {
    let vendorId = UIDevice.current.identifierForVendor?.uuidString ?? "Unknown"
    let appId = Bundle.main.bundleIdentifier ?? "Unknown"
    return "\(vendorId):\(appId)"
  }
  
  @ViewBuilder
  private var footerSection: some View {
    Section {
      EmptyView()
    } footer: {
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          Image("LaunchIcon")
            .resizable()
            .scaledToFit()
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 8))
          Text("Joodle")
            .font(.appTitle2())
            .fontWeight(.semibold)
          + Text("®")
            .font(.appCaption())
            .fontWeight(.semibold)
            .baselineOffset(10)
        }
        
        Text("VERSION \(AppEnvironment.fullVersionDisplayString)")
          .font(.appCaption())
          .foregroundStyle(.secondary)
        
        Text("© \(currentYear) Li Yuxuan. All Rights Reserved.")
          .font(.appCaption2())
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 16)
      .onLongPressGesture {
        showDeviceIdentifierAlert = true
      }
    }
    .alert("Share identifier with joodle@liyuxuan.dev to help debug purchase issues:", isPresented: $showDeviceIdentifierAlert) {
      Button("Copy to Clipboard") {
        UIPasteboard.general.string = deviceIdentifier
      }
      Button("Cancel", role: .cancel) { }
    } message: {
      Text(deviceIdentifier)
    }
  }
  
  // MARK: - Developer Options Section
  
  /// Returns true if the app is running in a non-production environment
  private var isNonProductionEnvironment: Bool {
    !AppEnvironment.isAppStore
  }
  
  /// Returns true if we're simulating production
  private var isSimulatingProduction: Bool {
    AppEnvironment.isSimulatingProduction
  }
  
  @ViewBuilder
  private var developerOptionsSection: some View {
    if (AppEnvironment.isDebug || isNonProductionEnvironment) && !simulateProductionEnvironment {
      Section {
        NavigationLink {
          DeveloperOptionsView(simulateProductionEnvironment: $simulateProductionEnvironment)
        } label: {
          HStack {
            SettingsIconView(systemName: "hammer.fill", backgroundColor: .gray)
            Text(verbatim: "Developer")
              .foregroundColor(.primary)
            Spacer()
            Text(verbatim: AppEnvironment.isDebug ? "Debug" : "TestFlight")
              .font(.appSubheadline())
              .foregroundColor(.secondary)
          }
        }
      }
    }

    if isSimulatingProduction {
      Section {
        Button("Exit Production Simulation") {
          AppEnvironment.simulateProductionEnvironment = false
          simulateProductionEnvironment = false
        }
        .foregroundColor(.orange)
      } footer: {
        Text("You are currently simulating production environment. Tap to return to development mode.")
      }
    }
  }
  
  // MARK: - Helper Methods
  
  /// Check if a newer app version is available based on changelog
  private func checkForAppUpdate() async {
    do {
      let index = try await RemoteChangelogService.shared.fetchChangelogIndex()
      if let latestVersion = index.first?.version {
        let currentVersion = AppEnvironment.fullVersionString
        isAppUpdateAvailable = VersionComparator.isOlderRelease(currentVersion, latestVersion)
      }
    } catch {
      // Silently fail - don't show update badge if we can't fetch
      print("Failed to check for app update: \(error)")
    }
  }
  
  private func openFeedback() {
    guard let url = AppEnvironment.feedbackURL else { return }
    
    if UIApplication.shared.canOpenURL(url) {
      UIApplication.shared.open(url)
    } else {
      if let appStoreURL = AppEnvironment.appStoreReviewURL {
        UIApplication.shared.open(appStoreURL)
      }
    }
  }
  
}

// MARK: - Daily Reminder Settings View

struct DailyReminderSettingsView: View {
  @Environment(\.userPreferences) private var userPreferences
  @StateObject private var reminderManager = ReminderManager.shared
  @State private var showNotificationDeniedAlert = false
  
  private var dailyReminderTimeBinding: Binding<Date> {
    Binding(
      get: { userPreferences.dailyReminderTime },
      set: { newTime in
        userPreferences.dailyReminderTime = newTime
        reminderManager.updateDailyReminderTime(newTime)
      }
    )
  }
  
  var body: some View {
    Form {
      Section {
        Toggle(isOn: Binding(
          get: { userPreferences.isDailyReminderEnabled },
          set: { newValue in
            if newValue {
              Task {
                let success = await reminderManager.enableDailyReminder(at: userPreferences.dailyReminderTime)
                await MainActor.run {
                  if success {
                    userPreferences.isDailyReminderEnabled = true
                  } else {
                    showNotificationDeniedAlert = true
                  }
                }
              }
            } else {
              userPreferences.isDailyReminderEnabled = false
              reminderManager.disableDailyReminder()
            }
          }
        )) {
          HStack {
            SettingsIconView(systemName: "bell.fill", backgroundColor: .red)
            Text("Enable Daily Reminder")
          }
        }
        
        if userPreferences.isDailyReminderEnabled {
          HStack {
            SettingsIconView(systemName: "clock.fill", backgroundColor: .red)
            Text("Reminder Time")
            Spacer()
            DatePicker(
              "Reminder Time",
              selection: dailyReminderTimeBinding,
              displayedComponents: .hourAndMinute
            )
            .labelsHidden()
          }
        }
      } footer: {
        Text("Get a daily notification to remind you to capture your moment in Joodle.")
      }
    }
    .navigationTitle("Daily Reminder")
    .navigationBarTitleDisplayMode(.inline)
    .postHogScreenView("Daily Reminder Settings")
    .alert("Notifications Disabled", isPresented: $showNotificationDeniedAlert) {
      Button("Open Settings") {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
          UIApplication.shared.open(url)
        }
      }
      Button("Cancel", role: .cancel) { }
    } message: {
      Text("Please enable notifications in Settings to receive daily reminders.")
    }
  }
}

// MARK: - Customization Settings View

struct CustomizationSettingsView: View {
  @Environment(\.userPreferences) private var userPreferences
  @StateObject private var subscriptionManager = SubscriptionManager.shared
  @Binding var showPaywall: Bool
  @Binding var paywallSource: String
  
  /// When true, scrolls to the "Prompt for notes after doodling" toggle on appear
  var scrollToNotePromptSetting: Bool = false

  // Shown when the user enables "Save photos to album" but Photos add-only
  // access is denied/restricted (iOS won't re-prompt — point them to Settings).
  @State private var showPhotoAccessDeniedAlert = false

  init(showPaywall: Binding<Bool>, paywallSource: Binding<String>, scrollToNotePromptSetting: Bool = false) {
    self._showPaywall = showPaywall
    self._paywallSource = paywallSource
    self.scrollToNotePromptSetting = scrollToNotePromptSetting
  }
  
  private var viewModeBinding: Binding<ViewMode> {
    Binding(
      get: { userPreferences.defaultViewMode },
      set: { newValue in
        let previousValue = userPreferences.defaultViewMode
        userPreferences.defaultViewMode = newValue
        if newValue != previousValue {
          AnalyticsManager.shared.trackSettingChanged(name: "default_view_mode", value: newValue.rawValue, previousValue: previousValue.rawValue)
        }
      }
    )
  }
  
  private var startOfWeekBinding: Binding<String> {
    Binding(
      get: { userPreferences.startOfWeek },
      set: { newValue in
        let previousValue = userPreferences.startOfWeek
        userPreferences.startOfWeek = newValue
        WidgetHelper.shared.updateStartOfWeek()
        if newValue != previousValue {
          AnalyticsManager.shared.trackSettingChanged(name: "start_of_week", value: newValue, previousValue: previousValue)
        }
      }
    )
  }
  
  private var colorSchemeBinding: Binding<ColorScheme?> {
    Binding(
      get: { userPreferences.preferredColorScheme },
      set: { newValue in
        userPreferences.preferredColorScheme = newValue
        NotificationCenter.default.post(name: .didChangeColorScheme, object: nil)
      }
    )
  }
  
  private var saveCapturedPhotoToAlbumBinding: Binding<Bool> {
    Binding(
      get: { userPreferences.saveCapturedPhotoToAlbum },
      set: { newValue in
        // Turning OFF never needs permission — it's a deliberate "don't save".
        guard newValue else {
          commitSaveCapturedPhotoToAlbum(false)
          return
        }

        // Turning ON requires Photos add-only access. The toggle's final state
        // must reflect the *actual* permission outcome — otherwise it sticks ON
        // when access is denied and saving would silently fail.
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
          commitSaveCapturedPhotoToAlbum(true)
        case .notDetermined:
          // Reflect ON immediately so the switch animates, then revert if the
          // user denies the system prompt.
          commitSaveCapturedPhotoToAlbum(true)
          PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
              let granted = status == .authorized || status == .limited
              if !granted {
                commitSaveCapturedPhotoToAlbum(false)
              }
            }
          }
        case .denied, .restricted:
          // iOS won't show the prompt again — keep the toggle OFF and direct the
          // user to Settings to grant access.
          commitSaveCapturedPhotoToAlbum(false)
          showPhotoAccessDeniedAlert = true
        @unknown default:
          commitSaveCapturedPhotoToAlbum(false)
        }
      }
    )
  }

  /// Commits the "save photos to album" preference and tracks the change only
  /// when the value actually flips. Safe to call from the permission
  /// completion handler (revert on denial).
  private func commitSaveCapturedPhotoToAlbum(_ value: Bool) {
    let previousValue = userPreferences.saveCapturedPhotoToAlbum
    guard value != previousValue else { return }
    userPreferences.saveCapturedPhotoToAlbum = value
    AnalyticsManager.shared.trackSettingChanged(
      name: "save_captured_photo_to_album",
      value: value,
      previousValue: previousValue
    )
  }

  private var shareCardWatermarkBinding: Binding<Bool> {
    Binding(
      get: { userPreferences.shareCardWatermarkEnabled },
      set: { newValue in
        let previousValue = userPreferences.shareCardWatermarkEnabled
        
        // For free users, show paywall when they try to disable it
        if !subscriptionManager.hasPremiumAccess && !newValue {
          userPreferences.shareCardWatermarkEnabled = true // Revert to ON
          paywallSource = "watermark_toggle"
          showPaywall = true // Show paywall sheet
          return
        }
        
        userPreferences.shareCardWatermarkEnabled = newValue
        if newValue != previousValue {
          AnalyticsManager.shared.trackSettingChanged(
            name: "share_card_watermark_enabled",
            value: newValue,
            previousValue: previousValue
          )
        }
      }
    )
  }

  private var wigglyStrokesBinding: Binding<Bool> {
    Binding(
      // Reflect the *effective* state: wiggle only applies for Joodle Pro, so
      // free users always see the toggle off (with a Pro badge) even if the
      // preference was switched on while it was a free experimental feature.
      get: { userPreferences.enableWigglyStrokes && subscriptionManager.hasPremiumAccess },
      set: { newValue in
        // Joodle Pro feature — free users get the paywall instead of toggling on.
        guard subscriptionManager.hasPremiumAccess else {
          paywallSource = "wiggly_strokes_toggle"
          showPaywall = true
          return
        }

        let previousValue = userPreferences.enableWigglyStrokes
        userPreferences.enableWigglyStrokes = newValue
        if newValue != previousValue {
          AnalyticsManager.shared.trackSettingChanged(
            name: "wiggly_strokes",
            value: newValue,
            previousValue: previousValue
          )
        }
      }
    )
  }

  var body: some View {
    ScrollViewReader { scrollProxy in
      Form {
        // Default View Mode Section
        Section {
          VStack(spacing: 0) {
            ZStack {
              Image("Others/MinimizedView")
                .resizable()
                .scaledToFit()
                .offset(y: userPreferences.defaultViewMode == .now ? 300 : 10)
              
              Image("Others/NormalView")
                .resizable()
                .scaledToFit()
                .offset(y: userPreferences.defaultViewMode == .now ? 10 : 300)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: userPreferences.defaultViewMode)
            
            if #available(iOS 26.0, *) {
              Picker("View Mode", selection: viewModeBinding) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                  Text(mode.displayName).tag(mode)
                }
              }
              .pickerStyle(.palette)
              .glassEffect(.regular.interactive())
            } else {
              Picker("View Mode", selection: viewModeBinding) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                  Text(mode.displayName).tag(mode)
                }
              }
              .pickerStyle(.palette)
            }
            
            VStack {
              if userPreferences.defaultViewMode == .now {
                Text("\"Normal\" view mode gives you a more focused view with 7 days per row representing the 7 days of a week. Layout is shifted to match the weekday.")
                  .font(.appCaption())
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
              } else if userPreferences.defaultViewMode == .year {
                Text("\"Minimized\" view mode gives you an overview of your entire year. Additional sharing is available in this view mode to share your entire year.")
                  .font(.appCaption())
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }.padding(.top, 12)
          }
        } header: {
          Text("Default View Mode")
        }
        
        // Start of Week Section
        Section {
          VStack(spacing: 12) {
            if #available(iOS 26.0, *) {
              Picker("Start of Week", selection: startOfWeekBinding) {
                Text("Sunday").tag("sunday")
                Text("Monday").tag("monday")
              }
              .pickerStyle(.palette)
              .glassEffect(.regular.interactive())
            } else {
              Picker("Start of Week", selection: startOfWeekBinding) {
                Text("Sunday").tag("sunday")
                Text("Monday").tag("monday")
              }
              .pickerStyle(.palette)
            }
            
            Text("Start of Week affects the layout in \"Normal\" view mode.")
              .font(.appCaption())
              .foregroundColor(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } header: {
          Text("Start of Week")
        }
        
        // Color Scheme Section
        Section {
          if #available(iOS 26.0, *) {
            Picker("Color Scheme", selection: colorSchemeBinding) {
              Text("System").tag(nil as ColorScheme?)
              Text("Light").tag(ColorScheme.light as ColorScheme?)
              Text("Dark").tag(ColorScheme.dark as ColorScheme?)
            }
            .pickerStyle(.palette)
            .glassEffect(.regular.interactive())
          } else {
            Picker("Color Scheme", selection: colorSchemeBinding) {
              Text("System").tag(nil as ColorScheme?)
              Text("Light").tag(ColorScheme.light as ColorScheme?)
              Text("Dark").tag(ColorScheme.dark as ColorScheme?)
            }
            .pickerStyle(.palette)
          }
        } header: {
          Text("Appearance")
        }
        
        // Theme Color Section
        Section {
          ThemeColorPaletteView(
            subscriptionManager: subscriptionManager,
            onLockedColorTapped: {
              paywallSource = "locked_color"
              showPaywall = true
            }
          )
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
          Text("Theme Color")
        }

        // Wiggly Strokes Section (Joodle Pro)
        Section {
          VStack(spacing: 24) {
            // Live demo of the boiling-line effect — always wiggling so it
            // showcases the feature even while the toggle is off.
            WigglyStrokePreview()
              .frame(height: 220)
              .frame(maxWidth: .infinity)
              .background(.black)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Toggle(isOn: wigglyStrokesBinding) {
              HStack(spacing: 6) {
                Text("Wiggly Strokes")
                if !subscriptionManager.hasPremiumAccess {
                  PremiumFeatureBadge()
                }
              }
            }
            .tint(.appAccent)
            // Stage 2 of the Wiggly Strokes discovery — touching the toggle
            // resolves the whole feature tip.
            .featureTip(FeatureTipDefinitions.AnchorID.wigglyToggle)
          }
        } header: {
          Text("Wiggly Strokes")
        } footer: {
          Text("Makes your doodles come alive with a shaky wiggle that never sits still.")
        }

        // Prompt for notes after doodling - no header
        Section {
          Toggle(isOn: Binding(
            get: { userPreferences.promptForNotesAfterDoodling },
            set: { newValue in
              let previousValue = userPreferences.promptForNotesAfterDoodling
              userPreferences.promptForNotesAfterDoodling = newValue
              if newValue != previousValue {
                AnalyticsManager.shared.trackSettingChanged(
                  name: "prompt_for_notes_after_doodling",
                  value: newValue,
                  previousValue: previousValue
                )
              }
            }
          )) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Prompt for notes after doodling")
              Text("Show a popup to add notes after doodling")
                .font(.appCaption())
                .foregroundStyle(.secondary)
            }
          }
          .tint(.appAccent)
          .id("notePromptSetting")
          
          Toggle(isOn: shareCardWatermarkBinding) {
            HStack(spacing: 8) {
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                  Text("Watermark when sharing")
                  if !subscriptionManager.hasPremiumAccess {
                    PremiumFeatureBadge()
                  }
                }
                Text("Add a watermark on share cards")
                  .font(.appCaption())
                  .foregroundStyle(.secondary)
              }
              Spacer()
            }
          }
          .tint(.appAccent)
          .id("watermarkSharingToggle")

          Toggle(isOn: saveCapturedPhotoToAlbumBinding) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Save photos to album")
              Text("Save reference photos you capture for tracing to your Photos album")
                .font(.appCaption())
                .foregroundStyle(.secondary)
            }
          }
          .tint(.appAccent)
          .alert("Photos Access Needed", isPresented: $showPhotoAccessDeniedAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Open Settings") {
              if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
              }
            }
          } message: {
            Text("Joodle needs permission to add photos to your library. Enable Photos access in Settings to save captured reference photos.")
          }
        }
      }
      .onAppear {
        if scrollToNotePromptSetting {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation {
              scrollProxy.scrollTo("notePromptSetting", anchor: .center)
            }
          }
        }
      }
    }
    .navigationTitle("Customization")
    .navigationBarTitleDisplayMode(.inline)
    .postHogScreenView("Customization Settings")
    .preferredColorScheme(userPreferences.preferredColorScheme)
    // Scope for stage 2 of the Wiggly Strokes feature tip.
    .featureTipScope(FeatureTipDefinitions.ScopeID.customization)
  }
}

// MARK: - Wiggly Stroke Preview

/// A small self-contained demo of the boiling-line effect, used in the
/// Customization screen so the Wiggly Strokes toggle has something to show.
private struct WigglyStrokePreview: View {
  /// The onboarding mushroom doodle, decoded from `PLACEHOLDER_DATA` polylines in `CANVAS_SIZE` space.
  private static let sample: [PathData] = {
    (try? JSONDecoder().decode([PathData].self, from: PLACEHOLDER_DATA)) ?? []
  }()

  /// Stable anchor for the boil's periodic clock.
  @State private var epoch = Date()

  /// The preview backdrop is always black, so pin the stroke to the dark-mode
  /// accent variant regardless of the system appearance.
  private static var darkAccent: Color {
    Color(UIColor(.appAccent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
  }

  var body: some View {
    // Always boil — the preview demonstrates the effect regardless of the toggle.
    TimelineView(.periodic(from: epoch, by: WigglyStroke.boilInterval)) { timeline in
      canvas(frame: WigglyStroke.frameIndex(at: timeline.date.timeIntervalSinceReferenceDate))
    }
  }

  /// Draws the sample doodle, jittered for the given boil `frame`.
  private func canvas(frame: Int) -> some View {
    Canvas { context, size in
      let scale = min(size.width, size.height) / CANVAS_SIZE
      context.translateBy(x: (size.width - CANVAS_SIZE * scale) / 2, y: (size.height - CANVAS_SIZE * scale) / 2)
      context.scaleBy(x: scale, y: scale)

      for stroke in Self.sample {
        let path = WigglyStroke.path(points: stroke.points, isDot: stroke.isDot, frame: frame)
        if stroke.isDot {
          context.fill(path, with: .color(Self.darkAccent))
        } else {
          context.stroke(
            path,
            with: .color(Self.darkAccent),
            style: StrokeStyle(lineWidth: DRAWING_LINE_WIDTH, lineCap: .round, lineJoin: .round)
          )
        }
      }
    }
  }
}

// MARK: - Interactions Settings View

// MARK: - Anniversary Alarms Settings View

struct AnniversaryAlarmsSettingsView: View {
  @StateObject private var reminderManager = ReminderManager.shared
  @State private var selectedReminders = Set<String>()
  @State private var showPastTimeAlert = false
  
  /// Sorted reminders by date (ascending)
  private var sortedReminders: [Reminder] {
    reminderManager.reminders.sorted { lhs, rhs in
      // First compare by dateString (which is in yyyy-MM-dd format, so lexicographic order works)
      if lhs.dateString != rhs.dateString {
        return lhs.dateString < rhs.dateString
      }
      // If same date, compare by reminder time
      return lhs.reminderDate < rhs.reminderDate
    }
  }
  
  var body: some View {
    List(selection: $selectedReminders) {
      if sortedReminders.isEmpty {
        Section {
          VStack(spacing: 12) {
            Image(systemName: "alarm")
              .font(.appFont(size: 40))
              .foregroundStyle(.secondary)
            Text("No Anniversary Alarms")
              .font(.appHeadline())
              .foregroundStyle(.secondary)
            Text("Set alarms for future Joodle entries to get notified on special dates.")
              .font(.appSubheadline())
              .foregroundStyle(.tertiary)
              .multilineTextAlignment(.center)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 40)
        }
      } else {
        Section {
          ForEach(sortedReminders) { reminder in
            AnniversaryAlarmRow(
              reminder: reminder,
              onTimeChange: { newTime in
                updateReminderTime(reminder: reminder, newTime: newTime)
              },
              onPastTimeError: {
                showPastTimeAlert = true
              }
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button(role: .destructive) {
                reminderManager.removeReminder(for: reminder.dateString)
              } label: {
                Image(systemName: "trash")
              }
              .tint(.red)
            }
          }
        } footer: {
          Text("Swipe left to delete, or tap Edit to select multiple alarms.")
        }
      }
    }
    .navigationTitle("Anniversary Alarms")
    .navigationBarTitleDisplayMode(.inline)
    .postHogScreenView("Anniversary Alarms Settings")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if !sortedReminders.isEmpty {
          EditButton()
        }
      }
      
      ToolbarItem(placement: .bottomBar) {
        if !selectedReminders.isEmpty {
          Button(role: .destructive) {
            deleteSelectedReminders()
          } label: {
            Text("Delete Selected (\(selectedReminders.count, format: .number.grouping(.never)))")
              .foregroundStyle(.red)
          }
        }
      }
    }
    .alert("Invalid Alarm Time", isPresented: $showPastTimeAlert) {
      Button("OK", role: .cancel) { }
    } message: {
      Text("The selected time has already passed. Please choose a future time for your anniversary alarm.")
    }
  }
  
  private func deleteSelectedReminders() {
    for dateString in selectedReminders {
      reminderManager.removeReminder(for: dateString)
    }
    selectedReminders.removeAll()
  }
  
  private func updateReminderTime(reminder: Reminder, newTime: Date) {
    Task {
      await reminderManager.addReminder(
        for: reminder.dateString,
        at: newTime,
        entryBody: reminder.entryBody
      )
    }
  }
}

// MARK: - Anniversary Alarm Row

struct AnniversaryAlarmRow: View {
  let reminder: Reminder
  let onTimeChange: (Date) -> Void
  let onPastTimeError: () -> Void
  
  @State private var selectedTime: Date
  
  init(reminder: Reminder, onTimeChange: @escaping (Date) -> Void, onPastTimeError: @escaping () -> Void) {
    self.reminder = reminder
    self.onTimeChange = onTimeChange
    self.onPastTimeError = onPastTimeError
    self._selectedTime = State(initialValue: reminder.reminderDate)
  }
  
  private var displayDate: String {
    CalendarDate(dateString: reminder.dateString)?.displayString ?? reminder.dateString
  }
  
  /// Combines the entry date with the selected time
  private func combinedReminderDate(from time: Date) -> Date {
    guard let entryDate = DayEntry.stringToLocalDate(reminder.dateString) else {
      return time
    }
    
    let timeComponents = Calendar.current.dateComponents([.hour, .minute], from: time)
    var dateComponents = Calendar.current.dateComponents([.year, .month, .day], from: entryDate)
    dateComponents.hour = timeComponents.hour
    dateComponents.minute = timeComponents.minute
    
    return Calendar.current.date(from: dateComponents) ?? time
  }
  
  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(displayDate)
          .font(.appBody())
          .foregroundStyle(.primary)
        
        if let entryBody = reminder.entryBody, !entryBody.isEmpty {
          Text(entryBody)
            .font(.appCaption())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      
      Spacer()
      
      DatePicker(
        "Alarm Time",
        selection: $selectedTime,
        displayedComponents: .hourAndMinute
      )
      .labelsHidden()
      .onChange(of: selectedTime) { _, newTime in
        let combined = combinedReminderDate(from: newTime)
        if combined <= Date() {
          // Reset to previous time and show error
          selectedTime = reminder.reminderDate
          onPastTimeError()
        } else {
          onTimeChange(combined)
        }
      }
    }
  }
}

struct InteractionsSettingsView: View {
  @Environment(\.userPreferences) private var userPreferences

  private var hapticBinding: Binding<Bool> {
    Binding(
      get: { userPreferences.enableHaptic },
      set: { userPreferences.enableHaptic = $0 }
    )
  }

  private var handednessBinding: Binding<SliderHandedness> {
    Binding(
      get: { userPreferences.cameraZoomSliderHandedness },
      set: { newValue in
        guard newValue != userPreferences.cameraZoomSliderHandedness else { return }
        Haptic.play(with: .light)
        // A non-overshooting curve so the preview slides flush to the edge
        // instead of overshooting and flashing a gap before it morphs back in.
        withAnimation(.smooth(duration: 0.4)) {
          userPreferences.cameraZoomSliderHandedness = newValue
        }
      }
    )
  }

  private var sliderEdge: HorizontalEdge {
    userPreferences.cameraZoomSliderHandedness == .right ? .trailing : .leading
  }

  var body: some View {
    Form {
      Section {
        // Interactive preview: drag to feel the ruler, and watch it slide to the
        // other edge when the handedness changes. A fixed black backdrop lets the
        // always-black slider blend in instead of standing out on a light row.
        HandednessSliderPreview(edge: sliderEdge)
          .frame(height: 300)
          .frame(maxWidth: .infinity)
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.black)

        if #available(iOS 26.0, *) {
          Picker("Camera Zoom Slider", selection: handednessBinding) {
            ForEach(SliderHandedness.allCases, id: \.self) { handedness in
              Text(handedness.displayName).tag(handedness)
            }
          }
          .pickerStyle(.palette)
          .glassEffect(.regular.interactive())
        } else {
          Picker("Camera Zoom Slider", selection: handednessBinding) {
            ForEach(SliderHandedness.allCases, id: \.self) { handedness in
              Text(handedness.displayName).tag(handedness)
            }
          }
          .pickerStyle(.palette)
        }
      } header: {
        Text("Camera Zoom Slider")
      } footer: {
        Text("Choose which side the camera zoom slider appears on.")
      }
      
      if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
        Section {
          Toggle(isOn: hapticBinding) {
            HStack {
              SettingsIconView(systemName: "hand.tap.fill", backgroundColor: .blue)
              Text("Haptic Feedback")
            }
          }
        } footer: {
          Text("Haptic feedback also depends on your device's vibration setting in Settings > Accessibility > Touch > Vibration.")
        }
      }
    }
    .navigationTitle("Interactions")
    .navigationBarTitleDisplayMode(.inline)
    .postHogScreenView("Interactions Settings")
  }
}

// MARK: - Backup & Restore Settings View

struct BackupRestoreSettingsView: View {
  @Environment(\.modelContext) private var modelContext
  @State private var showICloudSaveAlert = false
  @State private var iCloudSaveMessage = ""
  @AppStorage(BackupScheduler.autoBackupEnabledKey) private var autoBackupEnabled = true
  @AppStorage(BackupScheduler.lastAutoBackupAtKey) private var lastAutoBackupAt: Double = 0
  @State private var iCloudAvailable = true

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $autoBackupEnabled) {
          HStack {
            SettingsIconView(systemName: "clock.arrow.circlepath", backgroundColor: .green)
            VStack(alignment: .leading, spacing: 2) {
              Text("Automatic iCloud Backup")
                .foregroundColor(.primary)
              if autoBackupEnabled {
                Text(Self.autoBackupSubtitle(lastBackupAt: lastAutoBackupAt))
                  .font(.appCaption())
                  .foregroundColor(.secondary)
              }
            }
          }
        }
        .disabled(!iCloudAvailable)
        .onChange(of: autoBackupEnabled) { _, newValue in
          if newValue {
            BackupScheduler.shared.schedulePeriodicBackup()
          } else {
            BackupScheduler.shared.cancelScheduledBackup()
          }
        }

        if !iCloudAvailable {
          HStack(alignment: .top, spacing: 12) {
            SettingsIconView(systemName: "exclamationmark.triangle.fill", backgroundColor: .orange)
            VStack(alignment: .leading, spacing: 2) {
              Text("iCloud Drive is not available for Joodle")
                .foregroundColor(.primary)
              Text("Make sure you're signed in to iCloud, then turn Joodle on under Settings → [Your Name] → iCloud → Saved to iCloud → Drive → Apps Syncing to iCloud Drive.")
                .font(.appCaption())
                .foregroundColor(.secondary)
            }
          }
        }
      } footer: {
        Text("Joodle will back up your entries about once a day.")
      }

      Section {
        Button(action: { saveToICloudDrive() }) {
          HStack {
            SettingsIconView(systemName: "icloud.and.arrow.up.fill", backgroundColor: .blue)
            Text("Save Backup to iCloud Drive Now")
              .foregroundColor(.primary)
            Spacer()
            Image(systemName: "chevron.right")
              .font(.appCaption())
              .foregroundColor(.secondary)
          }
          .opacity(iCloudAvailable ? 1.0 : 0.4)
        }
        .disabled(!iCloudAvailable)

        NavigationLink {
          ICloudBackupListView()
        } label: {
          HStack {
            SettingsIconView(systemName: "list.bullet.rectangle", backgroundColor: .blue)
            Text("Manage iCloud Backups")
              .foregroundColor(.primary)
          }
          .opacity(iCloudAvailable ? 1.0 : 0.4)
        }
        .disabled(!iCloudAvailable)
      }
    }
    .navigationTitle("Backup & Restore")
    .navigationBarTitleDisplayMode(.inline)
    .postHogScreenView("Backup & Restore Settings")
    .onAppear { refreshICloudAvailability() }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
      refreshICloudAvailability()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSUbiquityIdentityDidChange)) { _ in
      refreshICloudAvailability()
    }
    .alert("iCloud Backup", isPresented: $showICloudSaveAlert) {
      Button("OK", role: .cancel) { }
    } message: {
      Text(iCloudSaveMessage)
    }
  }
  
  private func refreshICloudAvailability() {
    let containerID = BackupManager.ubiquityContainerIdentifier
    Task.detached(priority: .utility) {
      let fm = FileManager.default
      let available = fm.ubiquityIdentityToken != nil
        && fm.url(forUbiquityContainerIdentifier: containerID) != nil
      await MainActor.run {
        iCloudAvailable = available
      }
    }
  }

  private static func relativeBackupDate(from timeInterval: Double) -> String {
    let date = Date(timeIntervalSince1970: timeInterval)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  /// Subtitle for the automatic backup row.
  /// - For the first hour after a backup, shows how long ago the last backup ran.
  /// - After that, shows the remaining duration until the next scheduled backup.
  private static func autoBackupSubtitle(lastBackupAt: Double) -> String {
    guard lastBackupAt > 0 else {
      return String(localized: "No backup yet", comment: "Subtitle on Automatic iCloud Backup row when no backup has run yet.")
    }
    let now = Date()
    let lastDate = Date(timeIntervalSince1970: lastBackupAt)
    let elapsed = now.timeIntervalSince(lastDate)
    let oneHour: TimeInterval = 60 * 60

    if elapsed < oneHour {
      let relative = relativeBackupDate(from: lastBackupAt)
      return String(localized: "Last backup: \(relative)", comment: "Subtitle showing how long ago the last automatic iCloud backup ran.")
    }

    let remaining = BackupScheduler.intervalSeconds - elapsed
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    if remaining <= 0 {
      // Backup is overdue but hasn't run yet (e.g. iOS hasn't woken the BGTask).
      return String(localized: "Next backup soon", comment: "Subtitle on Automatic iCloud Backup row when the next backup is overdue but hasn't run.")
    }
    let nextDate = now.addingTimeInterval(remaining)
    let relative = formatter.localizedString(for: nextDate, relativeTo: now)
    return String(localized: "Next backup \(relative)", comment: "Subtitle showing time until the next automatic iCloud backup. The placeholder is a localized relative time like 'in 5 hours'.")
  }

  private func saveToICloudDrive() {
    // Avoid running while CloudKit is actively syncing
    if CloudSyncManager.shared.isSyncing {
      iCloudSaveMessage = "iCloud sync is active. Please try again later."
      showICloudSaveAlert = true
      return
    }
    let container = modelContext.container
    Task.detached {
      do {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DayEntry>()
        let entries = try context.fetch(descriptor)
        let data = try BackupManager.shared.serializeEntries(entries)
        _ = try BackupManager.shared.writeBackupToICloudDrive(data: data)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: BackupScheduler.lastAutoBackupAtKey)
        let entryCount = entries.count

        await MainActor.run {
          iCloudSaveMessage = String(localized: "Backup saved", comment: "Confirmation shown after a manual iCloud backup completes successfully.")
          showICloudSaveAlert = true
          AnalyticsManager.shared.trackDataExported(entryCount: entryCount)
        }
      } catch BackupManager.BackupError.ubiquityUnavailable {
        await MainActor.run {
          iCloudSaveMessage = "iCloud Drive is not available. Make sure you're signed into iCloud and iCloud Drive is enabled."
          showICloudSaveAlert = true
        }
      } catch {
        await MainActor.run {
          iCloudSaveMessage = "Failed to save backup: \(error.localizedDescription)"
          showICloudSaveAlert = true
        }
      }
    }
  }
}

// MARK: - Data Transfer Objects

struct DayEntryDTO: Codable {
  let body: String
  let createdAt: Date
  let dateString: String?
  let drawingData: Data?
  let drawingThumbnail20: Data?
  let drawingThumbnail200: Data?
  /// Doodles 2…N for a multi-doodle day, JSON-encoded `[Doodle]` — mirrors
  /// `DayEntry.extraDoodlesData`. Absent/nil for single-doodle days and for
  /// backups written before the multi-doodle feature (they decode as nil).
  let extraDoodlesData: Data?

  enum CodingKeys: String, CodingKey {
    case body
    case createdAt
    case dateString
    case drawingData
    case drawingThumbnail20
    case drawingThumbnail200
    case extraDoodlesData
  }

  init(body: String, createdAt: Date, dateString: String?, drawingData: Data?, drawingThumbnail20: Data?, drawingThumbnail200: Data?, extraDoodlesData: Data?) {
    self.body = body
    self.createdAt = createdAt
    self.dateString = dateString
    self.drawingData = drawingData
    self.drawingThumbnail20 = drawingThumbnail20
    self.drawingThumbnail200 = drawingThumbnail200
    self.extraDoodlesData = extraDoodlesData
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    body = try container.decode(String.self, forKey: .body)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    dateString = try container.decodeIfPresent(String.self, forKey: .dateString)
    drawingData = try container.decodeIfPresent(Data.self, forKey: .drawingData)
    drawingThumbnail20 = try container.decodeIfPresent(Data.self, forKey: .drawingThumbnail20)
    drawingThumbnail200 = try container.decodeIfPresent(Data.self, forKey: .drawingThumbnail200)
    extraDoodlesData = try container.decodeIfPresent(Data.self, forKey: .extraDoodlesData)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(body, forKey: .body)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(dateString, forKey: .dateString)
    try container.encodeIfPresent(drawingData, forKey: .drawingData)
    try container.encodeIfPresent(drawingThumbnail20, forKey: .drawingThumbnail20)
    try container.encodeIfPresent(drawingThumbnail200, forKey: .drawingThumbnail200)
    try container.encodeIfPresent(extraDoodlesData, forKey: .extraDoodlesData)
  }
}

// MARK: - App Stats View

struct AppStatsView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.cloudSyncManager) private var cloudSyncManager
  @Environment(\.dismiss) private var dismiss
  @StateObject private var subscriptionManager = SubscriptionManager.shared
  
  @State private var totalEntries: Int = 0
  @State private var uniqueDateCount: Int = 0
  @State private var duplicateCount: Int = 0
  @State private var duplicateDetails: [String: Int] = [:]
  @State private var isCleaningDuplicates = false
  @State private var isCleaningEmpty = false
  @State private var cleanupResult: String?
  
  // Debug breakdown
  @State private var entriesByYear: [Int: Int] = [:]
  @State private var entriesWithDrawing: Int = 0
  @State private var entriesWithText: Int = 0
  @State private var entriesEmpty: Int = 0
  @State private var entriesWithEmptyDateString: Int = 0
  
  var body: some View {
    NavigationStack {
      List {
        Section("Overview") {
          HStack {
            Text("Total Entries")
            Spacer()
            Text(totalEntries, format: .number.grouping(.never))
              .foregroundColor(.secondary)
          }
          HStack {
            Text("Unique Dates")
            Spacer()
            Text(uniqueDateCount, format: .number.grouping(.never))
              .foregroundColor(.secondary)
          }
          HStack {
            Text("Duplicate Entries")
            Spacer()
            Text(duplicateCount, format: .number.grouping(.never))
              .foregroundColor(duplicateCount > 0 ? .orange : .secondary)
          }
        }
        
        Section("Content Breakdown") {
          HStack {
            Text("With Drawing")
            Spacer()
            Text(entriesWithDrawing, format: .number.grouping(.never))
              .foregroundColor(.secondary)
          }
          HStack {
            Text("With Text Only")
            Spacer()
            Text(entriesWithText, format: .number.grouping(.never))
              .foregroundColor(.secondary)
          }
          HStack {
            Text("Empty Entries")
            Spacer()
            Text(entriesEmpty, format: .number.grouping(.never))
              .foregroundColor(entriesEmpty > 0 ? .orange : .secondary)
          }
          HStack {
            Text("Missing Date String")
            Spacer()
            Text(entriesWithEmptyDateString, format: .number.grouping(.never))
              .foregroundColor(entriesWithEmptyDateString > 0 ? .red : .secondary)
          }
        }
        
        if !entriesByYear.isEmpty {
          Section("Entries by Year") {
            ForEach(entriesByYear.keys.sorted().reversed(), id: \.self) { year in
              HStack {
                Text(year, format: .number.grouping(.never))
                Spacer()
                Text(entriesByYear[year] ?? 0, format: .number.grouping(.never))
                  .foregroundColor(.secondary)
              }
            }
          }
        }
        
        if duplicateCount > 0 {
          Section("Duplicate Details") {
            ForEach(duplicateDetails.keys.sorted(), id: \.self) { dateString in
              HStack {
                Text(dateString)
                  .font(.appCaption())
                Spacer()
                Text("\(duplicateDetails[dateString] ?? 0, format: .number.grouping(.never)) entries")
                  .font(.appCaption())
                  .foregroundColor(.orange)
              }
            }
          }
        }
        
        Section("Sync Status") {
          HStack {
            Text("iCloud Available")
            Spacer()
            Image(systemName: cloudSyncManager.isCloudAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
              .foregroundColor(cloudSyncManager.isCloudAvailable ? .green : .red)
          }
          HStack {
            Text("Can Sync")
            Spacer()
            Image(systemName: cloudSyncManager.canSync ? "checkmark.circle.fill" : "xmark.circle.fill")
              .foregroundColor(cloudSyncManager.canSync ? .green : .red)
          }
          HStack {
            Text("Is Syncing")
            Spacer()
            if cloudSyncManager.isSyncing {
              ProgressView()
                .scaleEffect(0.8)
            } else {
              Image(systemName: "xmark.circle.fill")
                .foregroundColor(.secondary)
            }
          }
        }
        
        Section("Subscription") {
          HStack {
            Text("Status")
            Spacer()
            Text(subscriptionManager.hasPremiumAccess ? "Pro" : "Free")
              .foregroundColor(subscriptionManager.hasPremiumAccess ? .green : .secondary)
          }
          if let message = subscriptionManager.subscriptionStatusMessage {
            HStack {
              Text("Details")
              Spacer()
              Text(message)
                .font(.appCaption())
                .foregroundColor(.secondary)
            }
          }
        }
        
        Section("Actions") {
          Button {
            printDetailedDebugInfo()
          } label: {
            Text("Print Debug Info to Console")
          }
          
          if duplicateCount > 0 {
            Button {
              clearDuplicates()
            } label: {
              HStack {
                Text("Clear Duplicates")
                if isCleaningDuplicates {
                  Spacer()
                  ProgressView()
                    .scaleEffect(0.8)
                }
              }
            }
            .disabled(isCleaningDuplicates)
          }
          
          if entriesEmpty > 0 {
            Button(role: .destructive) {
              deleteEmptyEntries()
            } label: {
              HStack {
                Text("Delete Empty Entries")
                if isCleaningEmpty {
                  Spacer()
                  ProgressView()
                    .scaleEffect(0.8)
                }
              }
            }
            .disabled(isCleaningEmpty)
          }
        }
        
        if let result = cleanupResult {
          Section("Result") {
            Text(result)
              .font(.appCaption())
              .foregroundColor(.secondary)
          }
        }
      }
      .navigationTitle("App Stats")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .onAppear {
        loadStats()
        loadDebugBreakdown()
      }
    }
  }
  
  private func loadStats() {
    let descriptor = FetchDescriptor<DayEntry>()
    if let entries = try? modelContext.fetch(descriptor) {
      totalEntries = entries.count
      let dateStrings = entries.compactMap { $0.dateString }
      uniqueDateCount = Set(dateStrings).count
      duplicateCount = totalEntries - uniqueDateCount
    }
  }
  
  private func loadDebugBreakdown() {
    let descriptor = FetchDescriptor<DayEntry>()
    guard let entries = try? modelContext.fetch(descriptor) else { return }
    
    var yearCounts: [Int: Int] = [:]
    var withDrawing = 0
    var withText = 0
    var empty = 0
    var emptyDateString = 0
    var dateDuplicates: [String: Int] = [:]
    
    for entry in entries {
      let calendar = Calendar.current
      let year = calendar.component(.year, from: entry.createdAt)
      yearCounts[year, default: 0] += 1
      
      let hasDrawing = entry.drawingData != nil && !entry.drawingData!.isEmpty
      let hasText = !entry.body.isEmpty
      
      if hasDrawing {
        withDrawing += 1
      } else if hasText {
        withText += 1
      } else {
        empty += 1
      }
      
      if entry.dateString.isEmpty {
        emptyDateString += 1
      }
      
      dateDuplicates[entry.dateString, default: 0] += 1
    }
    
    entriesByYear = yearCounts
    entriesWithDrawing = withDrawing
    entriesWithText = withText
    entriesEmpty = empty
    entriesWithEmptyDateString = emptyDateString
    duplicateDetails = dateDuplicates.filter { $0.value > 1 }
  }
  
  private func printDetailedDebugInfo() {
    let descriptor = FetchDescriptor<DayEntry>()
    guard let entries = try? modelContext.fetch(descriptor) else { return }
    
    print("=== DETAILED DEBUG INFO ===")
    print("Total entries: \(entries.count)")
    print("")
    
    let sortedEntries = entries.sorted { $0.createdAt < $1.createdAt }
    var dateGroups: [String: [DayEntry]] = [:]
    
    for entry in sortedEntries {
      let key = entry.dateString.isEmpty ? "(empty)" : entry.dateString
      dateGroups[key, default: []].append(entry)
    }
    
    print("=== ENTRIES BY DATE ===")
    for dateString in dateGroups.keys.sorted() {
      let group = dateGroups[dateString]!
      if group.count > 1 {
        print("\n⚠️ DUPLICATE: \(dateString) - \(group.count) entries")
        for (index, entry) in group.enumerated() {
          let hasDrawing = entry.drawingData != nil && !entry.drawingData!.isEmpty
          let textPreview = entry.body.prefix(50).replacingOccurrences(of: "\n", with: " ")
          print("  [\(index + 1)] Created: \(entry.createdAt), Drawing: \(hasDrawing), Text: \"\(textPreview)\"")
        }
      }
    }
    
    print("\n=== EMPTY ENTRIES ===")
    let emptyEntries = entries.filter { entry in
      let hasDrawing = entry.drawingData != nil && !entry.drawingData!.isEmpty
      let hasText = !entry.body.isEmpty
      return !hasDrawing && !hasText
    }
    for entry in emptyEntries {
      print("Empty: \(entry.dateString.isEmpty ? "(empty)" : entry.dateString) - Created: \(entry.createdAt)")
    }
    
    print("\n=== END DEBUG INFO ===")
  }
  
  private func clearDuplicates() {
    isCleaningDuplicates = true
    
    Task {
      let result = DuplicateEntryCleanup.shared.forceCleanupDuplicates(modelContext: modelContext, markAsCompleted: false)
      await MainActor.run {
        cleanupResult = "Merged \(result.merged), deleted \(result.deleted) entries"
        isCleaningDuplicates = false
        loadStats()
        loadDebugBreakdown()
      }
    }
  }
  
  private func deleteEmptyEntries() {
    isCleaningEmpty = true
    
    Task {
      let descriptor = FetchDescriptor<DayEntry>()
      guard let entries = try? modelContext.fetch(descriptor) else {
        await MainActor.run {
          isCleaningEmpty = false
          cleanupResult = "Failed to fetch entries"
        }
        return
      }
      
      var deletedCount = 0
      for entry in entries {
        let hasDrawing = entry.drawingData != nil && !entry.drawingData!.isEmpty
        let hasText = !entry.body.isEmpty
        if !hasDrawing && !hasText {
          modelContext.delete(entry)
          deletedCount += 1
        }
      }
      
      try? modelContext.save()
      
      await MainActor.run {
        cleanupResult = "Deleted \(deletedCount) empty entries"
        isCleaningEmpty = false
        loadStats()
        loadDebugBreakdown()
      }
    }
  }
}

// MARK: - Learn Core Features View

struct LearnCoreFeaturesView: View {
  @StateObject private var subscriptionManager = SubscriptionManager.shared
  @State private var selectedTutorialStep: TutorialStepType?
  @State private var showRevisitOnboardingConfirmation = false
  @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true
  
  var body: some View {
    List {
      Section {
        ForEach(TutorialStepType.allCases) { stepType in
          Button {
            selectedTutorialStep = stepType
          } label: {
            HStack {
              SettingsIconView(systemName: stepType.icon, backgroundColor: .indigo)
              Text(stepType.title)
                .foregroundColor(.textColor)
              Spacer()
              Image(systemName: "chevron.right")
                .font(.appCaption())
                .foregroundColor(.secondaryTextColor)
            }
          }
        }
      } header: {
        Text("Interactive Tutorials")
      }
      
      Section {
        ForEach(TutorialDefinitions.widgetTutorials) { tutorial in
          NavigationLink {
            TutorialView(
              title: tutorial.title,
              screenshots: tutorial.screenshots,
              description: tutorial.description
            )
          } label: {
            HStack {
              SettingsIconView(systemName: tutorial.icon, backgroundColor: .indigo)
              Text(tutorial.title)
                .foregroundColor(.primary)
              Spacer()
              if !subscriptionManager.hasPremiumAccess && tutorial.isPremiumFeature {
                PremiumFeatureBadge()
              }
            }
          }
        }
      } header: {
        Text("Widget Tutorials")
      }
      
      Section {
        ForEach(TutorialDefinitions.otherTutorials) { tutorial in
          NavigationLink {
            TutorialView(
              title: tutorial.title,
              screenshots: tutorial.screenshots,
              description: tutorial.description
            )
          } label: {
            HStack {
              SettingsIconView(systemName: tutorial.icon, backgroundColor: .indigo)
              Text(tutorial.title)
                .foregroundColor(.primary)
              Spacer()
              if !subscriptionManager.hasPremiumAccess && tutorial.isPremiumFeature {
                PremiumFeatureBadge()
              }
            }
          }
        }
      }
      
      Section {
        Button {
          showRevisitOnboardingConfirmation = true
        } label: {
          HStack {
            SettingsIconView(systemName: "arrow.counterclockwise", backgroundColor: .orange)
            Text("Revisit Onboarding")
              .foregroundColor(.primary)
          }
        }
      }
      .confirmationDialog(
        "Revisit Onboarding?",
        isPresented: $showRevisitOnboardingConfirmation,
        titleVisibility: .visible
      ) {
        Button("Revisit Onboarding") {
          // Set flag to indicate this is a revisit from settings (ensures tutorials are shown)
          UserDefaults.standard.set(true, forKey: "isRevisitFromSettings")
          // Reset the flag to trigger onboarding flow in JoodleApp
          hasCompletedOnboarding = false
        }
        Button("Cancel", role: .cancel) { }
      } message: {
        Text("This will restart the full onboarding experience. Today's entry may be overwritten, and you will go through preference setup again.")
      }
    }
    .navigationTitle("Learn Core Features")
    .navigationBarTitleDisplayMode(.inline)
    .postHogScreenView("Learn Core Features")
    .fullScreenCover(item: $selectedTutorialStep) { stepType in
      InteractiveTutorialView(stepType: stepType) {
        selectedTutorialStep = nil
      }
    }
    
  }
}

// MARK: - Debug Data Seeder View

#if DEBUG
struct DebugDataSeederView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true
  @ObservedObject private var gracePeriodManager = GracePeriodManager.shared
  @State private var selectedYear = Calendar.current.component(.year, from: Date())
  @State private var seedCount = 10
  @State private var selectedDrawingSize: DebugDataSeeder.DrawingSize = .placeholder
  @State private var currentDebugCount = 0
  @State private var isSeeding = false
  @State private var seedingProgress = ""

  // Stats
  @State private var yearStats: (total: Int, withDrawings: Int, seeded: Int) = (0, 0, 0)
  @State private var payloadStats: (userDefaultsBytes: Int, drawingFileBytes: Int, thumbnailBytes: Int, entryCount: Int) = (0, 0, 0, 0)

  private var currentYear: Int {
    Calendar.current.component(.year, from: Date())
  }

  var body: some View {
    NavigationStack {
      Form {
        // MARK: Widget Payload Memory Stats
        Section {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("Total entries")
              Spacer()
              Text(payloadStats.entryCount, format: .number.grouping(.never))
                .foregroundStyle(.secondary)
            }
            HStack {
              Text("UserDefaults payload")
              Spacer()
              Text(formatBytes(payloadStats.userDefaultsBytes))
                .foregroundStyle(payloadStats.userDefaultsBytes > 4_000_000 ? .red : payloadStats.userDefaultsBytes > 1_000_000 ? .orange : .green)
                .fontWeight(payloadStats.userDefaultsBytes > 1_000_000 ? .semibold : .regular)
            }
            HStack {
              Text("  └─ Thumbnails")
              Spacer()
              Text(formatBytes(payloadStats.thumbnailBytes))
                .foregroundStyle(.secondary)
            }
            .font(.appCaption())
            HStack {
              Text("Drawing files (on disk)")
              Spacer()
              Text(formatBytes(payloadStats.drawingFileBytes))
                .foregroundStyle(.secondary)
            }
          }

          if payloadStats.userDefaultsBytes > 4_000_000 {
            Label("UserDefaults exceeds 4 MB — widgets will be throttled!", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .font(.appCaption())
          } else if payloadStats.userDefaultsBytes > 1_000_000 {
            Label("UserDefaults exceeds 1 MB — widgets may update slowly", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
              .font(.appCaption())
          } else {
            Label("UserDefaults payload within safe limits", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .font(.appCaption())
          }

          Button("Trigger Widget Update Now") {
            WidgetHelper.shared.updateWidgetData(in: modelContext)
          }
          .disabled(isSeeding)
        } header: {
          Text("Widget Payload Memory")
        } footer: {
          Text("Drawing data is stored as individual files in the App Group container (no size limit). Only metadata and thumbnails go into UserDefaults.")
        }

        // MARK: Year Stats
        Section("Year \(selectedYear, format: .number.grouping(.never)) Status") {
          HStack {
            Text("Total entries")
            Spacer()
            Text(yearStats.total, format: .number.grouping(.never))
              .foregroundStyle(.secondary)
          }
          HStack {
            Text("With drawings")
            Spacer()
            Text(yearStats.withDrawings, format: .number.grouping(.never))
              .foregroundStyle(.secondary)
          }
          HStack {
            Text("Seeded (debug/stress)")
            Spacer()
            Text(yearStats.seeded, format: .number.grouping(.never))
              .foregroundStyle(.secondary)
          }
        }

        // MARK: Seed Data
        Section {
          Picker("Year", selection: $selectedYear) {
            ForEach((2020...currentYear).reversed(), id: \.self) { year in
              Text(String(year)).tag(year)
            }
          }
          .onChange(of: selectedYear) { _, _ in refreshStats() }

          HStack {
            Text("Count")
            Spacer()
            TextField("Count", value: $seedCount, format: .number.grouping(.never))
              .keyboardType(.numberPad)
              .multilineTextAlignment(.trailing)
              .frame(width: 80)

            Button("MAX") {
              seedCount = DebugDataSeeder.shared.daysInYear(selectedYear)
            }
            .buttonStyle(.bordered)
            .font(.appCaption())
          }

          Picker("Drawing Size", selection: $selectedDrawingSize) {
            ForEach(DebugDataSeeder.DrawingSize.allCases) { size in
              Text(size.rawValue).tag(size)
            }
          }

          Button {
            seedData()
          } label: {
            HStack {
              Text("Seed \(seedCount, format: .number.grouping(.never)) Entries for \(selectedYear, format: .number.grouping(.never))")
              if isSeeding {
                Spacer()
                ProgressView()
              }
            }
          }
          .disabled(isSeeding)
        } header: {
          Text("Stress Test Seeder")
        } footer: {
          let estimatedPerEntry: String = {
            switch selectedDrawingSize {
            case .placeholder: return "~1 KB"
            case .small: return "~5 KB"
            case .medium: return "~20 KB"
            case .large: return "~80 KB"
            case .huge: return "~200 KB"
            }
          }()
          let estimatedTotal = seedCount * (selectedDrawingSize == .placeholder ? 1 : selectedDrawingSize == .small ? 5 : selectedDrawingSize == .medium ? 20 : selectedDrawingSize == .large ? 80 : 200)
          Text("Each entry: \(estimatedPerEntry) drawing data. Total estimate: ~\(estimatedTotal >= 1000 ? "\(estimatedTotal / 1000) MB" : "\(estimatedTotal) KB") widget payload for \(seedCount) entries.")
        }

        if !seedingProgress.isEmpty {
          Section("Progress") {
            Text(seedingProgress)
              .font(.appCaption())
              .foregroundStyle(.secondary)
          }
        }

        // MARK: Paywall & Onboarding
        Section {
          HStack {
            Text("Trial state")
            Spacer()
            Text(trialStateDescription)
              .foregroundStyle(.secondary)
          }

          Button {
            GracePeriodManager.shared.resetGracePeriod()
            TrialOfferManager.shared.resetFunnelState()
            UserDefaults.standard.removeObject(forKey: "isRevisitFromSettings")
            hasCompletedOnboarding = false
            dismiss()
          } label: {
            Label("Restart Onboarding (fresh first-run)", systemImage: "arrow.counterclockwise.circle")
          }

          Button("Simulate Trial: 5 days left") {
            GracePeriodManager.shared.resetGracePeriod()
            GracePeriodManager.shared.setGracePeriodStart(Date().addingTimeInterval(-2 * 86_400))
            dismiss()
          }

          Button("Simulate Trial: Day 5 (reminder · 2 left)") {
            GracePeriodManager.shared.resetGracePeriod()
            GracePeriodManager.shared.setGracePeriodStart(Date().addingTimeInterval(-5 * 86_400))
            dismiss()
          }

          Button("Simulate Trial: 1 day left") {
            GracePeriodManager.shared.resetGracePeriod()
            GracePeriodManager.shared.setGracePeriodStart(Date().addingTimeInterval(-6 * 86_400))
            dismiss()
          }

          Button("Simulate Trial: Expired") {
            GracePeriodManager.shared.resetGracePeriod()
            GracePeriodManager.shared.setGracePeriodStart(Date().addingTimeInterval(-8 * 86_400))
            dismiss()
          }

          Button {
            GracePeriodManager.shared.sendTrialReminderNow()
            dismiss()
          } label: {
            Label("Send Trial Reminder Now (5s)", systemImage: "bell.badge")
          }
        } header: {
          Text("Paywall & Onboarding")
        } footer: {
          Text("Restart Onboarding wipes the trial + claim-funnel state and replays the first-time flow including the paywall step. Trial simulations set the trial clock — return to Settings to see the banner/sheet; relaunch to see the post-trial sheet. \"Send Trial Reminder Now\" fires the day-5 reminder notification in 5s — background the app to see it on the lock screen.")
        }

        // MARK: Danger Zone
        Section("Danger Zone") {
          Button("Clear Seeded Data for \(selectedYear, format: .number.grouping(.never))", role: .destructive) {
            clearYearData()
          }
          .disabled(isSeeding)

          Button("Clear All Seeded Data (≤2024)", role: .destructive) {
            clearAllData()
          }
          .disabled(isSeeding)
        }
      }
      .navigationTitle("Data Seeder")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .onAppear {
        refreshStats()
      }
    }
  }

  // MARK: - Helpers

  private var trialStateDescription: String {
    if gracePeriodManager.isInGracePeriod {
      return "Trial · \(gracePeriodManager.gracePeriodDaysRemaining)d left"
    }
    if gracePeriodManager.hasGracePeriodExpired {
      return "Expired"
    }
    return "Not started"
  }

  private func formatBytes(_ bytes: Int) -> String {
    if bytes >= 1_048_576 {
      return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    } else if bytes >= 1_024 {
      return String(format: "%.0f KB", Double(bytes) / 1_024.0)
    }
    return "\(bytes) B"
  }

  private func refreshStats() {
    currentDebugCount = DebugDataSeeder.shared.getDebugEntryCount(container: modelContext.container)
    yearStats = DebugDataSeeder.shared.getEntryStats(for: selectedYear, container: modelContext.container)
    payloadStats = DebugDataSeeder.shared.estimateWidgetPayloadSize(container: modelContext.container)
  }

  private func seedData() {
    isSeeding = true
    seedingProgress = "Seeding \(seedCount) entries..."
    Task {
      await DebugDataSeeder.shared.seedEntries(
        for: selectedYear, count: seedCount, drawingSize: selectedDrawingSize, container: modelContext.container)
      seedingProgress = "Done! Syncing to widgets..."
      // Also update widget data to see the memory impact
      WidgetHelper.shared.updateWidgetData(in: modelContext)
      refreshStats()
      seedingProgress = ""
      isSeeding = false
    }
  }

  private func clearYearData() {
    isSeeding = true
    seedingProgress = "Clearing seeded data for \(selectedYear)..."
    Task {
      await DebugDataSeeder.shared.clearSeededData(for: selectedYear, container: modelContext.container)
      WidgetHelper.shared.updateWidgetData(in: modelContext)
      refreshStats()
      seedingProgress = ""
      isSeeding = false
    }
  }

  private func clearAllData() {
    isSeeding = true
    seedingProgress = "Clearing all seeded data..."
    Task {
      await DebugDataSeeder.shared.clearAllDebugData(container: modelContext.container)
      WidgetHelper.shared.updateWidgetData(in: modelContext)
      refreshStats()
      seedingProgress = ""
      isSeeding = false
    }
  }
}
#endif

// MARK: - Membership Banner Preview View (Debug)

#if DEBUG
struct MembershipBannerPreviewView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selectedState: BannerPreviewState = .free
  
  enum BannerPreviewState: String, CaseIterable {
    case free = "Free User"
    case gracePeriod = "Grace Period (5 days)"
    case gracePeriodLastDay = "Grace Period (1 day)"
    case proActive = "Pro (Active)"
    case proTrial = "Pro (Trial)"
    case proCancelled = "Pro (Cancelled)"
    case proExpiringSoon = "Pro (Expiring Soon)"
  }
  
  var body: some View {
    NavigationStack {
      List {
        Section {
          Picker("Preview State", selection: $selectedState) {
            ForEach(BannerPreviewState.allCases, id: \.self) { state in
              Text(state.rawValue).tag(state)
            }
          }
          .pickerStyle(.menu)
        }
        
        Section("Preview") {
          MembershipBannerView(
            hasPremiumAccess: hasPremiumAccess,
            isInGracePeriod: isInGracePeriod,
            gracePeriodDaysRemaining: gracePeriodDaysRemaining,
            statusMessage: statusMessage,
            onTap: {}
          )
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
      }
      .navigationTitle("Banner Preview")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
  
  private var hasPremiumAccess: Bool {
    switch selectedState {
    case .free:
      return false
    case .gracePeriod, .gracePeriodLastDay, .proActive, .proTrial, .proCancelled, .proExpiringSoon:
      return true
    }
  }
  
  private var isInGracePeriod: Bool {
    switch selectedState {
    case .gracePeriod, .gracePeriodLastDay:
      return true
    default:
      return false
    }
  }
  
  private var gracePeriodDaysRemaining: Int {
    switch selectedState {
    case .gracePeriod:
      return 5
    case .gracePeriodLastDay:
      return 1
    default:
      return 0
    }
  }
  
  private var statusMessage: String? {
    switch selectedState {
    case .proTrial:
      let futureDate = Calendar.current.date(byAdding: .day, value: 5, to: Date())!
      let formatter = DateFormatter()
      formatter.dateStyle = .medium
      return "Trial ends \(formatter.string(from: futureDate))"
    case .proCancelled:
      let futureDate = Calendar.current.date(byAdding: .day, value: 20, to: Date())!
      let formatter = DateFormatter()
      formatter.dateStyle = .medium
      return "Expires \(formatter.string(from: futureDate))"
    case .proExpiringSoon:
      let futureDate = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
      let formatter = DateFormatter()
      formatter.dateStyle = .medium
      return "Expires \(formatter.string(from: futureDate))"
    default:
      return nil
    }
  }
}
#endif

#Preview {
  NavigationStack {
    SettingsView()
      .environment(\.userPreferences, UserPreferences.shared)
  }
}
