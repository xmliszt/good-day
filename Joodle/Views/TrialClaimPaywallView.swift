//
//  TrialClaimPaywallView.swift
//  Joodle
//
//  The "7 days on us" claim paywall. Shown once the free doodle allowance is
//  used up (or as a winback for legacy installs), reopened from the Settings
//  claim banner and the canvas limit gate while the claim window runs.
//
//  This surface sells a gift, not a purchase: no StoreKit, no pricing cards,
//  a single low-friction Claim button, and copy that explicitly separates
//  this trial from an App Store free trial (no card, no auto-charge).
//  Claiming transitions in-place to the shared `ProCelebrationView` — confetti
//  plus shimmering crown — which a completed purchase now lands on too.
//

import SwiftUI

struct TrialClaimPaywallView: View {
  let source: String

  @Environment(\.dismiss) private var dismiss
  @StateObject private var trialOfferManager = TrialOfferManager.shared
  @StateObject private var gracePeriodManager = GracePeriodManager.shared

  /// Flips the view from offer to celebration once the claim lands.
  @State private var claimed = false

  var body: some View {
    ZStack {
      if claimed {
        celebration
          .transition(.opacity.combined(with: .scale(scale: 0.92)))
      } else {
        offer
          .transition(.opacity)
      }
    }
    .animation(.springFkingSatifying, value: claimed)
    .presentationDragIndicator(.visible)
    // Same committed dark, premium look as every other paywall surface.
    .preferredColorScheme(.dark)
    .postHogScreenView("Trial Claim Paywall")
    .onAppear {
      AnalyticsManager.shared.track(.trialOfferShown, properties: [.source: source])
    }
    .onDisappear {
      // Centralized here so every presenter (home auto-present, Settings
      // banner, canvas gate) gets identical dismissal semantics: the first
      // un-claimed dismissal starts the claim-window countdown; a dismissal
      // after claiming is a no-op inside the manager.
      trialOfferManager.handleClaimSheetDismissed(source: source)
    }
  }

  // MARK: - Offer

  private var offer: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 24) {
          GlossyCrownView(isSubscribed: true)
            .padding(.top, 36)

          VStack(spacing: 12) {
            Text("Want to keep doodling?")
              .font(.appFont(size: 34, weight: .bold))
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)

            Text("The next 7 days of Joodle Pro are on us — unlimited doodles, every widget, everything.")
              .font(.appSubheadline())
              .foregroundColor(.secondary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.horizontal, 28)

          // Countdown appears once the window is running (reopened from the
          // banner) — the urgency is real; claiming stops it for good.
          if case .claimWindow(let end) = trialOfferManager.phase {
            VStack(spacing: 10) {
              Text("Offer ends in")
                .font(.appCaption(weight: .medium))
                .foregroundColor(.secondary)
              CountdownTimerView(endDate: end, style: .pills)
            }
          }

          checklistCard
            .padding(.horizontal, 24)

          Text("This is not an App Store free trial. We simply switch Pro on for you. When it ends, you're back on Free automatically — nothing is charged.")
            .font(.appCaption())
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
      }

      VStack(spacing: 12) {
        Button {
          claim()
        } label: {
          Text("Claim my 7-day free trial")
            .font(.appHeadline())
            .foregroundColor(.appAccentContrast)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
              Capsule().fill(
                LinearGradient(
                  colors: [.appAccent.opacity(0.75), .appAccent],
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )
            )
        }

        Button {
          dismiss()
        } label: {
          Text("Maybe later")
            .font(.appSubheadline())
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
        }
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 16)
    }
  }

  private var checklistCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      checklistRow("No credit card")
      checklistRow("No subscription started")
      checklistRow("Nothing to cancel")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.appAccent.opacity(0.10))
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.appAccent.opacity(0.4), lineWidth: 1)
        )
    )
  }

  private func checklistRow(_ text: LocalizedStringResource) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "checkmark.circle.fill")
        .font(.appFont(size: 18))
        .foregroundColor(.appAccent)
      Text(text)
        .font(.appBody(weight: .medium))
        .foregroundColor(.primary)
    }
  }

  // MARK: - Celebration

  private var celebration: some View {
    ProCelebrationView(
      message: "7 days of unlimited doodles, every widget, and many more exclusive features, start right now!",
      badge: gracePeriodManager.gracePeriodExpirationDate.map {
        Text("Pro until \($0, format: .dateTime.day().month())")
      },
      onContinue: { dismiss() }
    )
  }

  private func claim() {
    guard !claimed else { return }
    trialOfferManager.claimTrial(source: source)
    Haptic.play(with: .medium)
    claimed = true
  }
}

#if DEBUG
#Preview("Offer") {
  TrialClaimPaywallView(source: "preview")
}
#endif
