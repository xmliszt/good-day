//
//  WeekGridWidget.swift
//  Widgets
//
//  Created by Joodle
//

import SwiftUI
import WidgetKit

// MARK: - Timeline Provider

struct WeekGridWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> WeekGridTimelineEntry {
    let calendar = Calendar.current
    let now = Date()
    return WeekGridTimelineEntry(
      date: now,
      year: calendar.component(.year, from: now),
      weekDayDateStrings: [],
      startOfWeek: "sunday",
      dayEntries: [],
      hasPremiumAccess: true
    )
  }

  func getSnapshot(in context: Context, completion: @escaping (WeekGridTimelineEntry) -> Void) {
    completion(buildEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<WeekGridTimelineEntry>) -> Void) {
    let entry = buildEntry()

    // Refresh every 15 minutes so widgets stay reasonably current for all users,
    // or at midnight to flip to the new day — whichever comes first.
    let calendar = Calendar.current
    let now = Date()
    let nextMidnight = calendar.date(
      byAdding: .day,
      value: 1,
      to: calendar.startOfDay(for: now)
    )!
    let fifteenMinutesLater = now.addingTimeInterval(900)
    let nextUpdate = min(nextMidnight, fifteenMinutesLater)

    let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
    completion(timeline)
  }

  private func buildEntry() -> WeekGridTimelineEntry {
    let calendar = Calendar.current
    let now = Date()
    let hasPremiumAccess = WidgetDataManager.shared.hasPremiumAccess()
    let startOfWeek = WidgetDataManager.shared.loadStartOfWeek()

    let weekStart = weekStartDate(for: now, startOfWeek: startOfWeek)
    let year = calendar.component(.year, from: weekStart)

    let weekDayStrings = (0..<7).compactMap { offset -> String? in
      guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
      return dateString(from: date)
    }

    let dayEntries = hasPremiumAccess ? loadEntriesForWeek(dayDateStrings: weekDayStrings) : []

    return WeekGridTimelineEntry(
      date: now,
      year: year,
      weekDayDateStrings: weekDayStrings,
      startOfWeek: startOfWeek,
      dayEntries: dayEntries,
      hasPremiumAccess: hasPremiumAccess
    )
  }

  private func loadEntriesForWeek(dayDateStrings: [String]) -> [WidgetDayEntry] {
    let daySet = Set(dayDateStrings)
    return WidgetDataManager.shared.loadAllEntries()
      .filter { daySet.contains($0.dateString) }
      .map { entry in
        // Rotate through the day's doodles: pick a random slot each refresh so a
        // multi-doodle day cycles across the ~15-min timeline ticks. Two-tier
        // fallback: per-slot file → inline UserDefaults (backward compat) → nil.
        let slot = entry.drawingCount > 1 ? Int.random(in: 0..<entry.drawingCount) : 0
        let drawingData: Data? = entry.hasDrawing
          ? (WidgetDataManager.shared.loadDrawingData(for: entry.dateString, index: slot) ?? entry.drawingData)
          : nil
        return WidgetDayEntry(
          dateString: entry.dateString,
          hasText: entry.hasText,
          hasDrawing: entry.hasDrawing,
          thumbnail: entry.thumbnail,
          drawingData: drawingData
        )
      }
  }

  private func weekStartDate(for date: Date, startOfWeek: String) -> Date {
    let calendar = Calendar.current
    let weekday = calendar.component(.weekday, from: date)
    let offset: Int
    if startOfWeek.lowercased() == "monday" {
      offset = (weekday - 2 + 7) % 7
    } else {
      offset = weekday - 1
    }
    return calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: date))!
  }

  private func dateString(from date: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
  }
}

// MARK: - Timeline Entry

struct WeekGridTimelineEntry: TimelineEntry {
  let date: Date
  let year: Int
  let weekDayDateStrings: [String]
  let startOfWeek: String
  let dayEntries: [WidgetDayEntry]
  let hasPremiumAccess: Bool
}

// MARK: - Widget View

