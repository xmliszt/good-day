//
//  TrialOfferManager.swift
//  Joodle
//
//  Owns the claim-based 7-day trial offer funnel:
//
//    dormant → offerAvailable → claimWindow → postTrial(offerExpired)
//                        ↘ trialActive (claimed) → postTrial(trialEnded)
//
//  New installs become offer-eligible when they finish their free doodle
//  allowance; legacy installs (whose auto-started grace period predates this
//  funnel) become eligible as a winback the moment their auto trial is over.
//  Dismissing the claim paywall starts a per-user claim window whose countdown
//  lives in the Settings banner; once it lapses — or a claimed trial ends —
//  the post-trial 50%-off lifetime offer arms (see LimitedTimeOfferManager).
//

import Combine
import Foundation
import UIKit

// MARK: - Funnel Phase Model

/// Where a user stands in the claim funnel. File-scope (not nested in the
/// @MainActor manager) so pure helpers and unit tests can build and compare
/// values without actor isolation.
enum TrialFunnelPhase: Equatable {
  enum PostTrialReason: String, Equatable {
    /// A claimed (or legacy auto) trial ran its 7 days.
    case trialEnded = "trial_ended"
    /// The claim window lapsed without the trial ever being claimed.
    case offerExpired = "offer_expired"
  }

  /// Nothing offered yet (new install still under the free doodle limit).
  case dormant
  /// The claim paywall may be shown; no countdown is running yet.
  case offerAvailable
  /// The claim paywall was dismissed — the claim countdown is running.
  case claimWindow(end: Date)
  /// A trial (claimed, or a legacy auto-started grace period) is running.
  case trialActive
  /// The trial ended or the claim offer expired — 50%-off territory.
  case postTrial(reason: PostTrialReason)
  /// The user owns a subscription or lifetime purchase; the funnel is done.
  case converted
}

/// One-tap canonical funnel states for the Developer console, so every branch
/// of the conversion funnel can be exercised end-to-end in debug/TestFlight
/// builds without waiting out real clocks. Labels are verbatim developer-UI
/// strings and intentionally bypass localization.
enum FunnelDebugScenario: String, CaseIterable, Identifiable {
  case freshNewInstall
  case atDoodleLimit
  case claimWindowActive
  case claimWindowExpired
  case trialActiveDay2
  case trialEndingSoon
  case trialEnded
  case legacyWinback
  case legacyMidTrial

  var id: String { rawValue }

  var title: String {
    switch self {
    case .freshNewInstall: return "Fresh new install (dormant)"
    case .atDoodleLimit: return "At doodle limit → claim offer due"
    case .claimWindowActive: return "Claim window running (12h left)"
    case .claimWindowExpired: return "Claim window expired (offer lost)"
    case .trialActiveDay2: return "Claimed trial active — day 2"
    case .trialEndingSoon: return "Claimed trial ends in 2 minutes"
    case .trialEnded: return "Claimed trial ended"
    case .legacyWinback: return "Legacy install — winback offer"
    case .legacyMidTrial: return "Legacy install — auto-trial day 3"
    }
  }

  /// What the tester should do/expect after applying the scenario.
  var hint: String {
    switch self {
    case .freshNewInstall:
      return "New cohort, 7-doodle limit, nothing offered. Draw doodles to walk the funnel naturally."
    case .atDoodleLimit:
      return "Free limit set to your current doodle count (min 1). Relaunch to auto-present the claim paywall; the canvas gate and Settings routes offer the claim too."
    case .claimWindowActive:
      return "Claim countdown ends in 12h. Check the Settings banner; tapping it reopens the claim paywall."
    case .claimWindowExpired:
      return "Offer forfeited. Relaunch to see the post-trial sheet (offer-expired copy) and the 50%-off window arm."
    case .trialActiveDay2:
      return "Pro is on via the claimed trial (day 2 of 7). Settings banner shows trial status."
    case .trialEndingSoon:
      return "Trial expires in ~2 minutes — keep the app open to watch Pro switch off live, or relaunch after it lapses for the post-trial sheet."
    case .trialEnded:
      return "Trial is over. Relaunch to see the trial-ended sheet, the 50%-off window, and the review prompt after dismissing the sheet."
    case .legacyWinback:
      return "Legacy cohort (30-doodle limit), auto-trial expired a month ago. Relaunch to auto-present the winback claim paywall."
    case .legacyMidTrial:
      return "Legacy cohort mid auto-trial (day 3). No claim offer while it runs; it becomes a winback when the trial ends."
    }
  }

