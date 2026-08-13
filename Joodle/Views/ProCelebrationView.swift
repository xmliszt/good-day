//
//  ProCelebrationView.swift
//  Joodle
//
//  The shared "You're Pro!" moment: confetti, the shimmering crown, and a single
//  way onward. Extracted from the trial-claim paywall so becoming Pro looks the
//  same however it happened — claimed trial, onboarding purchase, any of the
//  standalone paywall's entry points, or "View All Plans" in Settings. A purchase
//  used to land the user back where they started with no acknowledgement at all.
//

import ConfettiSwiftUI
import SwiftUI

struct ProCelebrationView: View {
  /// Sub-headline under the title. Differs by route: a claimed trial talks in
  /// days, a purchase says thank you.
  let message: LocalizedStringResource
  /// Optional pill under the message — the trial's end date, or lifetime
  /// ownership. A `Text` rather than a string so callers can interpolate a
  /// formatted date into it; nil leaves the pill out entirely.
  var badge: Text?
  let onContinue: () -> Void

  @State private var confettiTrigger = 0

  var body: some View {
    VStack(spacing: 0) {
      Spacer()

      GlossyCrownView(isSubscribed: true)

      VStack(spacing: 12) {
        Text("You're Pro!")
          .font(.appFont(size: 40, weight: .bold))
          .multilineTextAlignment(.center)

        Text(message)
          .font(.appSubheadline())
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 32)
      .padding(.top, 24)

      if let badge {
        HStack(spacing: 6) {
          Image(systemName: "crown.fill")
            .font(.appFont(size: 12))
          badge
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

      Button(action: onContinue) {
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
    .confettiCannon(
      trigger: $confettiTrigger,
      num: 60,
      colors: [.appAccent, .yellow, .orange, .pink, .mint],
      confettiSize: 12,
      radius: 420
    )
    // Fired from here rather than by the caller, so every route that lands on
    // this screen gets the confetti without having to remember to ask for it.
    .onAppear { confettiTrigger += 1 }
  }
}

#if DEBUG
#Preview("Purchased — lifetime") {
  ProCelebrationView(
    message: "Unlimited doodles, every widget, and every exclusive feature — thank you for backing Joodle!",
    badge: Text("Lifetime access"),
    onContinue: {}
  )
  .preferredColorScheme(.dark)
}

#Preview("Purchased — subscription") {
  ProCelebrationView(
    message: "Unlimited doodles, every widget, and every exclusive feature — thank you for backing Joodle!",
    onContinue: {}
  )
  .preferredColorScheme(.dark)
}
#endif
