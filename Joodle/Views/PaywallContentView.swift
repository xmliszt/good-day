//
//  PaywallContentView.swift
//  Joodle
//
//  Shared paywall content component used by StandalonePaywallView
//

import SwiftUI
import StoreKit

// MARK: - Configuration

/// The surface a paywall is being shown in. Drives which sections render.
enum PaywallContext: Equatable {
  /// Purchasable paywall at the end of onboarding: value + comparison + plans,
  /// with a muted "Skip" in the navigation bar's trailing slot, level with the
  /// back button. No trial framing here — the claimable 7-day trial is only
  /// offered later, at the free doodle limit.
  case onboarding
  /// Shown mid-trial from the Settings banner. Timeline reflects `daysLeft`; offers optional early upgrade.
  case trialStatus(daysLeft: Int)
  /// The generic pay screen: Free-vs-Pro comparison + plans.
  case expired
  /// Limited-time offer surface: countdown header + discounted plans. Driven by
  /// `LimitedTimeOfferManager`; presented as a sheet and from the Settings banner.
  case limitedTimeOffer
  /// Post-trial bottom sheet on next app open: loss-framed header + comparison
  /// + plans, quoting the 50%-off lifetime window while it's live.
  /// `offerExpired` distinguishes "your trial ended" from "you never claimed it".
  case trialEnded(offerExpired: Bool)
}

/// Configuration for PaywallContentView behavior and appearance
struct PaywallConfiguration {
  /// The surface this paywall is shown in. Determines section composition.
  var context: PaywallContext = .expired

  /// Whether to use onboarding-style buttons
  var useOnboardingStyle: Bool = false

  /// The source/trigger that caused this paywall to be shown (for analytics attribution)
  var paywallSource: String = "unknown"

  /// Called when a purchase is completed successfully
  var onPurchaseComplete: (() -> Void)?

  /// Called when user chooses to continue with free version
  var onContinueFree: (() -> Void)?

  /// Called when restore is successful and user has active subscription
  var onRestoreComplete: (() -> Void)?
}

// MARK: - SliderCTAButton

/// A slide-to-unlock style CTA button with mode toggle
struct SliderCTAButton: View {
  /// Whether the slider is in "Pro" mode (true) or "Free" mode (false)
  @Binding var isProMode: Bool

  /// Whether the user can toggle between modes by tapping the thumb
  let allowModeToggle: Bool

  /// Whether the button is in a loading state
  let isLoading: Bool

  /// Optional trial period text to display (e.g., "7-Day", "1-Month", "3-Month")
  let trialPeriodText: String?

  /// Custom text to show when there's no trial (defaults to "Subscribe to Joodle Pro")
  let fallbackButtonText: String

  /// Called when the user completes the slide action
  let onSlideComplete: () -> Void

  @State private var dragOffset: CGFloat = 0
  @State private var isDragging = false
  @State private var shimmerOffset: CGFloat = -200

  @Namespace private var thumbNamespace

  private let thumbSize: CGFloat = 60
  private let trackHeight: CGFloat = 56
  private var trackPadding: CGFloat {
    (trackHeight - thumbSize) / 2
  }

  var body: some View {
    GeometryReader { geometry in
      let maxOffset = geometry.size.width - thumbSize - (trackPadding * 2)

      ZStack(alignment: .leading) {
        // Track background (clipped separately)
        trackBackground
          .clipShape(Capsule())

        // Green progress overlay on the left of thumb
        progressOverlay(maxOffset: maxOffset, trackWidth: geometry.size.width)

        // Label
        trackLabel(maxWidth: geometry.size.width)

        // Thumb (not clipped, sits on top)
        thumb(maxOffset: maxOffset)
      }
      .frame(height: trackHeight)
    }
    .frame(height: trackHeight)
  }

  // MARK: - Progress Overlay
  private func progressOverlay(maxOffset: CGFloat, trackWidth: CGFloat) -> some View {
    let clampedOffset = min(max(dragOffset, 0), maxOffset)
    let progressWidth = trackPadding + clampedOffset + thumbSize

    return Capsule()
      .fill(Color.appAccent.opacity(0.8))
      .frame(width: trackWidth, height: trackHeight)
      .mask(
        HStack(spacing: 0) {
          RoundedRectangle(cornerRadius: thumbSize / 2, style: .circular)
            .frame(width: max(progressWidth, 0))

          Spacer(minLength: 0)
        }
          .frame(width: trackWidth)
      )
      .animation(.springFkingSatifying, value: dragOffset)
  }