  var icon: String {
    switch self {
    case .freshNewInstall: return "sparkles"
    case .atDoodleLimit: return "scribble.variable"
    case .claimWindowActive: return "timer"
    case .claimWindowExpired: return "timer.slash"
    case .trialActiveDay2: return "crown"
    case .trialEndingSoon: return "hourglass.tophalf.filled"
    case .trialEnded: return "hourglass.bottomhalf.filled"
    case .legacyWinback: return "gift"
    case .legacyMidTrial: return "clock.arrow.circlepath"
    }
  }
}

/// Raw inputs for phase resolution, separated out so the transition logic is
/// a pure function the unit tests can drive without singletons or clocks.
struct TrialFunnelSnapshot {
  var isSubscribed: Bool
  var isLegacyInstall: Bool
  var legacyGraceActive: Bool
  var claimedTrialStart: Date?
  var claimWindowEnd: Date?
  var doodleCount: Int
  var freeLimit: Int
  var now: Date
}

@MainActor
final class TrialOfferManager: ObservableObject {
  static let shared = TrialOfferManager()

  // MARK: - Constants

  /// How long the user has to claim the free trial after first dismissing the
  /// claim paywall. 72h ≈ 2–3 daily sessions of banner exposure — a 24h window
  /// would often lapse before a once-a-day doodler's next open.
  static let claimWindowDuration: TimeInterval = 72 * 60 * 60

  // MARK: - Storage Keys

  // nonisolated so the pure/static helpers below (and SubscriptionManager's
  // nonisolated limit resolution) can read them off the main actor.
  private nonisolated static let migrationVersionKey = "conversion_funnel_version"
  private nonisolated static let legacyInstallKey = "funnel_is_legacy_install"
  nonisolated static let freeJoodleLimitKey = "free_joodle_limit"
  private static let claimWindowEndKey = "trial_claim_window_end"
  private static let offerAutoPresentedKey = "trial_offer_autopresented"
  private static let postTrialSheetShownKey = "post_trial_sheet_shown"

  // MARK: - Phase Resolution

  /// Pure phase resolution — the single source of truth for funnel state.
  nonisolated static func resolvePhase(_ s: TrialFunnelSnapshot) -> TrialFunnelPhase {
    if s.isSubscribed { return .converted }

    // A claimed trial outranks everything else, running or finished.
    if let start = s.claimedTrialStart {
      return s.now < start.addingTimeInterval(GracePeriodManager.gracePeriodDuration)
        ? .trialActive
        : .postTrial(reason: .trialEnded)
    }

    // A legacy auto-started grace period still running counts as the trial;
    // those users are never offered a second claim while it lasts.
    if s.legacyGraceActive { return .trialActive }

    // The claim countdown, once started, decides availability by itself.
    if let end = s.claimWindowEnd {
      return s.now < end ? .claimWindow(end: end) : .postTrial(reason: .offerExpired)
    }

    // Legacy installs whose auto trial is over get the claim offer as a
    // winback regardless of doodle count; new installs earn it by using up
    // their free allowance.
    if s.isLegacyInstall { return .offerAvailable }
    return s.doodleCount >= s.freeLimit ? .offerAvailable : .dormant
  }

  // MARK: - Published State

  /// Bumped whenever any underlying input changes so SwiftUI re-reads `phase`.
  @Published private(set) var stateVersion = 0

  /// Doodle count last reported by the UI; feeds the new-install offer trigger.
  private var lastKnownDoodleCount = 0

  private var foregroundObserver: AnyCancellable?
  private var windowExpiryTimer: Timer?
  private let cloudStore = NSUbiquitousKeyValueStore.default

