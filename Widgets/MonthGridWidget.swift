//
//  MonthGridWidget.swift
//  Widgets
//
//  Created by Joodle
//

import SwiftUI
import WidgetKit

// MARK: - Timeline Provider

struct MonthGridWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> MonthGridTimelineEntry {
    let calendar = Calendar.current
    let now = Date()
    return MonthGridTimelineEntry(
      date: now,
      year: calendar.component(.year, from: now),
      month: calendar.component(.month, from: now),
      startOfWeek: "sunday",
      dayEntries: [],
      hasPremiumAccess: true
    )
  }

  func getSnapshot(in context: Context, completion: @escaping (MonthGridTimelineEntry) -> Void) {
    completion(buildEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<MonthGridTimelineEntry>) -> Void) {
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

  private func buildEntry() -> MonthGridTimelineEntry {
    let calendar = Calendar.current
    let now = Date()
    let hasPremiumAccess = WidgetDataManager.shared.hasPremiumAccess()
    let startOfWeek = WidgetDataManager.shared.loadStartOfWeek()
    let year = calendar.component(.year, from: now)
    let month = calendar.component(.month, from: now)
    let dayEntries = hasPremiumAccess ? loadEntriesForMonth(year: year, month: month) : []

    return MonthGridTimelineEntry(
      date: now,
      year: year,
      month: month,
      startOfWeek: startOfWeek,
      dayEntries: dayEntries,
      hasPremiumAccess: hasPremiumAccess
    )
  }

  private func loadEntriesForMonth(year: Int, month: Int) -> [WidgetDayEntry] {
    let prefix = String(format: "%04d-%02d", year, month)
    return WidgetDataManager.shared.loadAllEntries()
      .filter { $0.dateString.hasPrefix(prefix) }
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
}

// MARK: - Timeline Entry

struct MonthGridTimelineEntry: TimelineEntry {
  let date: Date
  let year: Int
  let month: Int
  let startOfWeek: String
  let dayEntries: [WidgetDayEntry]
  let hasPremiumAccess: Bool
}

// MARK: - Widget View

struct MonthGridWidgetView: View {
  var entry: MonthGridWidgetProvider.Entry

  var body: some View {
    if !entry.hasPremiumAccess {
      MonthGridWidgetLockedView()
        .widgetURL(URL(string: "joodle://paywall"))
        .containerBackground(for: .widget) {
          Color(UIColor.systemBackground)
        }
    } else {
      MonthGridWidgetContentView(
        year: entry.year,
        month: entry.month,
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

struct MonthGridWidgetLockedView: View {
  private var themeColor: Color {
    WidgetDataManager.shared.loadThemeColor()
  }

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "crown.fill")
        .font(.appFont(size: 40))
        .foregroundStyle(
          LinearGradient(
            colors: [themeColor.opacity(0.5), themeColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )

      VStack(spacing: 4) {
        Text("Joodle Pro")
          .font(.appHeadline())
          .foregroundColor(.primary)

        Text("Upgrade to unlock widgets")
          .font(.appSubheadline())
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding()
  }
}

// MARK: - Content View

struct MonthGridWidgetContentView: View {
  let year: Int
  let month: Int
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

  private var monthName: String {
    let formatter = DateFormatter()
    formatter.locale = appLocale
    formatter.dateFormat = "MMMM"
    let components = DateComponents(year: year, month: month, day: 1)
    guard let date = Calendar.current.date(from: components) else { return "" }
    return formatter.string(from: date)
  }

  private var daysInMonth: Int {
    let calendar = Calendar.current
    guard let date = calendar.date(from: DateComponents(year: year, month: month)) else { return 30 }
    return calendar.range(of: .day, in: .month, for: date)?.count ?? 30
  }

  private var leadingEmptyCells: Int {
    let calendar = Calendar.current
    guard let firstOfMonth = calendar.date(
      from: DateComponents(year: year, month: month, day: 1)
    ) else { return 0 }
    let weekday = calendar.component(.weekday, from: firstOfMonth)
    if startOfWeek.lowercased() == "sunday" {
      return weekday - 1
    } else {
      return (weekday - 2 + 7) % 7
    }
  }

  private var numberOfRows: Int {
    (leadingEmptyCells + daysInMonth + 6) / 7
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
      let cellSpacing: CGFloat = 3
      let availableWidth = size.width - horizontalPadding * 2
      let cellSize = (availableWidth - cellSpacing * 6) / 7
      let lookup = entriesByDateKey

      VStack(spacing: 18) {
        // Header: year (left) + month name (right)
        HStack {
          Text(String(year))
            .font(.appFont(size: 14))
            .foregroundColor(.primary)
          Spacer()
          Text(monthName)
            .font(.appFont(size: 14))
            .foregroundColor(.primary)
        }
        .padding(.horizontal, horizontalPadding)

        VStack(spacing: 10) {
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

          // Calendar grid
          VStack(spacing: cellSpacing) {
            ForEach(0..<numberOfRows, id: \.self) { rowIndex in
              HStack(spacing: cellSpacing) {
                ForEach(0..<7, id: \.self) { colIndex in
                  let cellIndex = rowIndex * 7 + colIndex
                  let dayNumber = cellIndex - leadingEmptyCells + 1

                  if dayNumber >= 1 && dayNumber <= daysInMonth {
                    let dateString = String(format: "%04d-%02d-%02d", year, month, dayNumber)
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
                          themeColor: WidgetDataManager.shared.doodleStrokeColor(forMonth: month)
                        )
                        .widgetAccentable()
                      }
                    }
                    .frame(width: cellSize, height: cellSize)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                  } else {
                    Color.clear
                      .frame(width: cellSize, height: cellSize)
                  }
                }
              }
              .padding(.horizontal, horizontalPadding)
            }
          }
        }
      
        Spacer(minLength: 0)
      }
      .padding(.top, 8)
    }
  }
}

// MARK: - Widget Configuration

struct MonthGridWidget: Widget {
  let kind: String = "MonthGridWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: MonthGridWidgetProvider()) { entry in
      MonthGridWidgetView(entry: entry)
        .environment(\.locale, WidgetDataManager.shared.loadAppLocale() ?? .current)
    }
    .configurationDisplayName("This Month")
    .description("View this month's Joodles at a glance.")
    .supportedFamilies([.systemLarge])
  }
}

