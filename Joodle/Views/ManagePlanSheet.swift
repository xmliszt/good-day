//
//  ManagePlanSheet.swift
//  Joodle
//
//  Created by Manage Plan Sheet
//

import SwiftUI
import StoreKit

/// A custom sheet that displays plan switching options (monthly, yearly, lifetime)
/// before optionally navigating to Apple's native subscription manager.
/// This is needed because lifetime is a one-time purchase (non-consumable)
/// and won't appear in Apple's native manage subscriptions sheet.
struct ManagePlanSheet: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var storeManager = StoreKitManager.shared
  @StateObject private var subscriptionManager = SubscriptionManager.shared

  @State private var isPurchasing = false
  @State private var showNativeManagement = false
  @State private var errorMessage: String?
  @State private var showError = false
  /// Set when a purchase made here turned a non-Pro user Pro, flipping the sheet
  /// to the celebration. This sheet doubles as "View All Plans" for users who
  /// aren't subscribed yet, so it is a real acquisition surface — but a plain
  /// plan switch by someone already Pro leaves this nil, since "You're Pro!"
  /// would be telling them something they already know.
  @State private var celebration: PurchaseCelebration?

  private enum PurchaseCelebration {
    case subscription
    case lifetime
  }

  var body: some View {
    if let celebration {
      ProCelebrationView(
        message: "Unlimited doodles, every widget, and every exclusive feature — thank you for backing Joodle!",
        badge: celebration == .lifetime ? Text("Lifetime access") : nil,
        onContinue: { dismiss() }
      )
      .preferredColorScheme(.dark)
    } else {
      planSwitcher
    }
  }

  private var planSwitcher: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          // Header
          headerSection

          // Plan options
          planOptionsSection

          // Manage or cancel via Apple
          if subscriptionManager.isSubscribed && !subscriptionManager.isLifetimeUser {
            nativeManagementButton
          }

          // Disclaimer
          disclaimerText
        }
        .padding(20)
        .padding(.bottom, 20)
      }
      .navigationTitle(String(localized: "Switch Plan"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(String(localized: "Done")) { dismiss() }
            .font(.appBody())
        }
      }
      .manageSubscriptionsSheet(isPresented: $showNativeManagement)
      .alert(String(localized: "Purchase Failed"), isPresented: $showError) {
        Button(String(localized: "OK"), role: .cancel) {}
      } message: {
        Text(errorMessage ?? String(localized: "An unexpected error occurred."))
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(spacing: 8) {
      Text(String(localized: "Choose Your Plan"))
        .font(.appFont(size: 22, weight: .bold))

      if let currentProduct = storeManager.currentProduct {
        Text(String(localized: "Currently on \(currentProduct.displayName)"))
          .font(.appCaption())
          .foregroundColor(.secondary)
      } else if !subscriptionManager.isSubscribed {
        Text(String(localized: "Select a plan to get started"))
          .font(.appCaption())
          .foregroundColor(.secondary)
      }
    }
    .padding(.top, 4)
  }

  // MARK: - Plan Options

  private var planOptionsSection: some View {
    VStack(spacing: 12) {
      // Lifetime option — highlighted
      if let lifetime = storeManager.lifetimeProduct {
        planOptionRow(
          product: lifetime,
          icon: "infinity",
          subtitle: String(localized: "One-time purchase, yours forever"),
          badge: String(localized: "BEST VALUE"),
          isCurrent: subscriptionManager.isLifetimeUser
        )
      }

      // Yearly option
      if let yearly = storeManager.yearlyProduct {
        planOptionRow(
          product: yearly,
          icon: "repeat",
          subtitle: yearlySavingsSubtitle(),
          badge: savingsBadgeText(),
          isCurrent: storeManager.currentProductID == yearly.id,
          isDisabled: subscriptionManager.isLifetimeUser
        )
      }

      // Monthly option
      if let monthly = storeManager.monthlyProduct {
        planOptionRow(
          product: monthly,
          icon: "repeat",
          subtitle: String(localized: "Billed monthly"),
          badge: nil,
          isCurrent: storeManager.currentProductID == monthly.id,
          isDisabled: subscriptionManager.isLifetimeUser
        )
      }
    }
  }

  // MARK: - Plan Option Row

  private func planOptionRow(
    product: Product,
    icon: String,
    subtitle: String,
    badge: String?,
    isCurrent: Bool,
    isDisabled: Bool = false
  ) -> some View {
    Button {
      if isCurrent || isDisabled {
        return
      }
      handlePlanSelection(product)
    } label: {
      ZStack(alignment: .topTrailing) {
        HStack(spacing: 14) {
          // Icon
          Image(systemName: icon)
            .font(.appFont(size: 20))
            .foregroundStyle(isCurrent ? .appAccent : .primary)
            .frame(width: 36, height: 36)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCurrent ? .appAccent.opacity(0.15) : .appBorder.opacity(0.3))
            )

          // Title + subtitle
          VStack(alignment: .leading, spacing: 3) {
            Text(product.displayName)
              .font(.appBody(weight: .medium))
              .foregroundColor(.primary)

            Text(subtitle)
              .font(.appCaption2())
              .foregroundColor(.secondary)
          }

          Spacer()

          // Price or "Current" label
          if isCurrent {
            Text(String(localized: "Current"))
              .font(.appCaption(weight: .medium))
              .foregroundColor(.appAccent)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(
                Capsule()
                  .fill(.appAccent.opacity(0.12))
              )
          } else {
            VStack(alignment: .trailing, spacing: 2) {
              Text(product.displayPrice)
                .font(.appBody(weight: .semibold))
                .foregroundColor(.primary)

              if let period = periodLabel(for: product) {
                Text(period)
                  .font(.appCaption2())
                  .foregroundColor(.secondary)
              }
            }
          }
        }
        .padding(16)
        .background(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.appBorder.opacity(0.3))
            .overlay(
              RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isCurrent ? .appAccent : .clear, lineWidth: 1.5)
            )
        )

        // Badge
        if let badge = badge, !isCurrent, !isDisabled {
          Text(badge)
            .font(.appCaption2(weight: .bold))
            .foregroundColor(.appAccentContrast)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
              Capsule()
                .fill(.appAccent)
            )
            .offset(x: -8, y: -10)
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(isPurchasing || isDisabled)
    .opacity(isDisabled ? 0.4 : (isPurchasing && !isCurrent ? 0.6 : 1.0))
  }

  // MARK: - Native Management Button

  private var nativeManagementButton: some View {
    Button {
      showNativeManagement = true
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "arrow.up.right.square")
          .font(.appCaption())
        Text(String(localized: "Manage or Cancel via App Store"))
          .font(.appCaption())
      }
      .foregroundColor(.secondary)
      .frame(maxWidth: .infinity)
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(.appBorder.opacity(0.2))
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Disclaimer

  private var disclaimerText: some View {
    Group {
      if subscriptionManager.isSubscribed && !subscriptionManager.isLifetimeUser {
        Text(String(localized: "Switching between subscription plans is handled by the App Store. Tap a new plan to purchase it, or use \"Manage or Cancel via App Store\" to change or cancel your current subscription."))
      } else {
        Text(String(localized: "You already own Joodle forever. There is no need to purchase subscription plans."))
      }
    }
    .font(.appCaption2())
    .foregroundColor(.secondary)
    .multilineTextAlignment(.center)
    .padding(.horizontal, 8)
  }

  // MARK: - Helpers

  private func periodLabel(for product: Product) -> String? {
    if product.id.contains("lifetime") {
      return String(localized: "one-time")
    } else if product.id.contains("yearly") {
      return String(localized: "/ year")
    } else if product.id.contains("monthly") {
      return String(localized: "/ month")
    }
    return nil
  }

  private func yearlySavingsSubtitle() -> String {
    if let percentage = storeManager.savingsPercentage() {
      let formatted = (Double(percentage) / 100).formatted(.percent)
      return String(localized: "Save \(formatted) vs monthly")
    }
    return String(localized: "Billed annually")
  }

  private func savingsBadgeText() -> String? {
    guard let percentage = storeManager.savingsPercentage() else { return nil }
    let formatted = (Double(percentage) / 100).formatted(.percent)
    return String(localized: "SAVE \(formatted)")
  }

  // MARK: - Purchase Logic

  private func handlePlanSelection(_ product: Product) {
    // Captured before the purchase: afterwards the entitlement says Pro either
    // way, and only someone who wasn't Pro a moment ago has something to
    // celebrate.
    let wasSubscribed = subscriptionManager.isSubscribed
    isPurchasing = true

    Task {
      do {
        let transaction = try await storeManager.purchase(product, paywallSource: "manage_plan")

        if transaction != nil {
          await subscriptionManager.updateSubscriptionStatus()
          await MainActor.run {
            isPurchasing = false
            guard !wasSubscribed else {
              // A plan switch — nothing to congratulate, just close.
              dismiss()
              return
            }
            Haptic.play(with: .medium)
            celebration = JoodleProducts.lifetimeIDs.contains(product.id) ? .lifetime : .subscription
          }
        } else {
          // Transaction nil — user cancelled or pending
          await MainActor.run {
            isPurchasing = false
          }
        }
      } catch {
        await MainActor.run {
          isPurchasing = false

          if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .userCancelled:
              break // Don't show error for cancellation
            case .networkError:
              errorMessage = String(localized: "Network error. Please check your internet connection and try again.")
              showError = true
            default:
              errorMessage = String(localized: "Purchase failed: \(error.localizedDescription)")
              showError = true
            }
          } else {
            errorMessage = String(localized: "Purchase failed: \(error.localizedDescription)")
            showError = true
          }
        }
      }
    }
  }
}