  private init() {
    foregroundObserver = NotificationCenter.default
      .publisher(for: UIApplication.willEnterForegroundNotification)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in self?.refresh() }
      }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(cloudStoreDidChange),
      name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
      object: cloudStore
    )

    scheduleWindowExpiryTick()
  }

  deinit {
    windowExpiryTimer?.invalidate()
    foregroundObserver?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Migration (runs once, before anything reads the free limit)

  /// Decides, on the first launch after this funnel ships, whether this is a
  /// legacy install (auto-grace era → keeps the 30-doodle limit) or a fresh
  /// one (7-doodle limit). Safe to call every launch; writes only once.
  nonisolated static func migrateFunnelStateIfNeeded() {
    let defaults = UserDefaults.standard
    guard defaults.integer(forKey: migrationVersionKey) < 2 else { return }

    // A grace-period start date anywhere means the install predates the
    // claim funnel. iCloud KVS may not have synced yet on a fresh reinstall —
    // the KVS observer below raises the limit later if the cloud disagrees.
    let cloud = NSUbiquitousKeyValueStore.default
    let isLegacy = defaults.object(forKey: "grace_period_start_date") != nil
      || cloud.object(forKey: "grace_period_start_date") != nil

    let limit = isLegacy
      ? SubscriptionManager.legacyFreeJoodlesAllowed
      : SubscriptionManager.baseFreeJoodlesAllowed

    defaults.set(isLegacy, forKey: legacyInstallKey)
    defaults.set(limit, forKey: freeJoodleLimitKey)
    defaults.set(2, forKey: migrationVersionKey)
    cloud.set(Int64(limit), forKey: freeJoodleLimitKey)
    cloud.synchronize()
    print("🧭 [Funnel] Migrated to v2 — legacy: \(isLegacy), free limit: \(limit)")
  }

  var isLegacyInstall: Bool {
    UserDefaults.standard.bool(forKey: Self.legacyInstallKey)
  }

  // MARK: - Derived State

  private var claimWindowEnd: Date? {
    get { UserDefaults.standard.object(forKey: Self.claimWindowEndKey) as? Date }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.claimWindowEndKey)
      if let newValue {
        cloudStore.set(newValue, forKey: Self.claimWindowEndKey)
        cloudStore.synchronize()
      }
    }
  }

  private var snapshot: TrialFunnelSnapshot {
    let grace = GracePeriodManager.shared
    return TrialFunnelSnapshot(
      isSubscribed: SubscriptionManager.shared.isSubscribed,
      isLegacyInstall: isLegacyInstall,
      legacyGraceActive: grace.claimedTrialStartDate == nil && grace.isInGracePeriod,
      claimedTrialStart: grace.claimedTrialStartDate,
      claimWindowEnd: claimWindowEnd,
      doodleCount: lastKnownDoodleCount,
      freeLimit: SubscriptionManager.freeJoodlesAllowed,
      now: Date()
    )
  }

  var phase: TrialFunnelPhase { Self.resolvePhase(snapshot) }

  /// Whether the claim paywall is a valid surface right now (auto-present,
  /// Settings banner, or the canvas limit gate).
  var isClaimOfferAvailable: Bool {
    switch phase {
    case .offerAvailable, .claimWindow: return true
    default: return false
    }
  }

  /// Gates LimitedTimeOfferManager: the 50%-off window may only exist once
  /// the trial question is settled (ended or forfeited).
  var isEligibleForPostTrialOffer: Bool {
    if case .postTrial = phase { return true }
    return false
  }

  var isTrialClaimed: Bool {
    GracePeriodManager.shared.claimedTrialStartDate != nil
  }

  // MARK: - Auto-presentation

  private var offerAutoPresented: Bool {
    get { UserDefaults.standard.bool(forKey: Self.offerAutoPresentedKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.offerAutoPresentedKey) }
  }

  private var postTrialSheetShown: Bool {
    get { UserDefaults.standard.bool(forKey: Self.postTrialSheetShownKey) }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.postTrialSheetShownKey)
      cloudStore.set(newValue, forKey: Self.postTrialSheetShownKey)
      cloudStore.synchronize()
    }
  }

  /// One-shot: pop the claim paywall on its own. New installs qualify the
  /// moment their doodle count reaches the free limit; legacy installs
  /// qualify on their first open once their auto trial is over (winback).
  func shouldAutoPresentClaimOffer(doodleCount: Int) -> Bool {
    lastKnownDoodleCount = max(lastKnownDoodleCount, doodleCount)
    guard !offerAutoPresented else { return false }
    guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return false }
    return phase == .offerAvailable
  }

  func markClaimOfferAutoPresented() {
    offerAutoPresented = true
    bumpState()
  }

  /// One-shot: the post-trial comparison sheet on next app open.
  var shouldPresentPostTrialSheet: Bool {
    guard !postTrialSheetShown else { return false }
    guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return false }
    return isEligibleForPostTrialOffer
  }

  var postTrialReason: TrialFunnelPhase.PostTrialReason? {
    if case .postTrial(let reason) = phase { return reason }
    return nil
  }

  func markPostTrialSheetShown() {
    postTrialSheetShown = true
    bumpState()
  }

  // MARK: - Actions

  /// The user tapped Claim: start the 7-day trial and stop any countdown.
  func claimTrial(source: String) {
    guard !isTrialClaimed else { return }
    GracePeriodManager.shared.claimTrial()
    windowExpiryTimer?.invalidate()
    AnalyticsManager.shared.track(.trialClaimed, properties: [.source: source])
    WidgetHelper.shared.updateSubscriptionStatus()
    bumpState()
  }

  /// The claim paywall was closed without claiming. The first dismissal
  /// starts the claim window; later ones (reopened from the banner) don't
  /// shorten or extend it.
  func handleClaimSheetDismissed(source: String) {
    guard !isTrialClaimed else { return }
    AnalyticsManager.shared.track(.trialOfferDismissed, properties: [.source: source])
    guard claimWindowEnd == nil, phase == .offerAvailable else { return }
    claimWindowEnd = Date().addingTimeInterval(Self.claimWindowDuration)
    scheduleWindowExpiryTick()
    bumpState()
  }

  // MARK: - Refresh

  /// Re-evaluates state on launch/foreground so time-driven transitions
  /// (window expiry, trial end) surface without user interaction.
  func refresh() {
    scheduleWindowExpiryTick()
    bumpState()
  }

  private func bumpState() {
    stateVersion += 1
  }

  /// Fires exactly at the claim window's expiry instant so the Settings
  /// banner disappears live rather than on the next interaction.
  private func scheduleWindowExpiryTick() {
    windowExpiryTimer?.invalidate()
    windowExpiryTimer = nil
    guard let end = claimWindowEnd, !isTrialClaimed else { return }
    let interval = end.timeIntervalSinceNow
    guard interval > 0 else { return }
    windowExpiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.bumpState()
        AnalyticsManager.shared.track(.trialOfferExpired)
      }
    }
  }

  @objc private func cloudStoreDidChange(_ notification: Notification) {
    Task { @MainActor in
      reconcileWithCloud()
      refresh()
    }
  }

  /// Cross-device / reinstall reconciliation. Earliest window end wins (a
  /// reinstall can't restart the countdown); a higher cloud free limit wins
  /// (a legacy user reinstalling before KVS syncs must get 30 back, never 7).
  private func reconcileWithCloud() {
    let defaults = UserDefaults.standard

    if let cloudEnd = cloudStore.object(forKey: Self.claimWindowEndKey) as? Date {
      let localEnd = defaults.object(forKey: Self.claimWindowEndKey) as? Date
      let earliest = min(localEnd ?? .distantFuture, cloudEnd)
      if localEnd != earliest {
        defaults.set(earliest, forKey: Self.claimWindowEndKey)
      }
    }

    let cloudLimit = Int(cloudStore.longLong(forKey: Self.freeJoodleLimitKey))
    if cloudLimit > defaults.integer(forKey: Self.freeJoodleLimitKey) {
      defaults.set(cloudLimit, forKey: Self.freeJoodleLimitKey)
      if cloudLimit >= SubscriptionManager.legacyFreeJoodlesAllowed {
        defaults.set(true, forKey: Self.legacyInstallKey)
      }
      print("☁️ [Funnel] Free limit raised from iCloud KVS: \(cloudLimit)")
    }

    if cloudStore.bool(forKey: Self.postTrialSheetShownKey),
       !defaults.bool(forKey: Self.postTrialSheetShownKey) {
      defaults.set(true, forKey: Self.postTrialSheetShownKey)
    }
  }

  // MARK: - Debug / Testing

  /// Wipes all funnel state. Available in all builds so TestFlight/sandbox
  /// reviewer flows can restart the funnel, mirroring resetGracePeriod().
  func resetFunnelState() {
    guard AppEnvironment.isActuallyNonProduction else { return }
    let defaults = UserDefaults.standard
    for key in [Self.claimWindowEndKey, Self.offerAutoPresentedKey, Self.postTrialSheetShownKey] {
      defaults.removeObject(forKey: key)
      cloudStore.removeObject(forKey: key)
    }
    cloudStore.synchronize()
    lastKnownDoodleCount = 0
    windowExpiryTimer?.invalidate()
    bumpState()
    print("🔄 [Funnel] Trial offer state reset")
  }

  /// Applies a canonical funnel state for the Developer console: wipes all
  /// trial/claim/review state first, then layers exactly what the scenario
  /// needs. Runtime-gated (not #if DEBUG) so TestFlight builds can run
  /// reviewer flows, mirroring GracePeriodManager.resetGracePeriod().
  ///
  /// Launch-time sheets (claim auto-present, post-trial sheet) fire on the
  /// next cold launch — the console's footer tells the tester to relaunch.
  func applyDebugScenario(_ scenario: FunnelDebugScenario, currentDoodleCount: Int) {
    guard AppEnvironment.isActuallyNonProduction else { return }
    let defaults = UserDefaults.standard
    let grace = GracePeriodManager.shared
    let day: TimeInterval = 24 * 60 * 60

    // Clean slate: trial dates, claim window, one-shots, review flags.
    grace.resetGracePeriod()
    resetFunnelState()
    ReviewRequestManager.shared.resetForTesting()
    defaults.set(true, forKey: "hasCompletedOnboarding")

    switch scenario {
    case .freshNewInstall:
      applyDebugCohort(legacy: false)

    case .atDoodleLimit:
      // Lower the limit to the doodles already drawn so the offer is due
      // immediately (or after the very next doodle when none exist yet) —
      // this exercises the real limit-hit trigger, not a shortcut.
      applyDebugCohort(legacy: false, limitOverride: max(1, currentDoodleCount))

    case .claimWindowActive:
      applyDebugCohort(legacy: false, limitOverride: max(1, currentDoodleCount))
      defaults.set(true, forKey: Self.offerAutoPresentedKey)
      claimWindowEnd = Date().addingTimeInterval(12 * 60 * 60)

    case .claimWindowExpired:
      applyDebugCohort(legacy: false, limitOverride: max(1, currentDoodleCount))
      defaults.set(true, forKey: Self.offerAutoPresentedKey)
      claimWindowEnd = Date().addingTimeInterval(-60)

    case .trialActiveDay2:
      applyDebugCohort(legacy: false)
      grace.setClaimedTrialStart(Date().addingTimeInterval(-1 * day))

    case .trialEndingSoon:
      applyDebugCohort(legacy: false)
      grace.setClaimedTrialStart(Date().addingTimeInterval(-(GracePeriodManager.gracePeriodDuration - 120)))

    case .trialEnded:
      applyDebugCohort(legacy: false)
      grace.setClaimedTrialStart(Date().addingTimeInterval(-8 * day))

    case .legacyWinback:
      applyDebugCohort(legacy: true)
      grace.setGracePeriodStart(Date().addingTimeInterval(-30 * day))

    case .legacyMidTrial:
      applyDebugCohort(legacy: true)
      grace.setGracePeriodStart(Date().addingTimeInterval(-2 * day))
    }

    scheduleWindowExpiryTick()
    bumpState()
    print("🧪 [Funnel] Debug scenario applied: \(scenario.rawValue)")
  }

  /// Writes the cohort flags (legacy vs new install) and the free doodle
  /// limit to both stores, as the real migration would have.
  private func applyDebugCohort(legacy: Bool, limitOverride: Int? = nil) {
    let limit = limitOverride
      ?? (legacy ? SubscriptionManager.legacyFreeJoodlesAllowed : SubscriptionManager.baseFreeJoodlesAllowed)
    let defaults = UserDefaults.standard
    defaults.set(legacy, forKey: Self.legacyInstallKey)
    defaults.set(limit, forKey: Self.freeJoodleLimitKey)
    defaults.set(2, forKey: Self.migrationVersionKey)
    cloudStore.set(Int64(limit), forKey: Self.freeJoodleLimitKey)
    cloudStore.synchronize()
  }
}
