//
//  CountdownHelper.swift
//  Joodle
//
//  Shared utility for countdown text generation
//

import Foundation

struct CountdownHelper {
  /// The locale used when no caller supplies one — the device's language.
  ///
  /// Callers that live inside a SwiftUI hierarchy should pass `\.locale` from the
  /// environment instead: both the app (in-app language picker) and the widgets
  /// (app-group language override) drive their language through that key, and it
  /// does not necessarily match the device language.
  static let defaultLocale = Locale.autoupdatingCurrent

  private static func calendar(for locale: Locale) -> Calendar {
    var value = Calendar.autoupdatingCurrent
    value.locale = locale
    return value
  }

  /// The bundle holding `locale`'s strings, or `Bundle.main` when the app ships no
  /// catalog for it (English, the source language, has no `.lproj` of its own).
  ///
  /// `String(localized:locale:)` uses `locale` only to format the interpolated
  /// arguments — it still reads the catalog through the bundle's *own* preferred
  /// localization, i.e. the device language. Rendering a language the user chose
  /// inside Joodle therefore needs the matching `.lproj` bundle passed explicitly.
  private static func localizationBundle(for locale: Locale) -> Bundle {
    let main = Bundle.main
    let available = main.localizations

    // Widen from the most specific tag to the bare language: zh-Hant-TW → zh-Hant → zh.
    var candidate = locale.identifier.replacingOccurrences(of: "_", with: "-")
    while !candidate.isEmpty {
      if let match = available.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }),
        let path = main.path(forResource: match, ofType: "lproj"),
        let bundle = Bundle(path: path)
      {
        return bundle
      }
      guard let separator = candidate.lastIndex(of: "-") else { break }
      candidate = String(candidate[candidate.startIndex..<separator])
    }

    return main
  }

  private static func localizedDurationString(years: Int, months: Int, days: Int, includeYears: Bool, locale: Locale) -> String? {
    let formatter = DateComponentsFormatter()
    formatter.calendar = calendar(for: locale)
    formatter.unitsStyle = .full
    formatter.zeroFormattingBehavior = .dropAll
    formatter.maximumUnitCount = includeYears ? 3 : 2
    formatter.allowedUnits = includeYears ? [.year, .month, .day] : [.month, .day]

    var components = DateComponents()
    if includeYears {
      components.year = years
    }
    components.month = months
    components.day = days

    return formatter.string(from: components)
  }

  /// Generate countdown text from now to target date
  /// Returns the formatted countdown string (e.g., "Tomorrow", "in 2 days", etc.)
  /// For entries 1 calendar day away, shows "Tomorrow" since Joodle tracks days, not timestamps
  /// - Parameter locale: the language to render in. Pass the SwiftUI `\.locale`
  ///   environment value so the result follows the in-app language override.
  static func countdownText(from now: Date, to targetDate: Date, locale: Locale = defaultLocale) -> String {
    let calendar = Self.calendar(for: locale)

    // Calculate calendar day difference (ignoring time of day)
    let startOfToday = calendar.startOfDay(for: now)
    let startOfTarget = calendar.startOfDay(for: targetDate)
    let calendarDayDiff = calendar.dateComponents([.day], from: startOfToday, to: startOfTarget).day ?? 0

    // Only future dates have countdown text
    guard calendarDayDiff > 0 else { return "" }

    // Use time-based components for months and years display
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: now,
      to: targetDate
    )

    guard let years = components.year,
      let months = components.month,
      let days = components.day
    else { return "" }

    // More than a year: show year + month + day
    if years > 0 {
      if let duration = localizedDurationString(years: years, months: months, days: days, includeYears: true, locale: locale) {
        return String(localized: "in \(duration)", bundle: localizationBundle(for: locale), locale: locale)
      }
      return ""
    }

    // More than a month but less than a year: show month + day
    if months > 0 {
      if let duration = localizedDurationString(years: years, months: months, days: days, includeYears: false, locale: locale) {
        return String(localized: "in \(duration)", bundle: localizationBundle(for: locale), locale: locale)
      }
      return ""
    }

    // Less than a month: use calendar day difference for accuracy
    // This ensures D+1 shows "Tomorrow" and D+2 shows "in 2 days"
    // regardless of the current time of day
    if calendarDayDiff > 1 {
      let relativeFormatter = RelativeDateTimeFormatter()
      relativeFormatter.locale = locale
      relativeFormatter.calendar = calendar
      relativeFormatter.unitsStyle = .full
      return relativeFormatter.localizedString(for: startOfTarget, relativeTo: startOfToday)
    }

    // 1 calendar day away: show "Tomorrow"
    // This is because Joodle tracks entries by day, not by exact timestamp
    if calendarDayDiff == 1 {
      return String(localized: "Tomorrow", bundle: localizationBundle(for: locale), locale: locale)
    }

    return ""
  }

  /// Format date as "MMM d, yyyy" (e.g., "Jan 15, 2025")
  /// - Parameter locale: the language to render in. Pass the SwiftUI `\.locale`
  ///   environment value so the result follows the in-app language override.
  static func dateText(for date: Date, locale: Locale = defaultLocale) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar(for: locale)
    formatter.locale = locale
    formatter.setLocalizedDateFormatFromTemplate("yMMMd")
    return formatter.string(from: date)
  }

  /// Check if we need real-time updates for countdown
  /// Returns false since we only show "Tomorrow" for sub-day countdowns,
  /// which doesn't require frequent updates
  static func needsRealTimeUpdates(from now: Date, to targetDate: Date) -> Bool {
    // No need for real-time updates since we show "Tomorrow" for <= 1 day
    // and day-based countdown for > 1 day
    return false
  }

  /// Calculate the appropriate timer interval based on time remaining
  /// Returns the interval in seconds for how often to update the countdown
  /// Since we only track days (not hours/minutes/seconds), we update less frequently
  static func timerInterval(from now: Date, to targetDate: Date) -> TimeInterval {
    // Update once per hour is sufficient since we only show day-level precision
    // or "Tomorrow" for sub-day countdowns
    return 3600.0
  }
}
