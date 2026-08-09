//
//  CountdownHelperTests.swift
//  JoodleTests
//

import Foundation
import Testing
@testable import Joodle

struct CountdownHelperTests {

  // Dates are built in the local calendar because CountdownHelper deliberately
  // works in the user's timezone (Joodle tracks perceived days, not timestamps).
  // A fixed-GMT calendar here makes the tests fail on any non-UTC machine.
  private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    let calendar = Calendar.autoupdatingCurrent

    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = 0

    return calendar.date(from: components)!
  }

  @Test func countdownTomorrowAtDayBoundary() {
    let now = makeDate(2026, 3, 11, 23, 50)
    let target = makeDate(2026, 3, 12, 0, 10)

    let result = CountdownHelper.countdownText(from: now, to: target)

    #expect(result == String(localized: "Tomorrow"))
  }

  @Test func countdownTwoDaysMatchesRelativeFormatter() {
    let now = makeDate(2026, 3, 11, 9, 0)
    let target = makeDate(2026, 3, 13, 18, 0)

    var calendar = Calendar.autoupdatingCurrent
    calendar.locale = .autoupdatingCurrent
    let startOfToday = calendar.startOfDay(for: now)
    let startOfTarget = calendar.startOfDay(for: target)

    let formatter = RelativeDateTimeFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.calendar = calendar
    formatter.unitsStyle = .full

    let expected = formatter.localizedString(for: startOfTarget, relativeTo: startOfToday)
    let actual = CountdownHelper.countdownText(from: now, to: target)

    #expect(actual == expected)
  }

  @Test func countdownPastDateIsEmpty() {
    let now = makeDate(2026, 3, 11, 9, 0)
    let target = makeDate(2026, 3, 10, 9, 0)

    let result = CountdownHelper.countdownText(from: now, to: target)

    #expect(result.isEmpty)
  }

  @Test func localizedDateTextUsesExpectedTemplate() {
    let date = makeDate(2026, 3, 11, 10, 30)

    var calendar = Calendar.autoupdatingCurrent
    calendar.locale = .autoupdatingCurrent

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("yMMMd")

    let expected = formatter.string(from: date)
    let actual = CountdownHelper.dateText(for: date)

    #expect(actual == expected)
    #expect(!actual.isEmpty)
  }

  // MARK: - Explicit locale
  //
  // Joodle drives its language from the SwiftUI `\.locale` environment (the
  // in-app language picker in the app, the app-group override in the widgets),
  // which can differ from the device language. These cover that the countdown
  // follows the locale it is handed instead of resolving against the device.

  @Test(arguments: [
    ("fr", "Demain"),
    ("ja", "明日"),
    ("ko", "내일"),
  ])
  func countdownTomorrowFollowsExplicitLocale(languageCode: String, expected: String) {
    let now = makeDate(2026, 3, 11, 9, 0)
    let target = makeDate(2026, 3, 12, 9, 0)

    let result = CountdownHelper.countdownText(
      from: now,
      to: target,
      locale: Locale(identifier: languageCode)
    )

    #expect(result == expected)
    #expect(result != "Tomorrow")
  }

  @Test(arguments: ["ja_JP", "zh-Hant-TW"])
  func countdownWidensRegionalLocaleToAnAvailableLanguage(identifier: String) {
    let now = makeDate(2026, 3, 11, 9, 0)
    let target = makeDate(2026, 3, 12, 9, 0)

    let result = CountdownHelper.countdownText(from: now, to: target, locale: Locale(identifier: identifier))

    #expect(result != "Tomorrow")
  }

  @Test func countdownFallsBackToEnglishForUnshippedLanguage() {
    let now = makeDate(2026, 3, 11, 9, 0)
    let target = makeDate(2026, 3, 12, 9, 0)

    // Joodle ships no German catalog: fall back to the source language rather
    // than to some arbitrary other translation.
    let result = CountdownHelper.countdownText(from: now, to: target, locale: Locale(identifier: "de"))

    #expect(result == "Tomorrow")
  }

  @Test func countdownInMonthsFollowsExplicitLocale() {
    let now = makeDate(2026, 3, 11, 9, 0)
    let target = makeDate(2026, 6, 20, 9, 0)

    let english = CountdownHelper.countdownText(from: now, to: target, locale: Locale(identifier: "en"))
    let japanese = CountdownHelper.countdownText(from: now, to: target, locale: Locale(identifier: "ja"))
    let french = CountdownHelper.countdownText(from: now, to: target, locale: Locale(identifier: "fr"))

    #expect(!english.isEmpty)
    #expect(!japanese.isEmpty)
    #expect(!french.isEmpty)
    // Both the "in %@" wrapper and the duration itself must be translated.
    #expect(japanese != english)
    #expect(french != english)
    #expect(japanese != french)
  }

  @Test func countdownInDaysFollowsExplicitLocale() {
    let now = makeDate(2026, 3, 11, 9, 0)
    let target = makeDate(2026, 3, 15, 9, 0)

    let locale = Locale(identifier: "fr")
    var calendar = Calendar.autoupdatingCurrent
    calendar.locale = locale

    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.unitsStyle = .full

    let expected = formatter.localizedString(
      for: calendar.startOfDay(for: target),
      relativeTo: calendar.startOfDay(for: now)
    )
    let actual = CountdownHelper.countdownText(from: now, to: target, locale: locale)

    #expect(actual == expected)
    #expect(actual != CountdownHelper.countdownText(from: now, to: target, locale: Locale(identifier: "en")))
  }

  @Test func dateTextFollowsExplicitLocale() {
    let date = makeDate(2026, 3, 11, 10, 30)

    let locale = Locale(identifier: "ja")
    var calendar = Calendar.autoupdatingCurrent
    calendar.locale = locale

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = locale
    formatter.setLocalizedDateFormatFromTemplate("yMMMd")

    let expected = formatter.string(from: date)
    let actual = CountdownHelper.dateText(for: date, locale: locale)

    #expect(actual == expected)
    #expect(actual != CountdownHelper.dateText(for: date, locale: Locale(identifier: "en")))
  }
}