#if DEBUG
#Preview("Active Monthly Sub") {
  Text(String(localized: "Preview"))
    .sheet(isPresented: .constant(true)) {
      ManagePlanSheet()
        .task {
          SubscriptionManager.shared.configureForPreview(
            subscribed: true,
            autoRenew: true,
            expiration: Date().addingTimeInterval(60 * 60 * 24 * 30),
            productID: "dev.liyuxuan.joodle.pro.monthly"
          )
          await SubscriptionManager.shared.loadProductsForPreview()
        }
    }
}

#Preview("Active Yearly Sub") {
  Text(String(localized: "Preview"))
    .sheet(isPresented: .constant(true)) {
      ManagePlanSheet()
        .task {
          SubscriptionManager.shared.configureForPreview(
            subscribed: true,
            autoRenew: true,
            expiration: Date().addingTimeInterval(60 * 60 * 24 * 365),
            productID: "dev.liyuxuan.joodle.pro.yearly"
          )
          await SubscriptionManager.shared.loadProductsForPreview()
        }
    }
}

#Preview("Cancelled Sub") {
  Text(String(localized: "Preview"))
    .sheet(isPresented: .constant(true)) {
      ManagePlanSheet()
        .task {
          SubscriptionManager.shared.configureForPreview(
            subscribed: true,
            autoRenew: false,
            expiration: Date().addingTimeInterval(60 * 60 * 24 * 5),
            productID: "dev.liyuxuan.joodle.pro.yearly"
          )
          await SubscriptionManager.shared.loadProductsForPreview()
        }
    }
}
#endif
