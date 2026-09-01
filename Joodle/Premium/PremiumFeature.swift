//
//  PremiumFeature.swift
//  Joodle
//
//  Created by Premium Feature System
//

import Foundation
import SwiftUI
import Combine

// MARK: - Premium Feature Definition

/// All premium features in Joodle.
/// Add new features here - they will automatically be gated.
enum PremiumFeature: String, CaseIterable, Identifiable {
    case unlimitedJoodles
    case widgets  // Free users have NO widget access
    case allShareTemplates

    var id: String { rawValue }

    // MARK: - Feature Metadata

    var name: LocalizedStringResource {
        switch self {
        case .unlimitedJoodles:
            return "Unlimited Joodles"
        case .widgets:
            return "All Widgets"
        case .allShareTemplates:
            return "All Share Templates"
        }
    }

    var description: LocalizedStringResource {
        switch self {
        case .unlimitedJoodles:
            return "Draw as much as you want, no limits"
        case .widgets:
            return "Access to all Joodle widgets"
        case .allShareTemplates:
            return "Beautiful templates for sharing"
        }
    }

    var icon: String {
        switch self {
        case .unlimitedJoodles:
            return "scribble.variable"
        case .widgets:
            return "square.grid.3x3.fill"
        case .allShareTemplates:
            return "square.and.arrow.up.fill"
        }
    }

    /// Check if this feature is currently available
    /// Note: Must be called from MainActor context
    @MainActor
    var isAvailable: Bool {
        SubscriptionManager.shared.hasPremiumAccess
    }
}

// MARK: - Premium Access Controller

/// Central controller for premium feature access.
/// Use this to check and gate premium features throughout the app.
@MainActor
final class PremiumAccessController: ObservableObject {
    static let shared = PremiumAccessController()

    @Published private(set) var hasPremiumAccess: Bool = false
    @Published private(set) var subscriptionExpired: Bool = false

    private var cancellables = Set<AnyCancellable>()

    /// Last time we refreshed from StoreKit to avoid excessive calls
    private var lastRefreshTime: Date?

    /// Minimum interval between StoreKit refreshes (in seconds)
    private let refreshInterval: TimeInterval = 30

    private init() {
        // Observe subscription manager changes
        SubscriptionManager.shared.$isSubscribed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let newValue = SubscriptionManager.shared.hasPremiumAccess
                let wasSubscribed = self?.hasPremiumAccess ?? false
                self?.hasPremiumAccess = newValue

                // Detect subscription expiry (only if grace period also expired)
                if wasSubscribed && !newValue {
                    self?.handleSubscriptionExpired()
                }
            }
            .store(in: &cancellables)

        // Also observe grace period changes
        GracePeriodManager.shared.$isInGracePeriod
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let newValue = SubscriptionManager.shared.hasPremiumAccess
                let wasSubscribed = self?.hasPremiumAccess ?? false
                self?.hasPremiumAccess = newValue

                if wasSubscribed && !newValue {
                    self?.handleSubscriptionExpired()
                }
            }
            .store(in: &cancellables)

        // Initial state
        hasPremiumAccess = SubscriptionManager.shared.hasPremiumAccess
    }

    // MARK: - Feature Access Checks

    /// Check if a feature is accessible (synchronous, uses cached state)
    /// For critical access points, prefer `checkAccessWithRefresh` instead
    func canAccess(_ feature: PremiumFeature) -> Bool {
        // Trigger background refresh when checking premium features
        triggerBackgroundRefreshIfNeeded()
        return hasPremiumAccess
    }

    /// Check if a feature is accessible after refreshing from StoreKit first
    /// Use this for critical access points where you need the latest subscription status
    func checkAccessWithRefresh(_ feature: PremiumFeature) async -> Bool {
        // Refresh from StoreKit first to get the latest status
        await refreshSubscriptionStatus()
        return hasPremiumAccess
    }

    /// Triggers a background StoreKit refresh if enough time has passed since the last refresh
    private func triggerBackgroundRefreshIfNeeded() {
        // Trigger background refresh (rate limiting is handled in refreshSubscriptionStatus)
        Task {
            await refreshSubscriptionStatus()
        }
    }

    // MARK: - Subscription Expiry Handling

    private func handleSubscriptionExpired() {
        subscriptionExpired = true

        // Post notification for app-wide handling
        NotificationCenter.default.post(
            name: .subscriptionDidExpire,
            object: nil
        )

        // Reset all premium features to free tier defaults
        // (theme color, watermark, widget status, etc.)
        SubscriptionManager.shared.resetPremiumFeaturesToDefaults()

        // Disable iCloud sync if it was enabled
        if UserPreferences.shared.isCloudSyncEnabled {
            UserPreferences.shared.isCloudSyncEnabled = false
            // Note: ModelContainerManager.needsRestartForSyncChange will be checked by UI
        }
    }

    /// Reset the expired flag (call after user acknowledges)
    func acknowledgeExpiry() {
        subscriptionExpired = false
    }

    /// Refresh subscription status from StoreKit (rate-limited)
    func refreshSubscriptionStatus() async {
        let now = Date()

        // Check if we should refresh (rate limiting)
        if let lastRefresh = lastRefreshTime {
            guard now.timeIntervalSince(lastRefresh) >= refreshInterval else {
                return
            }
        }

        // Update last refresh time immediately to prevent duplicate calls
        lastRefreshTime = now

        await SubscriptionManager.shared.refreshSubscriptionFromStoreKit()
    }

    /// Force an immediate refresh from StoreKit, bypassing rate limiting
    func forceRefresh() async {
        lastRefreshTime = Date()
        await SubscriptionManager.shared.refreshSubscriptionFromStoreKit()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let subscriptionDidExpire = Notification.Name("subscriptionDidExpire")
    static let subscriptionDidActivate = Notification.Name("subscriptionDidActivate")
    static let premiumFeatureAccessed = Notification.Name("premiumFeatureAccessed")
}

