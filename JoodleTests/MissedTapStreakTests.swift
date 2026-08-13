//
//  MissedTapStreakTests.swift
//  JoodleTests
//
//  The window logic behind re-surfacing the "tap here to finish" hint for a user
//  who keeps tapping the backdrop. Getting this wrong is worse than not having
//  it: too eager and the bubble nags people who merely brushed the backdrop, too
//  slack and the user stays stuck.
//

import Foundation
import Testing

@testable import Joodle

struct MissedTapStreakTests {

  private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

  private func offset(_ seconds: TimeInterval) -> Date {
    t0.addingTimeInterval(seconds)
  }

  /// The cases below are written against these values — if you retune them,
  /// retune the expectations too rather than deleting this.
  @Test func isTunedToThreeTapsInThreeSeconds() {
    #expect(MissedTapStreak.threshold == 3)
    #expect(MissedTapStreak.windowSeconds == 3)
  }

  @Test func doesNotFireBelowTheThreshold() {
    var streak = MissedTapStreak()
    #expect(streak.register(at: t0) == false)
    #expect(streak.register(at: offset(0.4)) == false)
  }

  @Test func firesOnTheThirdTapInsideTheWindow() {
    var streak = MissedTapStreak()
    #expect(streak.register(at: t0) == false)
    #expect(streak.register(at: offset(0.5)) == false)
    #expect(streak.register(at: offset(1.0)) == true)
  }

  /// The window is measured from the first tap, not the previous one — otherwise
  /// a user tapping slowly but indefinitely would accumulate forever.
  @Test func doesNotFireWhenTapsStrayPastTheWindow() {
    var streak = MissedTapStreak()
    let step = MissedTapStreak.windowSeconds * 0.6
    #expect(streak.register(at: t0) == false)
    #expect(streak.register(at: offset(step)) == false)
    // Third tap lands past the window, so it starts a fresh streak instead.
    #expect(streak.register(at: offset(step * 2)) == false)
  }

  /// A stale tap restarts the count rather than failing, so someone tapping
  /// steadily still gets there — it just takes three inside one window.
  @Test func aLateTapStartsAFreshStreak() {
    var streak = MissedTapStreak()
    _ = streak.register(at: t0)
    let late = MissedTapStreak.windowSeconds + 1
    #expect(streak.register(at: offset(late)) == false)
    #expect(streak.register(at: offset(late + 0.2)) == false)
    #expect(streak.register(at: offset(late + 0.4)) == true)
  }

  /// Fires once per streak: the counter resets on the firing tap, so the bubble
  /// isn't re-nudged by every further tap in the same flurry.
  @Test func firesOnlyOncePerStreak() {
    var streak = MissedTapStreak()
    _ = streak.register(at: t0)
    _ = streak.register(at: offset(0.2))
    #expect(streak.register(at: offset(0.4)) == true)
    #expect(streak.register(at: offset(0.6)) == false)
    #expect(streak.register(at: offset(0.8)) == false)
    #expect(streak.register(at: offset(1.0)) == true)
  }

  @Test func resetDropsAnInFlightStreak() {
    var streak = MissedTapStreak()
    _ = streak.register(at: t0)
    _ = streak.register(at: offset(0.2))
    streak.reset()
    #expect(streak.register(at: offset(0.4)) == false)
    #expect(streak.register(at: offset(0.6)) == false)
    #expect(streak.register(at: offset(0.8)) == true)
  }
}
