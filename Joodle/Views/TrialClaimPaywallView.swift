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
//  Claiming transitions in-place to a confetti + shimmering-crown celebration.
//

import ConfettiSwiftUI
import SwiftUI

struct TrialClaimPaywallView: View {
  let source: String

  @Environment(\.dismiss) private var dismiss
  @StateObject private var trialOfferManager = TrialOfferManager.shared
  @StateObject private var gracePeriodManager = GracePeriodManager.shared

  /// Flips the view from offer to celebration once the claim lands.
  @State private var claimed = false
  @State private var confettiTrigger = 0

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
    .confettiCannon(
      trigger: $confettiTrigger,
      num: 60,
      colors: [.appAccent, .yellow, .orange, .pink, .mint],
      confettiSize: 12,
      radius: 420
    )
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
    VStack(spacing: 0) {
      Spacer()

      GlossyCrownView(isSubscribed: true)

      VStack(spacing: 12) {
        Text("You're Pro!")
          .font(.appFont(size: 40, weight: .bold))
          .multilineTextAlignment(.center)

        Text("7 days of unlimited doodles, every widget, and many more exclusive features, start right now!")
          .font(.appSubheadline())
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 32)
      .padding(.top, 24)

      if let until = gracePeriodManager.gracePeriodExpirationDate {
        HStack(spacing: 6) {
          Image(systemName: "crown.fill")
            .font(.appFont(size: 12))
          Text("Pro until \(until, format: .dateTime.day().month())")
            .font(.appCaption(weight: .bold))
        }
        .foregroundColor(.appAccent)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
          Capsule()
            .fill(Color.appAccent.opacity(0.12))
            .overlay(Capsule().strokeBorder(Color.appAccent.opacity(0.45), lineWidth: 1))
        )
        .padding(.top, 20)
      }

      Spacer()

      Button {
        dismiss()
      } label: {
        Text("Start doodling")
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
      .padding(.horizontal, 24)
      .padding(.bottom, 24)
    }
  }

  private func claim() {
    guard !claimed else { return }
    trialOfferManager.claimTrial(source: source)
    Haptic.play(with: .medium)
    claimed = true
    confettiTrigger += 1
  }
}

#if DEBUG
#Preview("Offer") {
  TrialClaimPaywallView(source: "preview")
}
#endif
