//
//  SubscriptionManager.swift
//  Joodle
//
//  Created by Subscription Manager
//

import Foundation
import Combine
import StoreKit
import SwiftData
import Network

@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    // MARK: - Stored Properties (persisted to UserDefaults)

    /// Whether user has an active subscription - computed from stored expiration date
    @Published private(set) var isSubscribed: Bool = false {
        didSet {
            // Don't trigger side effects during initialization to avoid circular dependency
            guard !isInitializing else { return }

            // Handle subscription state changes
            if oldValue && !isSubscribed {
                handleSubscriptionLost()
            } else if !oldValue && isSubscribed {
                handleSubscriptionGained()
            }
        }
    }

    @Published var isInTrialPeriod: Bool = false
    @Published var willAutoRenew: Bool = false
    @Published var hasRedeemedOfferCode: Bool = false
    @Published var offerCodeId: String? = nil
    @Published var hasPendingOfferCode: Bool = false  // Offer code queued for next renewal
    @Published var pendingOfferCodeId: String? = nil
    @Published var pendingPlanProductID: String? = nil  // Product the subscription will renew to (if plan changed)

    /// Flag indicating subscription just expired (for UI alerts)
    @Published var subscriptionJustExpired: Bool = false

    /// Whether the user has a lifetime (non-consumable) purchase
    @Published var isLifetimeUser: Bool = false

    /// The stored subscription expiration date - this is the source of truth for local checks
    var subscriptionExpirationDate: Date? {
        get {
            UserDefaults.standard.object(forKey: "subscriptionExpirationDate") as? Date
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "subscriptionExpirationDate")
        }
    }

    /// The stored product ID of the current subscription
    private var storedProductID: String? {
        get {
            UserDefaults.standard.string(forKey: "subscriptionProductID")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "subscriptionProductID")
        }
    }

    /// Last time subscription was successfully verified online with StoreKit
    private var lastOnlineVerificationDate: Date? {
        get {
            UserDefaults.standard.object(forKey: "lastOnlineVerificationDate") as? Date
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "lastOnlineVerificationDate")
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var expirationCheckTimer: Timer?

    /// Flag to prevent triggering side effects during initialization
    private var isInitializing = true

    /// Whether the user has premium access (subscription OR grace period)
    /// Use this for all feature gating instead of `isSubscribed` directly
    var hasPremiumAccess: Bool {
        isSubscribed || GracePeriodManager.shared.isInGracePeriod
    }

    #if DEBUG
    /// When true, prevents StoreKit refreshes from overwriting preview state
    private var isPreviewMode = false
    #endif

    /// Minimum interval between StoreKit refreshes (in seconds) to avoid rate limiting
    private let refreshInterval: TimeInterval = 30

    /// Last time we attempted a refresh (to implement rate limiting)
    private var lastRefreshAttempt: Date?

    // MARK: - Initialization

    private init() {
        // Set initial subscription state from stored date WITHOUT triggering didSet side effects
        let storedProduct = UserDefaults.standard.string(forKey: "subscriptionProductID")
        if let storedProduct, JoodleProducts.lifetimeIDs.contains(storedProduct) {
            // Lifetime purchase - always active, no expiration check needed
            isSubscribed = true
            isLifetimeUser = true
        } else if let expirationDate = subscriptionExpirationDate, Date() < expirationDate {
            isSubscribed = true
        }

        // Now allow side effects
        isInitializing = false

        // Start monitoring subscription status
        Task {
            // Refresh from StoreKit on launch to get latest status
            await refreshSubscriptionFromStoreKit()

            // Check premium theme color on launch - reset to default if not subscribed
            await checkAndResetPremiumThemeColorIfNeeded()
        }

        // Set up periodic expiration check (local check, very lightweight)
        setupExpirationCheck()

        // Listen for app becoming active to refresh status from StoreKit
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        // Listen for app entering background to update widget status
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    deinit {
        expirationCheckTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Subscription Features

    var hasUnlimitedJoodles: Bool {
        hasPremiumAccess
    }

    var hasWidgets: Bool {
        hasPremiumAccess
    }

    var hasAllShareTemplates: Bool {
        hasPremiumAccess
    }

    var hasWatermarkRemoval: Bool {
        hasPremiumAccess
    }

    // Free plan limits - maximum total Joodles allowed for free users.
    // 7 for installs on the claim funnel; 30 stays grandfathered for legacy
    // installs whose auto-started trial predates it. Resolved once by
    // TrialOfferManager.migrateFunnelStateIfNeeded and stored; before that
    // (or on a fresh reinstall racing iCloud KVS) the presence of a legacy
    // grace-period start date decides.
    nonisolated static let baseFreeJoodlesAllowed = 7
    nonisolated static let legacyFreeJoodlesAllowed = 30

    nonisolated static var freeJoodlesAllowed: Int {
        resolveFreeJoodleLimit(
            storedLimit: UserDefaults.standard.integer(forKey: TrialOfferManager.freeJoodleLimitKey),
            legacyGraceExists: UserDefaults.standard.object(forKey: "grace_period_start_date") != nil
        )
    }

    /// Pure limit resolution, unit-testable without UserDefaults.
    nonisolated static func resolveFreeJoodleLimit(storedLimit: Int, legacyGraceExists: Bool) -> Int {
        if storedLimit > 0 { return storedLimit }
        return legacyGraceExists ? legacyFreeJoodlesAllowed : baseFreeJoodlesAllowed
    }

    // MARK: - Day-Scoped Doodle Gate (additive; replaces the lifetime cap above)

    /// Result of `resolveDoodleGate`. `.dayLocked` takes precedence over
    /// `.dailyLimitReached` — "this isn't today" is checked before the count,
    /// since that's the reason backfill/future days are blocked for free users.
    enum DoodleGate: Equatable {
        case allowed
        case dayLocked          // not today, and not Pro
        case dailyLimitReached  // today, but the free 1-a-day is used up
    }

    /// Free users may draw one doodle per day, only on today.
    nonisolated static let freeDoodlesPerDay = 1

    /// Pure, unit-testable. `existingDoodleCount` is the doodle count already on the
    /// target day; `hasPremiumAccess` bypasses everything.
    nonisolated static func resolveDoodleGate(
        on date: Date,
        existingDoodleCount: Int,
        hasPremiumAccess: Bool,
        now: Date = Date()
    ) -> DoodleGate {
        if hasPremiumAccess { return .allowed }
        guard Calendar.current.isDate(date, inSameDayAs: now) else { return .dayLocked }
        return existingDoodleCount < freeDoodlesPerDay ? .allowed : .dailyLimitReached
    }

    // MARK: - Network-Aware Access Control

    /// Check if network is available for StoreKit verification
    private var isNetworkAvailable: Bool {
        // Use NetworkMonitor if available, otherwise return true to not block
        return NetworkMonitor.shared.isConnected
    }

    /// Verify subscription with online check before granting access
    /// Returns true if access should be granted, false otherwise
    @discardableResult func verifySubscriptionForAccess() async -> Bool {
        // Grace period grants full access — no StoreKit check needed
        if GracePeriodManager.shared.isInGracePeriod {
            return true
        }

        // Lifetime users always have access
        if isLifetimeUser {
            // Still refresh from StoreKit to confirm, but default to allowing access
            if isNetworkAvailable {
                await refreshSubscriptionFromStoreKit()
            }
            return isSubscribed
        }

        // If network is available, always refresh from StoreKit to get latest status
        if isNetworkAvailable {
            await refreshSubscriptionFromStoreKit()
            return isSubscribed
        }

        // Network is NOT available - check local expiry date
        // If subscription is still valid locally, allow access (safe assumption)
        // When user comes online, the expiry date will be auto-updated
        if let expirationDate = subscriptionExpirationDate, Date() < expirationDate {
            print("✅ Offline but subscription expiry date is still valid - allowing access")
            return isSubscribed
        }

        // Network unavailable AND (no expiry date OR expiry date has passed)
        // This is a security risk - deny access
        print("⚠️ Offline and subscription has expired locally - denying access")
        return false
    }

    // MARK: - Local Subscription Check

    /// Updates isSubscribed based on the stored expiration date (no network call)
    private func updateSubscribedStateFromStoredDate() {
        // Lifetime users are always subscribed
        if let storedProductID, JoodleProducts.lifetimeIDs.contains(storedProductID) {
            if !isSubscribed {
                isSubscribed = true
            }
            isLifetimeUser = true
            return
        }

        if let expirationDate = subscriptionExpirationDate {
            let wasSubscribed = isSubscribed
            let nowSubscribed = Date() < expirationDate

            // Only update if changed to avoid unnecessary didSet triggers
            if wasSubscribed != nowSubscribed {
                isSubscribed = nowSubscribed
            }
        } else {
            if isSubscribed {
                isSubscribed = false
            }
        }
    }

    // MARK: - StoreKit Refresh

    /// Refreshes subscription status from StoreKit and updates stored expiration date
    func refreshSubscriptionFromStoreKit() async {
        #if DEBUG
        guard !isPreviewMode else { return }
        #endif

        // Check if network is available
        // When offline, StoreKit returns inconsistent cached results
        // So we skip the StoreKit query and just use local expiry date
        guard isNetworkAvailable else {
            print("⚠️ Offline - skipping StoreKit refresh, using local expiry date")
            // Just check local expiry date
            updateSubscribedStateFromStoredDate()

            // Update widget subscription status
            WidgetHelper.shared.updateSubscriptionStatus()
            return
        }

        let storeManager = StoreKitManager.shared

        // Ensure products are loaded
        if storeManager.products.isEmpty {
            await storeManager.loadProducts()
        }

        // Query StoreKit for current subscription status (only when online)
        await storeManager.updatePurchasedProducts()

        // Update our stored state from StoreKit
        if storeManager.hasActiveSubscription {
            // Store the expiration date and product ID
            subscriptionExpirationDate = storeManager.subscriptionExpirationDate
            storedProductID = storeManager.currentProductID
            isInTrialPeriod = storeManager.isInTrialPeriod
            willAutoRenew = storeManager.willAutoRenew
            hasRedeemedOfferCode = storeManager.hasRedeemedOfferCode
            offerCodeId = storeManager.offerCodeId
            hasPendingOfferCode = storeManager.hasPendingOfferCode
            pendingOfferCodeId = storeManager.pendingOfferCodeId
            pendingPlanProductID = storeManager.pendingPlanProductID
            isLifetimeUser = storeManager.hasLifetimePurchase

            // Update subscribed state
            if !isSubscribed {
                isSubscribed = true
            }

            print("✅ Subscription active - expires: \(storeManager.subscriptionExpirationDate?.formatted() ?? "N/A")")
        } else {
            // A lifetime non-consumable never expires, so an empty entitlements read
            // for a known lifetime owner is a transient StoreKit glitch, not a real
            // loss. Clearing here would fire a false "subscription expired" alert.
            if isLifetimeUser || storedProductID.map({ JoodleProducts.lifetimeIDs.contains($0) }) == true {
                print("⚠️ StoreKit returned empty for lifetime owner - ignoring transient read")
                lastOnlineVerificationDate = Date()
                WidgetHelper.shared.updateSubscriptionStatus()
                return
            }

            // StoreKit says no active subscription - immediately clear everything
            // StoreKit is the source of truth, stored date is just a cache
            subscriptionExpirationDate = nil
            storedProductID = nil
            isInTrialPeriod = false
            willAutoRenew = false
            hasRedeemedOfferCode = false
            offerCodeId = nil
            hasPendingOfferCode = false
            pendingOfferCodeId = nil
            pendingPlanProductID = nil
            isLifetimeUser = false

            if isSubscribed {
                isSubscribed = false
            }

            print("❌ Subscription not active - cleared stored data")
        }

        // Update last online verification timestamp (only when online)
        lastOnlineVerificationDate = Date()

        // Update widget subscription status
        WidgetHelper.shared.updateSubscriptionStatus()
    }

    /// Public method for external callers (maintains API compatibility)
    func updateSubscriptionStatus() async {
        await refreshSubscriptionFromStoreKit()
    }

    // MARK: - Expiration Monitoring

    private func setupExpirationCheck() {
        // Check every 30 seconds if subscription has expired (local check only)
        expirationCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkExpiration()
            }
        }
    }

    /// Local check - just compares current time with stored expiration date
    private func checkExpiration() {
        guard isSubscribed else { return }
        // Lifetime users never expire
        guard !isLifetimeUser else { return }

        if let expirationDate = subscriptionExpirationDate {
            if Date() >= expirationDate {
                // Subscription has expired locally - refresh from StoreKit to confirm
                // (in case of renewal)
                Task {
                    await refreshSubscriptionFromStoreKit()
                }
            }
        }
    }

    @objc private func appDidBecomeActive() {
        // Refresh subscription status from StoreKit when app becomes active
        Task {
            await refreshSubscriptionFromStoreKit()
        }
    }

    @objc private func appWillResignActive() {
        // Update widget subscription status when app goes to background
        WidgetHelper.shared.updateSubscriptionStatus()
    }

    // MARK: - Subscription State Change Handling

    private func handleSubscriptionGained() {
        print("🎉 Subscription gained!")

        // A subscriber no longer needs the trial-ending reminder.
        GracePeriodManager.shared.cancelTrialReminder()

        // Auto-disable watermark for new pro users (they can now remove it)
        if UserPreferences.shared.shareCardWatermarkEnabled {
            UserPreferences.shared.shareCardWatermarkEnabled = false
        }

        // Auto-enable auto-trace on conversion so the now-unlimited button is
        // there to discover. A free user may have toggled it off deliberately,
        // but surfacing the feature they just paid to uncap wins here.
        if !UserPreferences.shared.isAutoTraceEnabled {
            UserPreferences.shared.isAutoTraceEnabled = true
        }

        // Update widget subscription status
        WidgetHelper.shared.updateSubscriptionStatus()

        // Post notification for other parts of the app
        NotificationCenter.default.post(
            name: .subscriptionDidActivate,
            object: nil
        )
    }

    /// Resets all premium feature preferences to free tier defaults
    /// Called when subscription is lost, grace period expires, or user downgrades
    func resetPremiumFeaturesToDefaults() {
        // Reset premium theme color to default if user was using a premium color
        let currentColor = UserPreferences.shared.accentColor
        if currentColor.isPremium {
            UserPreferences.shared.accentColor = ThemeColor.defaultColor
            // Save theme data without reloading — the subscription status update below will reload all widgets
            WidgetHelper.shared.updateThemeColor(reload: false)
        }

        // Reset watermark to enabled for free users (they can't disable it)
        if !UserPreferences.shared.shareCardWatermarkEnabled {
            UserPreferences.shared.shareCardWatermarkEnabled = true
        }

        // Update widget subscription status — this reloads all widgets once
        WidgetHelper.shared.updateSubscriptionStatus()
    }

    private func handleSubscriptionLost() {
        print("⚠️ Subscription lost")

        // If grace period is still active, don't strip premium features
        if GracePeriodManager.shared.isInGracePeriod {
            print("   Grace period still active — keeping premium features")
            return
        }

        print("   Disabling premium features")

        // Reset all premium features to free tier defaults
        resetPremiumFeaturesToDefaults()

        // Post notification for other parts of the app
        NotificationCenter.default.post(
            name: .subscriptionDidExpire,
            object: nil
        )

        // Set the expired flag
        let hadCloudSync = UserPreferences.shared.isCloudSyncEnabled
        if hadCloudSync {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.subscriptionJustExpired = true
            }
        } else {
            subscriptionJustExpired = true
        }
    }

    // MARK: - Theme Color Check

    func checkAndResetPremiumThemeColorIfNeeded() async {
        guard !hasPremiumAccess else { return }

        let currentColor = UserPreferences.shared.accentColor
        if currentColor.isPremium {
            print("🎨 Non-subscriber using premium color '\(currentColor.displayName)' - resetting to default")
            UserPreferences.shared.accentColor = ThemeColor.defaultColor
            // Reload all widgets to reflect the theme reset
            WidgetHelper.shared.updateThemeColor()
        }
    }

    // MARK: - Debug Methods

    var subscriptionStatusMessage: String? {
        guard isSubscribed else { return nil }

        // Lifetime users have permanent access
        if isLifetimeUser {
            return nil
        }

        if !willAutoRenew {
            if let expirationDate = subscriptionExpirationDate {
                let formatter = DateFormatter()
                formatter.locale = .autoupdatingCurrent
                formatter.calendar = .autoupdatingCurrent
                formatter.dateStyle = .medium
                let formattedDate = formatter.string(from: expirationDate)
                return String(localized: "Expires \(formattedDate)")
            }
            return String(localized: "Subscription ending")
        }

        if hasRedeemedOfferCode {
            if let expirationDate = subscriptionExpirationDate {
                let formatter = DateFormatter()
                formatter.locale = .autoupdatingCurrent
                formatter.calendar = .autoupdatingCurrent
                formatter.dateStyle = .medium
                let formattedDate = formatter.string(from: expirationDate)
                return String(localized: "Promo ends \(formattedDate)")
            }
            return String(localized: "Promo code active")
        }

        if isInTrialPeriod {
            if let expirationDate = subscriptionExpirationDate {
                let formatter = DateFormatter()
                formatter.locale = .autoupdatingCurrent
                formatter.calendar = .autoupdatingCurrent
                formatter.dateStyle = .medium
                let formattedDate = formatter.string(from: expirationDate)
                // Check if there's a pending offer code - promo activates after trial ends
                if hasPendingOfferCode {
                    return String(localized: "Trial ends \(formattedDate) • Promo next")
                }
                return String(localized: "Trial ends \(formattedDate)")
            }
            if hasPendingOfferCode {
                return String(localized: "Free trial • Promo code applied")
            }
            return String(localized: "Free trial active")
        }

        return nil
    }

    /// Reset the expired flag (call after user acknowledges)
    func acknowledgeExpiry() {
        subscriptionJustExpired = false
    }

    func formatExpirationDate(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    var shouldShowRenewalWarning: Bool {
        guard isSubscribed else { return false }

        if !willAutoRenew {
            return true
        }

        if isInTrialPeriod {
            if let expirationDate = subscriptionExpirationDate {
                let daysUntilExpiry = Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
                return daysUntilExpiry <= 3
            }
        }

        return false
    }

    var isAccessAtRisk: Bool {
        guard isSubscribed else { return false }

        if !willAutoRenew {
            if let expirationDate = subscriptionExpirationDate {
                let daysUntilExpiry = Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
                return daysUntilExpiry <= 7
            }
            return true
        }

        return false
    }

    // MARK: - Debug Methods

    #if DEBUG
    func grantSubscription() {
        // For testing: grant a 1-hour subscription
        subscriptionExpirationDate = Date().addingTimeInterval(3600)
        storedProductID = "debug.subscription"
        isSubscribed = true
    }

    func revokeSubscription() {
        subscriptionExpirationDate = nil
        storedProductID = nil
        isSubscribed = false
    }

    /// Configure subscription state for SwiftUI previews
    func configureForPreview(
        subscribed: Bool = false,
        lifetime: Bool = false,
        trial: Bool = false,
        autoRenew: Bool = true,
        offerCode: Bool = false,
        pendingOfferCode: Bool = false,
        pendingPlanProductID: String? = nil,
        expiration: Date? = nil,
        productID: String? = nil
    ) {
        isPreviewMode = true
        isInitializing = true
        isSubscribed = subscribed
        isLifetimeUser = lifetime
        isInTrialPeriod = trial
        willAutoRenew = autoRenew
        hasRedeemedOfferCode = offerCode
        hasPendingOfferCode = pendingOfferCode
        self.pendingPlanProductID = pendingPlanProductID
        subscriptionExpirationDate = expiration
        isInitializing = false

        // Also configure StoreKitManager so PricingCard can resolve the Product
        let storeManager = StoreKitManager.shared
        storeManager.isPreviewMode = true
        storeManager.currentProductID = productID
        storeManager.isInTrialPeriod = trial
        storeManager.willAutoRenew = autoRenew
        storeManager.subscriptionExpirationDate = expiration
        storeManager.hasRedeemedOfferCode = offerCode
        storeManager.hasPendingOfferCode = pendingOfferCode
        storeManager.pendingPlanProductID = pendingPlanProductID
        storeManager.hasLifetimePurchase = lifetime
        if subscribed {
            storeManager.purchasedProductIDs = productID.map { Set([$0]) } ?? []
        }
    }

    /// Ensure StoreKit products are loaded for previews
    func loadProductsForPreview() async {
        await StoreKitManager.shared.loadProducts()
    }
    #endif

    // MARK: - Joodle Access Helpers (Synchronous - uses cached state)

    func totalJoodleCount(from entries: [DayEntry]) -> Int {
        return entries.filter { entry in
            entry.drawingData != nil
        }.count
    }

    func fetchTotalJoodleCount(in modelContext: ModelContext) -> Int {
        let descriptor = FetchDescriptor<DayEntry>(
            predicate: #Predicate { entry in
                entry.drawingData != nil
            }
        )

        do {
            let count = try modelContext.fetchCount(descriptor)
            return count
        } catch {
            print("Error fetching Joodle count: \(error)")
            return 0
        }
    }

    // MARK: - Day-Scoped Doodle Gate (additive - uses cached state)

    /// Synchronous check - uses cached subscription state
    /// For critical access points, use doodleGateWithVerification(on:existingDoodleCount:) first
    func doodleGate(on date: Date, existingDoodleCount: Int) -> DoodleGate {
        Self.resolveDoodleGate(
            on: date,
            existingDoodleCount: existingDoodleCount,
            hasPremiumAccess: hasPremiumAccess
        )
    }

    /// Async access check with online verification
    /// Use this before allowing creation of a new doodle
    func doodleGateWithVerification(on date: Date, existingDoodleCount: Int) async -> DoodleGate {
        let hasAccess = await verifySubscriptionForAccess()
        return Self.resolveDoodleGate(
            on: date,
            existingDoodleCount: existingDoodleCount,
            hasPremiumAccess: hasAccess
        )
    }

    func canDrawJoodle(on date: Date, existingDoodleCount: Int) -> Bool {
        doodleGate(on: date, existingDoodleCount: existingDoodleCount) == .allowed
    }

    /// Backfilling/rescheduling a doodle to a different day is a Pro-only move.
    func canMoveJoodle() -> Bool {
        hasPremiumAccess
    }
}