  // MARK: - Track Background
  private var trackBackground: some View {
    ZStack {
      // Base gradient/color
      if isProMode {
        LinearGradient(
          colors: [Color.appAccent.opacity(0.2), Color.appAccent.opacity(0.5)],
          startPoint: .leading,
          endPoint: .trailing
        )
      } else {
        Color.appBorder.opacity(0.5)
      }

      // Shimmer overlay
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: .white.opacity(0.2), location: 0.4),
          .init(color: .white.opacity(0.2), location: 0.6),
          .init(color: .clear, location: 1.0)
        ],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: 100)
      .offset(x: shimmerOffset)
      .onAppear {
        startShimmerAnimation()
      }

      // Inner shadow for 3D depth
      Capsule()
        .stroke(Color.black.opacity(0.15), lineWidth: 6)
        .blur(radius: 4)
        .mask(Capsule().padding(1))

      Capsule()
        .stroke(
          LinearGradient(
            colors: [Color.black.opacity(0.2), Color.clear],
            startPoint: .top,
            endPoint: .bottom
          ),
          lineWidth: 1.5
        )
    }
    .clipped()
  }

  // MARK: - Track Label

  private func trackLabel(maxWidth: CGFloat) -> some View {
    ZStack {
      if isLoading {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle())
      } else {
        Text(isProMode ? trialButtonText : "Continue for Free")
          .font(.appHeadline())
          .foregroundColor(isProMode ? .appTextPrimary : .appTextSecondary)
      }
    }
    .frame(maxWidth: maxWidth)
    .opacity(0.9)
    .animation(.easeInOut, value: isDragging)
  }

  private var trialButtonText: String {
    if let trialText = trialPeriodText {
      return "Start \(trialText) Free Trial"
    }
    return fallbackButtonText
  }

  private func startShimmerAnimation() {
    shimmerOffset = -200
    withAnimation(
      .linear(duration: 2.0)
      .repeatForever(autoreverses: false)
    ) {
      shimmerOffset = 400
    }
  }

  // MARK: - Thumb

  private func thumb(maxOffset: CGFloat) -> some View {
    Group {
      if #available(iOS 26.0, *) {
        // iOS 26+: Use glass effect
        thumbContent
          .glassEffect(.regular.interactive())
          .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
          .offset(x: trackPadding + min(max(dragOffset, 0), maxOffset))
          .simultaneousGesture(thumbDragGesture(maxOffset: maxOffset))
          .onTapGesture {
            handleThumbTap()
          }
      } else {
        // Pre-iOS 26: Standard implementation
        thumbContent
          .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
          .offset(x: trackPadding + min(max(dragOffset, 0), maxOffset))
          .gesture(thumbDragGesture(maxOffset: maxOffset))
          .onTapGesture {
            handleThumbTap()
          }
      }
    }
  }

  private var thumbContent: some View {
    Circle()
      .fill(thumbBackground)
      .frame(width: thumbSize, height: thumbSize)
      .overlay(thumbIcon)
  }

  private func handleThumbTap() {
    guard !isLoading else { return }
    guard allowModeToggle else { return }

    withAnimation(.springFkingSatifying) {
      isProMode.toggle()
    }
  }

  private func thumbDragGesture(maxOffset: CGFloat) -> some Gesture {
    DragGesture()
      .onChanged { value in
        guard !isLoading else { return }
        isDragging = true
        dragOffset = value.translation.width
      }
      .onEnded { _ in
        isDragging = false
        let threshold = maxOffset * 0.9

        if dragOffset >= threshold {
          // Play haptic feedback on confirmation
          Haptic.play(with: .medium)

          // Complete the slide
          withAnimation(.springFkingSatifying) {
            dragOffset = maxOffset
          }

          // Trigger completion after animation
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onSlideComplete()
            // Reset after action
            withAnimation(.springFkingSatifying) {
              dragOffset = 0
            }
          }
        } else {
          // Snap back
          withAnimation(.springFkingSatifying) {
            dragOffset = 0
          }
        }
      }
  }

  private var thumbBackground: some ShapeStyle {
    if isProMode {
      return AnyShapeStyle(
        LinearGradient(
          colors: [Color.appAccent.opacity(0.5), Color.appAccent],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
    } else {
      return AnyShapeStyle(Color.appTextPrimary)
    }
  }

  private var thumbIcon: some View {
    Image(systemName: isProMode ? "crown.fill" : "arrow.right")
      .font(.appFont(size: 24, weight: .semibold))
      .foregroundColor(isProMode ? .white : .appBackground)
  }
}

// MARK: - PaywallContentView

struct PaywallContentView: View {
  let configuration: PaywallConfiguration

  @StateObject private var storeManager = StoreKitManager.shared
  @StateObject private var subscriptionManager = SubscriptionManager.shared
  @StateObject private var ltoManager = LimitedTimeOfferManager.shared

  @State private var selectedProductID: String?
  @State private var isPurchasing = false
  @State private var showError = false
  @State private var errorMessage: String?
  @State private var useProMode = true
  @State private var showRedeemCode = false
  @State private var showEarlyUpgrade = false
  /// Non-nil once a purchase lands, flipping the whole surface to the
  /// celebration. Every presenter's `onPurchaseComplete` dismisses or advances
  /// immediately, so the celebration has to live here — inside the shared
  /// paywall — rather than in each of them; the callback is deferred until the
  /// user taps through it.
  @State private var celebration: PurchaseCelebration?

  /// What a completed purchase should celebrate. Recorded from the product that
  /// was just bought rather than read back off the entitlement, which cannot
  /// distinguish a fresh purchase from one restored moments earlier.
  private enum PurchaseCelebration {
    case subscription
    case lifetime
  }

  var body: some View {
    Group {
      if celebration != nil {
        celebrationScreen
          .transition(.opacity.combined(with: .scale(scale: 0.92)))
      } else {
        paywall
          .transition(.opacity)
      }
    }
    .animation(.springFkingSatifying, value: celebration != nil)
    .alert(String(localized: "Purchase Failed"), isPresented: $showError) {
      Button(String(localized: "Contact Support")) {
        openSupportEmail()
      }
      Button(String(localized: "OK"), role: .cancel) {}
    } message: {
      if let error = errorMessage {
        Text(String(localized: "\(error)\n\nIf this issue persists, please contact the developer."))
      }
    }
    .onAppear {
      handleOnAppear()
    }
    .onChange(of: storeManager.products) { _, newProducts in
      if selectedProductID == nil, !newProducts.isEmpty {
        selectedProductID = displayedLifetimeProduct?.id ?? storeManager.yearlyProduct?.id
      }
    }
    .onChange(of: ltoManager.isActive) { _, active in
      // The window can lapse while the sheet is open — hand the selection
      // back to the full-price SKU so the expired promo can't be bought.
      if !active, selectedProductID == JoodleProducts.lifetimePromo {
        selectedProductID = storeManager.lifetimeProduct?.id
      }
    }
    .offerCodeRedemption(isPresented: $showRedeemCode) { _ in
      Task {
        await storeManager.updatePurchasedProducts()
        await subscriptionManager.updateSubscriptionStatus()
        if storeManager.hasActiveSubscription {
          configuration.onRestoreComplete?()
        }
      }
    }
    // The paywall commits to a dark, premium look on every surface it appears
    // on. The live feature demos are drawn against dark — white-alpha grids,
    // glowing accent strokes, the liquid backdrop — and wash out to nothing on
    // white, so the content owns its scheme rather than inheriting the host's.
    // Written into the environment, not as `preferredColorScheme`: that is a
    // preference, and the app root already sets one for the whole window, which
    // takes precedence over anything a pushed screen asks for.
    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    .environment(\.colorScheme, .dark)
    .toolbarColorScheme(.dark, for: .navigationBar)
  }

  /// The selling surface. Unmounted wholesale once a purchase lands, which also
  /// takes the onboarding "Skip" out of the toolbar — there is nothing left to
  /// skip past at that point.
  private var paywall: some View {
    VStack(spacing: 0) {
      if case .onboarding = configuration.context {
        // The slider inside the pricing section is the single purchase CTA.
        // Skipping lives as a muted "Skip" in the navigation bar's trailing
        // slot, so it sits on the same row as the back button rather than
        // floating lower over the scroll content.
        ScrollView {
          VStack(spacing: 32) {
            headerSection
            contextBody
          }
          .frame(maxWidth: .infinity, alignment: .top)
          .padding(.bottom, 40)
        }
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            onboardingSkipButton
          }
        }
      } else {
        ScrollView {
          VStack(spacing: 32) {
            headerSection
            contextBody
          }
        }
      }
    }
  }

  // MARK: - Celebration

  /// Shown in place of the paywall once a purchase completes. The presenter's
  /// `onPurchaseComplete` — which dismisses the sheet, or advances onboarding —
  /// is held back until the user taps through, so this is what they see instead
  /// of being dropped straight back where they started.
  private var celebrationScreen: some View {
    ProCelebrationView(
      message: "Unlimited doodles, every widget, and every exclusive feature — thank you for backing Joodle!",
      badge: celebration == .lifetime ? Text("Lifetime access") : nil,
      onContinue: { configuration.onPurchaseComplete?() }
    )
  }

  // MARK: - Header Section

  private var isOnboarding: Bool {
    if case .onboarding = configuration.context { return true }
    return false
  }

  private var headerSection: some View {
    // Onboarding reads as a full step: title is left-aligned and wraps freely.
    // Other surfaces stay centered above their price cards.
    VStack(alignment: isOnboarding ? .leading : .center, spacing: 16) {
      Text(headerTitleDisplay)
        .font(.appFont(size: 34, weight: .bold))
        .multilineTextAlignment(isOnboarding ? .leading : .center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: isOnboarding ? .leading : .center)

      if let headerSubtitle {
        Text(headerSubtitle)
          .font(.appSubheadline())
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 16)
      }

      // Countdown drives the urgency and stays honest — it counts to the same
      // instant the App Store Connect price reverts and the campaign flag flips.
      // Only the offer sheet carries it in the header; regular pay surfaces
      // show it inline, next to the discounted lifetime card.
      if case .limitedTimeOffer = configuration.context, let endDate = ltoManager.endDate {
        CountdownTimerView(endDate: endDate, style: .pills)
      }
    }
    .padding(.top, 24)
    .padding(.horizontal, isOnboarding ? 24 : 8)
  }

  /// Regular pay surfaces show the countdown inline, right above the lifetime
  /// card quoting the promo price, while the window is live. The offer sheet
  /// shows it in the header instead; onboarding never qualifies (isActive
  /// gates on completed onboarding).
  private var showsInlineOfferCountdown: Bool {
    if case .limitedTimeOffer = configuration.context { return false }
    return ltoManager.isActive
  }

  private var headerTitle: LocalizedStringResource {
    switch configuration.context {
    case .onboarding:
      return "Doodle without limits"
    case .trialStatus(let daysLeft):
      return "You're on Pro — \(daysLeft) days to enjoy"
    case .expired:
      return "Keep your Joodle Pro"
    case .limitedTimeOffer:
      // Overridden in headerTitleDisplay by the runtime campaign headline.
      return "Limited Time Offer"
    case .trialEnded(let offerExpired):
      return offerExpired ? "Your free-trial offer has expired" : "Your free trial has ended"
    }
  }

  /// Loss-framed subheadline under the post-trial header; nil elsewhere.
  private var headerSubtitle: LocalizedStringResource? {
    switch configuration.context {
    case .trialEnded(let offerExpired):
      if offerExpired {
        return "Your chance to claim 7 free days of Pro has passed. But here's something better while it lasts:"
      }
      return "You're back on the Free plan — unlimited doodles, widgets and Pro extras are locked again. If you want to keep Pro, this is the best chance we'll ever offer:"
    default:
      return nil
    }
  }

  /// Resolved title with "Joodle Pro" joined by a non-breaking space so the
  /// brand never splits across lines when the title wraps.
  private var headerTitleDisplay: String {
    let raw: String
    if case .limitedTimeOffer = configuration.context {
      raw = ltoManager.headline
    } else {
      raw = String(localized: headerTitle)
    }
    return raw.replacingOccurrences(of: "Joodle Pro", with: "Joodle\u{00A0}Pro")
  }

  // MARK: - Context Body

  /// Composes the body sections according to which surface the paywall is shown in.
  @ViewBuilder
  private var contextBody: some View {
    switch configuration.context {
    case .trialStatus:
      ProFeatureCarousel()
      TrialTimelineView(style: .trial, progress: GracePeriodManager.shared.gracePeriodProgress)
      ProComparisonTable()
      if showEarlyUpgrade {
        pricingSection
        ctaSection
        legalLinksSection
      } else {
        earlyUpgradeButton
      }

    case .onboarding, .expired, .limitedTimeOffer, .trialEnded:
      // The pay surfaces all share the same skeleton: value carousel,
      // Free-vs-Pro comparison, plans, CTA. Header copy (and the floating
      // skip button in onboarding) carry the contextual differences.
      ProFeatureCarousel()
      ProComparisonTable()
      pricingSection
      ctaSection
      legalLinksSection
    }
  }

  /// Muted skip affordance pinned to the onboarding paywall's top-right
  /// corner. Deliberately quiet next to the slider CTA: skipping stays
  /// available without competing with the purchase action.
  private var onboardingSkipButton: some View {
    Button {
      configuration.onContinueFree?()
    } label: {
      Text("Skip")
        .font(.appSubheadline(weight: .medium))
        .foregroundColor(.secondary)
    }
  }

  /// Secondary affordance in the trial-status context that reveals the pricing/purchase section.
  /// Uses the same glass style as the onboarding action button for consistency.
  private var earlyUpgradeButton: some View {
    OnboardingButtonView(label: "Get Joodle Pro") {
      withAnimation(.springFkingSatifying) {
        showEarlyUpgrade = true
      }
    }
    .padding(.top, 8)
  }

  // MARK: - Pricing Section

  private var pricingSection: some View {
    VStack(spacing: 16) {
      if storeManager.products.isEmpty {
        emptyProductsView
      } else {
        productCards
        
        // Savings and auto-renewal info
        if let selectedID = selectedProductID,
           let product = storeManager.products.first(where: { $0.id == selectedID }) {
          savingsAndRenewalInfo(for: product)
        }
      }
    }
    .padding(.horizontal, 24)
  }
  
  /// Shows savings info for yearly plan and auto-renewal disclaimer
  private func savingsAndRenewalInfo(for product: Product) -> some View {
    let isYearly = product.id.contains("yearly")
    let isLifetime = product.id.contains("lifetime")
    let savingsAmount = storeManager.yearlySavingsAmount()
    
    return VStack(spacing: 4) {
      // Savings text (only for yearly) - with fixed height container
      ZStack {
        // Invisible placeholder to maintain height
        Text("Save $00.00 per year.")
          .font(.appSubheadline(weight: .medium))
          .opacity(0)
        
        // Actual savings text with animation
        if isYearly, let amount = savingsAmount {
          Text("Save \(amount) per year.")
            .font(.appSubheadline(weight: .medium))
            .foregroundColor(.appAccent)
            .transition(.asymmetric(
              insertion: .opacity.combined(with: .scale(scale: 0.8)).combined(with: .offset(y: -4)),
              removal: .opacity.combined(with: .scale(scale: 0.8)).combined(with: .offset(y: 4))
            ))
        } else if isLifetime {
          Text("Pay once, own it forever.")
            .font(.appSubheadline(weight: .medium))
            .foregroundColor(.appAccent)
            .transition(.asymmetric(
              insertion: .opacity.combined(with: .scale(scale: 0.8)).combined(with: .offset(y: -4)),
              removal: .opacity.combined(with: .scale(scale: 0.8)).combined(with: .offset(y: 4))
            ))
        }
      }
      .animation(.springFkingSatifying, value: isYearly)
      .animation(.springFkingSatifying, value: isLifetime)
      
      // Auto-renewal disclaimer (not for lifetime)
      if isLifetime {
        Text("One-time purchase. No subscription.")
          .font(.appCaption())
          .foregroundColor(.secondary)
      } else {
        Text("Auto renews \(isYearly ? String(localized: "yearly") : String(localized: "monthly")) until canceled.")
          .font(.appCaption())
          .foregroundColor(.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .padding(.top, 4)
  }

  private var emptyProductsView: some View {
    VStack(spacing: 12) {
      Text("Unable to load plans")
        .foregroundColor(.secondary)

      Text("Please check your internet connection and try again.")
        .font(.appCaption())
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)

      Button {
        Task {
          await storeManager.loadProducts()
        }
      } label: {
        Label("Retry", systemImage: "arrow.clockwise")
          .font(.appSubheadline())
      }
      .buttonStyle(.bordered)
    }
    .padding(.vertical, 40)
  }

  /// Whether this surface is the offer sheet with a live per-user window.
  private var isShowingPromoOffer: Bool {
    guard case .limitedTimeOffer = configuration.context else { return false }
    return ltoManager.isActive
  }

  /// The lifetime card to display: the discounted promo SKU whenever the
  /// user's window is live — on every paywall surface, so no entry point
  /// quotes a worse price than the offer — and the full-price SKU otherwise.
  /// Never both at once: there'd be a permanent "always buy the cheap one" path.
  private var displayedLifetimeProduct: Product? {
    if ltoManager.isActive, let promo = ltoManager.promoProduct {
      return promo
    }
    return storeManager.lifetimeProduct
  }

  private var productCards: some View {
    VStack(spacing: 24) {
      if showsInlineOfferCountdown, let endDate = ltoManager.endDate {
        CountdownTimerView(endDate: endDate, style: .pills)
      }

      // Top row: Lifetime centered
      if let lifetime = displayedLifetimeProduct {
        let isPromo = lifetime.id == JoodleProducts.lifetimePromo
        PricingCard(
          product: lifetime,
          isSelected: selectedProductID == lifetime.id,
          badge: isPromo
            ? ltoManager.discountPercent.map { String(localized: "\((Double($0) / 100).formatted(.percent)) OFF") } ?? String(localized: "BEST VALUE")
            : String(localized: "BEST VALUE"),
          isEligibleForIntroOffer: false,
          layout: .compact,
          originalPriceText: isPromo ? storeManager.lifetimeProduct?.displayPrice : nil,
          onSelect: {
            selectedProductID = lifetime.id
          }
        )
        .frame(maxWidth: .infinity)
      }

      // Bottom row: Yearly + Monthly side by side. Hidden on the offer sheet —
      // the discount is lifetime-only, so the subscriptions would only dilute it.
      if !isShowingPromoOffer {
        HStack(spacing: 24) {
          if let yearly = storeManager.yearlyProduct {
            PricingCard(
              product: yearly,
              isSelected: selectedProductID == yearly.id,
              badge: savingsBadgeText(),
              isEligibleForIntroOffer: storeManager.isEligibleForIntroOffer,
              layout: .compact,
              onSelect: {
                selectedProductID = yearly.id
              }
            )
          }

          if let monthly = storeManager.monthlyProduct {
            PricingCard(
              product: monthly,
              isSelected: selectedProductID == monthly.id,
              badge: nil,
              isEligibleForIntroOffer: storeManager.isEligibleForIntroOffer,
              layout: .compact,
              onSelect: {
                selectedProductID = monthly.id
              }
            )
          }
        }
      }
    }
  }

  // MARK: - CTA Section

  private var ctaSection: some View {
    VStack(spacing: 12) {
      // Main CTA Slider
      mainCTAButton

      // Spotify-style disclaimer below CTA
      if let selectedID = selectedProductID,
         let product = storeManager.products.first(where: { $0.id == selectedID }) {
        spotifyStyleDisclaimer(for: product)
      }
    }
    .padding(.horizontal, 24)
  }
  
  /// Spotify-style disclaimer text that clearly states what happens after trial/promo
  private func spotifyStyleDisclaimer(for product: Product) -> some View {
    Text(spotifyDisclaimerText(for: product))
      .font(.appCaption2())
      .foregroundColor(.secondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 8)
  }
  
  /// Generates Spotify-style disclaimer text
  private func spotifyDisclaimerText(for product: Product) -> String {
    // Lifetime purchase - no subscription
    if product.id.contains("lifetime") {
      return String(localized: "One-time payment of \(product.displayPrice). No subscription, no recurring charges. Unlock all features forever.")
    }
    
    let periodText = product.id.contains("yearly") ? String(localized: "year") : String(localized: "month")
    
    // No trial available
    return String(localized: "\(product.displayPrice) per \(periodText). Cancel anytime.")
  }

  @ViewBuilder
  private var mainCTAButton: some View {
    SliderCTAButton(
      isProMode: .constant(true),
      allowModeToggle: false,
      isLoading: isPurchasing || storeManager.hasActiveSubscription,
      trialPeriodText: selectedTrialPeriodText,
      fallbackButtonText: selectedProductIsLifetime ? String(localized: "Buy Joodle Pro") : String(localized: "Continue with Pro"),
      onSlideComplete: handleSlideComplete
    )
  }

  /// Whether the currently selected product is the lifetime purchase
  private var selectedProductIsLifetime: Bool {
    selectedProductID?.contains("lifetime") == true
  }

  /// Returns the formatted trial period text for the currently selected product
  /// No introductory offers are used — always returns nil
  private var selectedTrialPeriodText: String? {
    return nil
  }

  /// Formats a subscription period into a user-friendly string (e.g., "7-Day", "1-Month", "3-Month")
  private func formatTrialPeriod(_ period: Product.SubscriptionPeriod) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .full
    formatter.maximumUnitCount = 1
    formatter.zeroFormattingBehavior = .dropAll
    formatter.calendar = .autoupdatingCurrent

    var components = DateComponents()
    switch period.unit {
    case .day:
      formatter.allowedUnits = [.day]
      components.day = period.value
    case .week:
      // Normalize weeks to days to avoid locale-specific week abbreviation output.
      formatter.allowedUnits = [.day]
      components.day = period.value * 7
    case .month:
      formatter.allowedUnits = [.month]
      components.month = period.value
    case .year:
      formatter.allowedUnits = [.year]
      components.year = period.value
    @unknown default:
      return String(localized: "Free")
    }

    return formatter.string(from: components) ?? String(localized: "Free")
  }

  private func handleSlideComplete() {
    if useProMode {
      // Handle purchase
      if let selectedID = selectedProductID,
         let product = storeManager.products.first(where: { $0.id == selectedID }) {
        // The offer genuinely expires: if the window lapsed between render
        // and slide, buy the full-price SKU instead of the stale promo.
        if product.id == JoodleProducts.lifetimePromo, !ltoManager.isActive,
           let full = storeManager.lifetimeProduct {
          selectedProductID = full.id
          handlePurchase(full)
        } else {
          handlePurchase(product)
        }
      } else if let lifetime = displayedLifetimeProduct {
        // Auto-select lifetime if nothing selected
        selectedProductID = lifetime.id
        handlePurchase(lifetime)
      } else if let yearly = storeManager.yearlyProduct {
        selectedProductID = yearly.id
        handlePurchase(yearly)
      }
    } else {
      // Handle continue for free
      configuration.onContinueFree?()
    }
  }

  // MARK: - Legal Links Section

  private var legalLinksSection: some View {
    HStack(spacing: 0) {
      // Restore Purchases
      Button {
        Task {
          await storeManager.restorePurchases(paywallSource: configuration.paywallSource)
          if storeManager.hasActiveSubscription {
            configuration.onRestoreComplete?()
          }
        }
      } label: {
        Text("Restore Purchases")
          .font(.appCaption())
          .foregroundColor(.secondary)
      }
      
      Spacer()
      
      // Terms
      Link("Terms", destination: URL(string: "https://liyuxuan.dev/apps/joodle/terms-of-service")!)
        .font(.appCaption())
        .foregroundColor(.secondary)
      
      Spacer()
      
      // Privacy
      Link("Privacy", destination: URL(string: "https://liyuxuan.dev/apps/joodle/privacy-policy")!)
        .font(.appCaption())
        .foregroundColor(.secondary)
      
      Spacer()
      
      // Redeem
      Button {
        showRedeemCode = true
      } label: {
        Text("Redeem")
          .font(.appCaption())
          .foregroundColor(.secondary)
      }
    }
    .padding(.horizontal, 32)
    .padding(.bottom, 20)
  }

  // MARK: - Helper Methods

  private func handleOnAppear() {
    if selectedProductID == nil, !storeManager.products.isEmpty {
      selectedProductID = displayedLifetimeProduct?.id ?? storeManager.yearlyProduct?.id
    }

    if storeManager.products.isEmpty && !storeManager.isLoading {
      Task {
        await storeManager.loadProducts()
      }
    }
  }

  private func handlePurchase(_ product: Product) {
    // Guard against double-purchase if user is already subscribed
    if storeManager.hasActiveSubscription {
      configuration.onPurchaseComplete?()
      return
    }

    isPurchasing = true

    Task {
      do {
        let transaction = try await storeManager.purchase(product, paywallSource: configuration.paywallSource)

        if transaction != nil {
          // Refresh the entitlement BEFORE the celebration takes over. Presenters
          // watch subscription state to decide whether their sheet should still
          // be up — the limited-time-offer sheet dismisses itself the moment the
          // offer stops being active, which is exactly what a purchase causes —
          // so a stale `isSubscribed` here would tear the celebration back down.
          await subscriptionManager.updateSubscriptionStatus()
          // Don't reset isPurchasing here - the paywall is unmounted in favour of
          // the celebration, and resetting would re-enable the slider underneath.
          await MainActor.run {
            Haptic.play(with: .medium)
            celebration = JoodleProducts.lifetimeIDs.contains(product.id) ? .lifetime : .subscription
          }
          return
        } else {
          // Transaction is nil - purchase was not completed (e.g., pending approval)
          await MainActor.run {
            errorMessage = String(localized: "Purchase could not be completed. It may be pending approval or was cancelled. Please check your subscription status from \"Settings > [Your Name] > Subscriptions\"")
            showError = true
          }
        }
      } catch {
        // Show user-friendly error message
        if let storeKitError = error as? StoreKitError {
          switch storeKitError {
          case .userCancelled:
            // Don't show error for user cancellation
            break
          case .networkError:
            errorMessage = String(localized: "Network error. Please check your internet connection and try again.")
            showError = true
          case .systemError:
            errorMessage = String(localized: "A system error occurred. Please try again later.")
            showError = true
          case .notAvailableInStorefront:
            errorMessage = String(localized: "This product is not available in your region.")
            showError = true
          case .notEntitled:
            errorMessage = String(localized: "You are not entitled to this product.")
            showError = true
          default:
            errorMessage = String(localized: "An unexpected error occurred: \(error.localizedDescription)")
            showError = true
          }
        } else {
          errorMessage = String(localized: "Purchase failed: \(error.localizedDescription)")
          showError = true
        }
      }

      // Only reset isPurchasing on error or when transaction is nil
      isPurchasing = false
    }
  }

  private func openFeedback() {
    guard let url = AppEnvironment.feedbackURL else { return }

    if UIApplication.shared.canOpenURL(url) {
      UIApplication.shared.open(url)
    } else {
      // Fallback: If TestFlight URL doesn't work, try opening App Store
      if let appStoreURL = AppEnvironment.appStoreReviewURL {
        UIApplication.shared.open(appStoreURL)
      }
    }
  }

  private var deviceIdentifier: String {
    let vendorId = UIDevice.current.identifierForVendor?.uuidString ?? "Unknown"
    let appId = Bundle.main.bundleIdentifier ?? "Unknown"
    return "\(vendorId):\(appId)"
  }

  private var supportMailURL: URL? {
    let email = "joodle@liyuxuan.dev"
    let subject = "Support Request - Purchase Issue"
    let iOSVersion = UIDevice.current.systemVersion
    let body = "\n\n\n\n\nJoodle \(AppEnvironment.fullVersionDisplayString) - iOS \(iOSVersion)\nID: \(deviceIdentifier)"

    let subjectEncoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let bodyEncoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

    return URL(string: "mailto:\(email)?subject=\(subjectEncoded)&body=\(bodyEncoded)")
  }

  private func openSupportEmail() {
    guard let url = supportMailURL else { return }
    UIApplication.shared.open(url)
  }

  private func savingsBadgeText() -> String? {
    if let percentage = storeManager.savingsPercentage() {
      let formatted = (Double(percentage) / 100).formatted(.percent)
      return String(localized: "SAVE \(formatted)")
    }
    return String(localized: "BEST VALUE")
  }
}

