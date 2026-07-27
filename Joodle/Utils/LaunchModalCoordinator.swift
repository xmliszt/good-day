//
//  LaunchModalCoordinator.swift
//  Joodle
//
//  One launch, one modal.
//

import Foundation

/// Arbitrates the modals that all want the same launch: the "What's New" sheet,
/// the limited-time offer, the post-trial sheet and the trial-claim sheet.
///
/// They are presented by different views — the changelog by the scene root, the
/// rest by ContentView — and each decides for itself after its own async work,
/// so without a shared slot two can land together. iOS then refuses the second
/// presentation and that content is lost for the launch. Every automatic
/// presenter takes the slot before showing and hands it back on dismiss.
///
/// The changelog goes first. It has exactly one launch to appear in, while a
/// paywall that stands down keeps its unseen flag and comes back on the next
/// open — so the release notes are never the thing that loses a race.
@MainActor
final class LaunchModalCoordinator {
  static let shared = LaunchModalCoordinator()

  enum Modal: String {
    case changelog
    case limitedTimeOffer
    case postTrial
    case trialClaim
    case widgetPaywall
  }

  /// Which modal owns the launch; nil when the slot is free.
  private(set) var owner: Modal?

  /// True once the changelog has either taken the slot or given up on it.
  private(set) var changelogSettled = false

  private init() {}

  // MARK: - The slot

  /// Takes the slot, or reports false when another modal already holds it.
  /// Call this immediately before presenting, and only present when it's true.
  func take(_ modal: Modal) -> Bool {
    guard owner == nil else { return false }
    owner = modal
    return true
  }

  /// Takes the slot even when something else holds it — for a modal the user
  /// asked for directly, like tapping a Pro widget. Refusing a tap is worse than
  /// displacing an automatic sheet, and anything displaced keeps its unseen flag
  /// and comes back later.
  ///
  /// Holders must re-check `owner` immediately before presenting so a modal that
  /// reserved the slot earlier doesn't present after being displaced.
  func takeOverriding(_ modal: Modal) {
    owner = modal
  }

  /// Hands the slot back. A release from anything that isn't the current owner
  /// is ignored, so a late dismiss can't take the slot away from whoever holds
  /// it next.
  func release(_ modal: Modal) {
    guard owner == modal else { return }
    owner = nil
  }

  // MARK: - Changelog precedence

  /// Records that the changelog's decision for this launch is final — it either
  /// took the slot or found nothing to show.
  func settleChangelog() {
    changelogSettled = true
  }

  /// Waits for the changelog to settle before a paywall considers presenting,
  /// giving up after `timeout` so a stalled fetch can't strand it. The fetch
  /// falls back to bundled notes on a shorter timeout of its own, so this
  /// deadline is a backstop rather than the normal path.
  ///
  /// Implemented as a poll on purpose: racing a continuation against a timer is
  /// easy to get wrong (a continuation resumed twice traps), and this runs a few
  /// dozen times at most, once per launch.
  func awaitChangelogDecision(timeout: Duration = .seconds(7)) async {
    guard !changelogSettled else { return }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !changelogSettled, !Task.isCancelled, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(120))
    }
  }

  // MARK: - Debug

  /// Clears the launch state so a debug scenario can be replayed without a
  /// relaunch.
  func resetForDebug() {
    owner = nil
    changelogSettled = false
  }
}