// MARK: - Previews

#Preview("Month Grid - With Entries", as: .systemLarge) {
  MonthGridWidget()
} timeline: {
  MonthGridTimelineEntry(
    date: Date(),
    year: 2026,
    month: 2,
    startOfWeek: "sunday",
    dayEntries: createMockMonthWidgetEntries(year: 2026, month: 2),
    hasPremiumAccess: true
  )
}

#Preview("Month Grid - Monday Start", as: .systemLarge) {
  MonthGridWidget()
} timeline: {
  MonthGridTimelineEntry(
    date: Date(),
    year: 2026,
    month: 2,
    startOfWeek: "monday",
    dayEntries: createMockMonthWidgetEntries(year: 2026, month: 2),
    hasPremiumAccess: true
  )
}

#Preview("Month Grid - Empty", as: .systemLarge) {
  MonthGridWidget()
} timeline: {
  MonthGridTimelineEntry(
    date: Date(),
    year: 2026,
    month: 2,
    startOfWeek: "sunday",
    dayEntries: [],
    hasPremiumAccess: true
  )
}

#Preview("Month Grid - Locked", as: .systemLarge) {
  MonthGridWidget()
} timeline: {
  MonthGridTimelineEntry(
    date: Date(),
    year: 2026,
    month: 2,
    startOfWeek: "sunday",
    dayEntries: [],
    hasPremiumAccess: false
  )
}

// MARK: - Preview Helpers

private func createMockMonthWidgetEntries(year: Int, month: Int) -> [WidgetDayEntry] {
  let calendar = Calendar.current
  guard let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
    return []
  }
  let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
  let daysWithEntries = Set((1...daysInMonth).shuffled().prefix(daysInMonth / 2))

  return daysWithEntries.map { day in
    let dateString = String(format: "%04d-%02d-%02d", year, month, day)
    return WidgetDayEntry(
      dateString: dateString,
      hasText: false,
      hasDrawing: true,
      thumbnail: nil,
      drawingData: createMockDrawingData()
    )
  }
}
