//
//  DoodleDayGateTests.swift
//  JoodleTests
//
//  Unit tests for the day-scoped doodle gate
//  (SubscriptionManager.resolveDoodleGate). Pure function, so no
//  singletons, UserDefaults, or real clocks are touched except where
//  pinning agreement with CalendarDate.isToday.
//

import Testing
import Foundation
@testable import Joodle

struct DoodleDayGateTests {

  private let calendar = Calendar.current

  private func date(year: Int, month: Int, day: Int, hour: Int = 12, minute: Int = 0) -> Date {
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    guard let resolved = calendar.date(from: components) else {
      fatalError("Invalid date components in test fixture")
    }
    return resolved
  }

  private var now: Date { date(year: 2026, month: 3, day: 15) }
  private var yesterday: Date { date(year: 2026, month: 3, day: 14) }
  private var tomorrow: Date { date(year: 2026, month: 3, day: 16) }

  // MARK: - Free, today

  @Test func freeTodayWithNoDoodlesIsAllowed() {
    let gate = SubscriptionManager.resolveDoodleGate(
      on: now, existingDoodleCount: 0, hasPremiumAccess: false, now: now
    )
    #expect(gate == .allowed)
  }

  @Test func freeTodayAtDailyLimitIsDailyLimitReached() {
    let gate = SubscriptionManager.resolveDoodleGate(
      on: now, existingDoodleCount: 1, hasPremiumAccess: false, now: now
    )
    #expect(gate == .dailyLimitReached)
  }

  // MARK: - Free, past/future

  @Test func freeYesterdayIsDayLocked() {
    let gate = SubscriptionManager.resolveDoodleGate(
      on: yesterday, existingDoodleCount: 0, hasPremiumAccess: false, now: now
    )
    #expect(gate == .dayLocked)
  }

  @Test func freeTomorrowIsDayLocked() {
    let gate = SubscriptionManager.resolveDoodleGate(
      on: tomorrow, existingDoodleCount: 0, hasPremiumAccess: false, now: now
    )
    #expect(gate == .dayLocked)
  }

  @Test func freeYesterdayIsDayLockedRegardlessOfCount() {
    // Proves the day rule takes precedence over the count rule: a past day
    // is locked even at 0 doodles, and stays locked past the daily cap.
    for count in [0, 1, 3] {
      let gate = SubscriptionManager.resolveDoodleGate(
        on: yesterday, existingDoodleCount: count, hasPremiumAccess: false, now: now
      )
      #expect(gate == .dayLocked)
    }
  }

  // MARK: - Pro bypasses everything

  @Test func proIsAlwaysAllowed() {
    for testDate in [yesterday, now, tomorrow] {
      for count in [0, 1, 3] {
        let gate = SubscriptionManager.resolveDoodleGate(
          on: testDate, existingDoodleCount: count, hasPremiumAccess: true, now: now
        )
        #expect(gate == .allowed)
      }
    }
  }

  // MARK: - Midnight boundary

  @Test func datesEitherSideOfMidnightLandOnCorrectSide() {
    let justBeforeMidnight = date(year: 2026, month: 3, day: 15, hour: 23, minute: 59)
    let justAfterMidnight = date(year: 2026, month: 3, day: 16, hour: 0, minute: 1)
    let anchoredNow = justBeforeMidnight

    let sameDayGate = SubscriptionManager.resolveDoodleGate(
      on: justBeforeMidnight, existingDoodleCount: 0, hasPremiumAccess: false, now: anchoredNow
    )
    #expect(sameDayGate == .allowed)

    let nextDayGate = SubscriptionManager.resolveDoodleGate(
      on: justAfterMidnight, existingDoodleCount: 0, hasPremiumAccess: false, now: anchoredNow
    )
    #expect(nextDayGate == .dayLocked)
  }

  // MARK: - Agreement with CalendarDate.isToday

  @Test func resolveDoodleGateAgreesWithCalendarDateIsToday() {
    let today = CalendarDate.today()
    let yesterday = CalendarDate.from(today.displayDate.addingTimeInterval(-1 * 24 * 60 * 60))
    let tomorrow = CalendarDate.from(today.displayDate.addingTimeInterval(1 * 24 * 60 * 60))

    for calendarDate in [today, yesterday, tomorrow] {
      let gate = SubscriptionManager.resolveDoodleGate(
        on: calendarDate.displayDate, existingDoodleCount: 0, hasPremiumAccess: false
      )
      #expect((gate != .dayLocked) == calendarDate.isToday)
    }
  }
}