// MARK: - View Modifiers for Premium Gating

/// Modifier that shows a paywall when tapping a locked feature
struct PremiumGatedModifier: ViewModifier {
    let feature: PremiumFeature
    @Binding var showPaywall: Bool
    @ObservedObject private var accessController = PremiumAccessController.shared
    @State private var isChecking = false

    let onAccessGranted: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                // Prevent multiple taps while checking
                guard !isChecking else { return }
                isChecking = true

                // Verify subscription with online check before granting access
                Task {
                    let hasAccess = await SubscriptionManager.shared.verifySubscriptionForAccess()
                    await MainActor.run {
                        isChecking = false
                        if hasAccess {
                            onAccessGranted?()
                        } else {
                            showPaywall = true
                        }
                    }
                }
            }
    }
}

/// Modifier that overlays a lock on premium content
struct PremiumLockedOverlayModifier: ViewModifier {
    let feature: PremiumFeature
    @ObservedObject private var accessController = PremiumAccessController.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if !accessController.canAccess(feature) {
                    ZStack {
                        Color.black.opacity(0.3)

                        VStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .font(.appTitle())
                                .foregroundColor(.appAccentContrast)

                            Text("Joodle Pro")
                                .font(.appCaption(weight: .bold))
                                .foregroundColor(.appAccentContrast)
                        }
                    }
                }
            }
    }
}

// MARK: - View Extensions

extension View {
    /// Gates a view behind premium - shows paywall if not subscribed
    func requiresPremium(
        _ feature: PremiumFeature,
        showPaywall: Binding<Bool>,
        onAccessGranted: (() -> Void)? = nil
    ) -> some View {
        self.modifier(PremiumGatedModifier(
            feature: feature,
            showPaywall: showPaywall,
            onAccessGranted: onAccessGranted
        ))
    }

    /// Overlays a lock on content if not subscribed
    func premiumLocked(_ feature: PremiumFeature) -> some View {
        self.modifier(PremiumLockedOverlayModifier(feature: feature))
    }

    /// Shows a premium badge on the view
    func withPremiumBadge(_ feature: PremiumFeature, show: Bool = true) -> some View {
        self.overlay(alignment: .topTrailing) {
            if show && !PremiumAccessController.shared.hasPremiumAccess {
                PremiumFeatureBadge()
                    .offset(x: 4, y: -4)
            }
        }
    }
}

// MARK: - Premium UI Components

/// Small badge indicating a premium feature
struct PremiumFeatureBadge: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "crown.fill")
                .font(.appFont(size: 8))
            Text("PRO")
                .font(.appFont(size: 7, weight: .bold))
        }
        .foregroundColor(.appAccentContrast)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                      colors: [.appAccent.opacity(0.5), .appAccent],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
    }
}

/// Button that gates action behind premium
struct PremiumGatedButton<Label: View>: View {
    let feature: PremiumFeature
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var showPaywall = false
    @State private var isChecking = false
    @ObservedObject private var accessController = PremiumAccessController.shared

    var body: some View {
        Button {
            // Prevent multiple taps while checking
            guard !isChecking else { return }
            isChecking = true

            // Verify subscription with online check before granting access
            Task {
                let hasAccess = await SubscriptionManager.shared.verifySubscriptionForAccess()
                await MainActor.run {
                    isChecking = false
                    if hasAccess {
                        action()
                    } else {
                        showPaywall = true
                    }
                }
            }
        } label: {
            label()
                .overlay(alignment: .topTrailing) {
                    if !accessController.hasPremiumAccess {
                        Image(systemName: "lock.fill")
                            .font(.appCaption2())
                            .foregroundColor(.secondary)
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .sheet(isPresented: $showPaywall) {
            StandalonePaywallView(source: "premium_gate")
        }
    }
}

/// Alert shown when subscription expires
struct SubscriptionExpiredAlert: ViewModifier {
    @ObservedObject private var accessController = PremiumAccessController.shared
    @State private var showAlert = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .subscriptionDidExpire)) { _ in
                showAlert = true
            }
            .alert("Subscription Ended", isPresented: $showAlert) {
                Button("OK") {
                    accessController.acknowledgeExpiry()
                }
                Button("Resubscribe") {
                    accessController.acknowledgeExpiry()
                    // The calling view should handle showing paywall
                    NotificationCenter.default.post(
                        name: .premiumFeatureAccessed,
                        object: nil
                    )
                }
            } message: {
                Text("Your Joodle Pro subscription has ended. Some features are now limited.")
            }
    }
}

extension View {
    /// Adds subscription expiry alert handling to a view
    func handlesSubscriptionExpiry() -> some View {
        self.modifier(SubscriptionExpiredAlert())
    }
}

// MARK: - Preview

#Preview("Premium Badge") {
    VStack(spacing: 20) {
        Text("Feature")
            .padding()
            .background(Color.blue)
            .withPremiumBadge(.allShareTemplates)

        PremiumFeatureBadge()
    }
}