struct WeekGridWidgetView: View {
  var entry: WeekGridWidgetProvider.Entry

  var body: some View {
    if !entry.hasPremiumAccess {
      WeekGridWidgetLockedView()
        .widgetURL(URL(string: "joodle://paywall"))
        .containerBackground(for: .widget) {
          Color(UIColor.systemBackground)
        }
    } else {
      WeekGridWidgetContentView(
        year: entry.year,
        weekDayDateStrings: entry.weekDayDateStrings,
        startOfWeek: entry.startOfWeek,
        entries: entry.dayEntries
      )
      .widgetURL(URL(string: "joodle://today"))
      .containerBackground(for: .widget) {
        Color(UIColor.systemBackground)
      }
    }
  }
}

// MARK: - Locked View

struct WeekGridWidgetLockedView: View {
  private var themeColor: Color {
    WidgetDataManager.shared.loadThemeColor()
  }

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "crown.fill")
        .font(.appFont(size: 28))
        .foregroundStyle(
          LinearGradient(
            colors: [themeColor.opacity(0.5), themeColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )

      VStack(spacing: 4) {
        Text("Joodle Pro")
          .font(.appCaption(weight: .bold))
          .foregroundColor(.primary)

        Text("Upgrade to unlock widgets")
          .font(.appCaption2())
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding()
  }
}

// MARK: - Content View

struct WeekGridWidgetContentView: View {
  let year: Int
  let weekDayDateStrings: [String]
  let startOfWeek: String
  let entries: [WidgetDayEntry]

  @Environment(\.widgetRenderingMode) var widgetRenderingMode

  private var themeColor: Color {
    WidgetDataManager.shared.loadThemeColor()
  }

  private var appLocale: Locale {
    WidgetDataManager.shared.loadAppLocale() ?? .current
  }

  private var weekdayLabels: [String] {
    var calendar = Calendar.current
    calendar.locale = appLocale
    let symbols = calendar.veryShortWeekdaySymbols
    return startOfWeek.lowercased() == "monday"
      ? Array(symbols[1...]) + [symbols[0]]
      : symbols
  }

  /// Format the date range string, e.g. "Feb 16 – 22" or "Feb 28 – Mar 6"
  private var dateRangeString: String {
    guard let firstStr = weekDayDateStrings.first,
          let lastStr = weekDayDateStrings.last else { return "" }

    let firstDate = dateFromString(firstStr)
    let lastDate = dateFromString(lastStr)

    let calendar = Calendar.current
    let startMonth = calendar.component(.month, from: firstDate)
    let endMonth = calendar.component(.month, from: lastDate)

    let monthDayFormatter = DateFormatter()
    monthDayFormatter.locale = appLocale
    monthDayFormatter.setLocalizedDateFormatFromTemplate("MMMd")

    if startMonth == endMonth {
      let dayFormatter = DateFormatter()
      dayFormatter.locale = appLocale
      dayFormatter.setLocalizedDateFormatFromTemplate("d")
      return "\(monthDayFormatter.string(from: firstDate)) – \(dayFormatter.string(from: lastDate))"
    } else {
      return "\(monthDayFormatter.string(from: firstDate)) – \(monthDayFormatter.string(from: lastDate))"
    }
  }

  private var entriesByDateKey: [String: WidgetDayEntry] {
    var lookup: [String: WidgetDayEntry] = [:]
    lookup.reserveCapacity(entries.count)
    for entry in entries {
      lookup[entry.dateString] = entry
    }
    return lookup
  }

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let horizontalPadding: CGFloat = 12
      let cellSpacing: CGFloat = 4
      let availableWidth = size.width - horizontalPadding * 2
      let cellSize = (availableWidth - cellSpacing * 6) / 7
      let lookup = entriesByDateKey

      VStack(spacing: 18) {
        // Header: year (left), date range (right)
        HStack {
          Text(String(year))
            .font(.appFont(size: 14))
            .foregroundColor(.primary)
          Spacer()
          Text("This Week")
            .font(.appFont(size: 14))
            .foregroundColor(.primary)
        }
        .padding(.horizontal, horizontalPadding)

        VStack(spacing: 6) {
          // Weekday labels
          HStack(spacing: cellSpacing) {
            ForEach(0..<7, id: \.self) { index in
              Text(weekdayLabels[index])
                .font(.appFont(size: 10))
                .foregroundColor(.secondary)
                .frame(width: cellSize)
            }
          }
          .padding(.horizontal, horizontalPadding)

          // Doodle cells (single row of 7)
          HStack(spacing: cellSpacing) {
            ForEach(0..<min(7, weekDayDateStrings.count), id: \.self) { index in
              let dateString = weekDayDateStrings[index]
              let dayEntry = lookup[dateString]

              ZStack {
                RoundedRectangle(cornerRadius: 4)
                  .fill(
                    widgetRenderingMode == .fullColor
                      ? Color(UIColor.secondarySystemBackground)
                      : Color.white.opacity(0.1)
                  )

                if let dayEntry = dayEntry, dayEntry.hasDrawing,
                   let drawingData = dayEntry.drawingData {
                  WidgetGridDoodleCanvas(
                    drawingData: drawingData,
                    themeColor: WidgetDataManager.shared.doodleStrokeColor(
                      forMonth: WidgetDataManager.shared.month(fromDateString: dateString)
                    )
                  )
                  .widgetAccentable()
                }
              }
              .frame(width: cellSize, height: cellSize)
              .clipShape(RoundedRectangle(cornerRadius: 4))
            }
          }
          .padding(.horizontal, horizontalPadding)
        }

        Spacer()
      }
      .padding(.top, 8)
    }
  }

  private func dateFromString(_ dateString: String) -> Date {
    let components = dateString.split(separator: "-")
    guard components.count == 3,
          let year = Int(components[0]),
          let month = Int(components[1]),
          let day = Int(components[2]) else { return Date() }
    return Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
  }
}