// MARK: - Preview

#Preview("Expired (pay screen)") {
  PaywallContentView(configuration: PaywallConfiguration(context: .expired))
}

#Preview("Onboarding (informative)") {
  PaywallContentView(configuration: PaywallConfiguration(context: .onboarding))
}

#Preview("Trial Status (5 days left)") {
  PaywallContentView(configuration: PaywallConfiguration(context: .trialStatus(daysLeft: 5)))
}

#Preview("Trial Status (1 day left)") {
  PaywallContentView(configuration: PaywallConfiguration(context: .trialStatus(daysLeft: 1)))
}

#Preview("Slider CTA - Pro Mode") {
  VStack(spacing: 40) {
    SliderCTAButton(
      isProMode: .constant(true),
      allowModeToggle: true,
      isLoading: false,
      trialPeriodText: "3-Month",
      fallbackButtonText: "Subscribe to Joodle Pro",
      onSlideComplete: {}
    )
    .padding(.horizontal, 24)

    SliderCTAButton(
      isProMode: .constant(false),
      allowModeToggle: true,
      isLoading: false,
      trialPeriodText: nil,
      fallbackButtonText: "Subscribe to Joodle Pro",
      onSlideComplete: {}
    )
    .padding(.horizontal, 24)
  }
  .padding(.vertical, 40)
}