// MARK: - Widget Configuration

struct WeekGridWidget: Widget {
  let kind: String = "WeekGridWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: WeekGridWidgetProvider()) { entry in
      WeekGridWidgetView(entry: entry)
        .environment(\.locale, WidgetDataManager.shared.loadAppLocale() ?? .current)
    }
    .configurationDisplayName("This Week")
    .description("View this week's Joodles at a glance.")
    .supportedFamilies([.systemMedium])
  }
}

// MARK: - Previews

#Preview("Week Grid - With Entries", as: .systemMedium) {
  WeekGridWidget()
} timeline: {
  WeekGridTimelineEntry(
    date: Date(),
    year: 2026,
    weekDayDateStrings: ["2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20", "2026-02-21", "2026-02-22"],
    startOfWeek: "monday",
    dayEntries: createMockWeekWidgetEntries(),
    hasPremiumAccess: true
  )
}

#Preview("Week Grid - Empty", as: .systemMedium) {
  WeekGridWidget()
} timeline: {
  WeekGridTimelineEntry(
    date: Date(),
    year: 2026,
    weekDayDateStrings: ["2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20", "2026-02-21", "2026-02-22"],
    startOfWeek: "sunday",
    dayEntries: [],
    hasPremiumAccess: true
  )
}

#Preview("Week Grid - Locked", as: .systemMedium) {
  WeekGridWidget()
} timeline: {
  WeekGridTimelineEntry(
    date: Date(),
    year: 2026,
    weekDayDateStrings: [],
    startOfWeek: "sunday",
    dayEntries: [],
    hasPremiumAccess: false
  )
}

// MARK: - Preview Helpers

private func createMockWeekWidgetEntries() -> [WidgetDayEntry] {
  // Create entries for some days: Mon, Wed, Thu, Sat
  return ["2026-02-16", "2026-02-18", "2026-02-19", "2026-02-21"].map { dateString in
    WidgetDayEntry(
      dateString: dateString,
      hasText: false,
      hasDrawing: true,
      thumbnail: nil,
      drawingData: createMockDrawingData()
    )
  }
}
