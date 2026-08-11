//
//  TodayDoodleWidget.swift
//  Widgets
//
//  Created by Widget Extension
//

import SwiftUI
import WidgetKit

// MARK: - Timeline Provider

struct TodayDoodleProvider: TimelineProvider {
  func placeholder(in context: Context) -> TodayDoodleEntry {
    return TodayDoodleEntry(
      date: Date(),
      todayData: nil,
      hasPremiumAccess: true
    )
  }

  func getSnapshot(in context: Context, completion: @escaping (TodayDoodleEntry) -> Void) {
    let hasPremiumAccess = WidgetDataManager.shared.hasPremiumAccess()
    let todayData = hasPremiumAccess ? getTodayEntry() : nil
    let entry = TodayDoodleEntry(
      date: Date(),
      todayData: todayData,
      hasPremiumAccess: hasPremiumAccess
    )
    completion(entry)
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<TodayDoodleEntry>) -> Void) {
    let currentDate = Date()
    let hasPremiumAccess = WidgetDataManager.shared.hasPremiumAccess()
    let todayData = hasPremiumAccess ? getTodayEntry() : nil

    let entry = TodayDoodleEntry(
      date: currentDate,
      todayData: todayData,
      hasPremiumAccess: hasPremiumAccess
    )

    // Refresh every 15 minutes so widgets stay reasonably current for all users,
    // or at midnight to flip to the new day — whichever comes first.
    let calendar = Calendar.current
    let nextMidnight = calendar.date(
      byAdding: .day,
      value: 1,
      to: calendar.startOfDay(for: currentDate)
    ) ?? currentDate
    let fifteenMinutesLater = currentDate.addingTimeInterval(900)
    let nextUpdate = min(nextMidnight, fifteenMinutesLater)

    let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
    completion(timeline)
  }

  private func getTodayEntry() -> TodayDoodleData? {
    let entries = WidgetDataManager.shared.loadAllEntries()

    // Get today's dateString for comparison (timezone-agnostic)
    let todayComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    let todayString = String(format: "%04d-%02d-%02d", todayComponents.year ?? 0, todayComponents.month ?? 1, todayComponents.day ?? 1)

    // Find today's entry using dateString comparison (timezone-agnostic)
    let todayEntry = entries.first { entry in
      entry.dateString == todayString && (entry.hasText || entry.hasDrawing)
    }

    guard let entry = todayEntry else {
      return nil
    }

    // Two-tier fallback: file-based drawing → inline UserDefaults (backward compat) → nil.
    // When the day has multiple doodles, pick a random one per refresh tick (unseeded,
    // so it varies each refresh — the desired behavior).
    let drawingData: Data? = {
      guard entry.hasDrawing else { return nil }
      let index = entry.drawingCount > 1 ? Int.random(in: 0..<entry.drawingCount) : 0
      return WidgetDataManager.shared.loadDrawingData(for: entry.dateString, index: index)
        ?? entry.drawingData
    }()

    return TodayDoodleData(
      dateString: entry.dateString,
      text: entry.body,
      drawingData: drawingData
    )
  }
}

// MARK: - Timeline Entry

struct TodayDoodleEntry: TimelineEntry {
  let date: Date
  let todayData: TodayDoodleData?
  let hasPremiumAccess: Bool
}

struct TodayDoodleData {
  /// The timezone-agnostic date string in "yyyy-MM-dd" format
  let dateString: String
  let text: String?
  let drawingData: Data?

  /// Computed display date from dateString (for UI components that need Date)
  var date: Date {
    let components = dateString.split(separator: "-")
    if components.count == 3,
       let year = Int(components[0]),
       let month = Int(components[1]),
       let day = Int(components[2]) {
      var dateComponents = DateComponents()
      dateComponents.year = year
      dateComponents.month = month
      dateComponents.day = day
      return Calendar.current.date(from: dateComponents) ?? Date()
    }
    return Date()
  }

  var hasText: Bool {
    text != nil && !text!.isEmpty
  }

  var hasDrawing: Bool {
    drawingData != nil && !drawingData!.isEmpty
  }
}

// MARK: - Widget View

struct TodayDoodleWidgetView: View {
  var entry: TodayDoodleProvider.Entry
  @Environment(\.widgetFamily) var family

  var body: some View {
    // Check subscription status first
    if !entry.hasPremiumAccess {
      TodayDoodleWidgetLockedView(family: family)
        .widgetURL(URL(string: "joodle://paywall"))
        .containerBackground(for: .widget) {
          Color(UIColor.systemBackground)
        }
    } else if let todayData = entry.todayData {
      Group {
        switch family {
        case .systemSmall:
          SmallTodayDoodleView(todayData: todayData)
        case .systemMedium:
          MediumTodayDoodleView(todayData: todayData)
        case .systemLarge:
          LargeTodayDoodleView(todayData: todayData)
        case .accessoryCircular:
          CircularTodayDoodleView(todayData: todayData)
        default:
          NoTodayDoodleView(family: family)
        }
      }
      .widgetURL(URL(string: "joodle://date/\(todayData.dateString)"))
    } else {
      NoTodayDoodleView(family: family)
        .widgetURL(URL(string: "joodle://today"))
    }
  }
}

// MARK: - Today Doodle Widget Locked View (Premium Required)

struct TodayDoodleWidgetLockedView: View {
  let family: WidgetFamily

  private var themeColor: Color {
    WidgetDataManager.shared.loadThemeColor()
  }

  var body: some View {
    VStack(spacing: family == .systemLarge ? 16 : 8) {
      Image(systemName: "crown.fill")
        .font(.appFont(size: family == .systemLarge ? 40 : 24))
        .foregroundStyle(
          LinearGradient(
            colors: [themeColor.opacity(0.5), themeColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )

      if family != .accessoryCircular {
        VStack(spacing: 4) {
          Text("Joodle Pro")
            .font(family == .systemLarge ? .appHeadline() : .appCaption(weight: .bold))
            .foregroundColor(.primary)

          Text("Upgrade to unlock widgets")
            .font(family == .systemLarge ? .appSubheadline() : .appCaption2())
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
        }
      } else {
        VStack(alignment: .center) {
          Text("Unlock")
            .font(.appFont(size: 8))
            .foregroundColor(.primary)
          Text("Pro")
            .font(.appFont(size: 8))
            .foregroundColor(.primary)
        }
      }
    }
    .padding()
  }
}

// MARK: - Circular (Lock Screen) Widget View

struct CircularTodayDoodleView: View {
  let todayData: TodayDoodleData

  private var themeColor: Color {
    WidgetDataManager.shared.loadThemeColor()
  }

  var body: some View {
    if todayData.hasDrawing, let drawingData = todayData.drawingData {
      ZStack {
        TodayDoodleJoodleView(drawingData: drawingData, family: .accessoryCircular)
          .padding(8)
      }
      .containerBackground(for: .widget) {
        Color.clear
      }
    } else {
      ZStack {
        Image(systemName: "scribble.variable")
          .font(.appFont(size: 24))
          .foregroundStyle(.secondary)
      }
      .containerBackground(for: .widget) {
        Color.clear
      }
    }
  }
}

// MARK: - Small Widget View

struct SmallTodayDoodleView: View {
  let todayData: TodayDoodleData

  var body: some View {
    VStack(spacing: 0) {
      VStack {
        Spacer()
        // Joodle or text content
        if todayData.hasDrawing, let drawingData = todayData.drawingData {
          TodayDoodleJoodleView(drawingData: drawingData, family: .systemSmall)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if todayData.hasText, let text = todayData.text {
          Text(text)
            .font(.appFont(size: 12))
            .lineLimit(4)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
        }
        Spacer()
      }
    }
    .containerBackground(for: .widget) {
      Color(UIColor.systemBackground)
    }
  }
}

// MARK: - Medium Widget View

struct MediumTodayDoodleView: View {
  let todayData: TodayDoodleData

  var body: some View {
    VStack(spacing: 0) {
      // Top bar with date
      HStack {
        Text(formatDate(todayData.date))
          .font(.appFont(size: 12))
          .foregroundColor(.secondary)
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 8)

      // Main content area
      HStack(spacing: 12) {
        // Left side: Joodle or placeholder
        if todayData.hasDrawing, let drawingData = todayData.drawingData {
          TodayDoodleJoodleView(drawingData: drawingData, family: .systemMedium)
            .frame(width: 80, height: 80)
            .padding(10)
        } else {
          Image(systemName: "scribble.variable")
            .font(.appFont(size: 40))
            .foregroundColor(.secondary.opacity(0.3))
            .frame(width: 80, height: 80)
            .padding(10)
        }

        // Right side: Text or placeholder
        if todayData.hasText, let text = todayData.text {
          Text(text)
            .font(.appFont(size: 12))
            .lineLimit(5)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Text("No notes for today.")
            .font(.appFont(size: 12))
            .foregroundColor(.secondary.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.bottom, 12)
    }
    .containerBackground(for: .widget) {
      Color(UIColor.systemBackground)
    }
  }

  private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = WidgetDataManager.shared.loadAppLocale() ?? .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }
}

// MARK: - Large Widget View

struct LargeTodayDoodleView: View {
  let todayData: TodayDoodleData

  var body: some View {
    VStack(spacing: 8) {
      VStack {
        Spacer()
        // Joodle or text content
        if todayData.hasDrawing, let drawingData = todayData.drawingData {
          TodayDoodleJoodleView(drawingData: drawingData, family: .systemLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if todayData.hasText, let text = todayData.text {
          Text(text)
            .font(.appFont(size: 20))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
        }
        Spacer()
      }
    }
    .containerBackground(for: .widget) {
      Color(UIColor.systemBackground)
    }
    .padding()
  }
}

// MARK: - Joodle View

struct TodayDoodleJoodleView: View {
  let drawingData: Data
  let family: WidgetFamily

  /// Stroke color for today's doodle — the current month's color under the rainbow theme.
  private var themeColor: Color {
    WidgetDataManager.shared.doodleStrokeColor(forMonth: Calendar.current.component(.month, from: Date()))
  }

  var body: some View {
    Canvas { context, size in
      let paths = decodePaths(from: drawingData)

      // Calculate scale to fit drawing in widget
      let scale = min(size.width / DOODLE_CANVAS_SIZE, size.height / DOODLE_CANVAS_SIZE)
      let offsetX = (size.width - DOODLE_CANVAS_SIZE * scale) / 2
      let offsetY = (size.height - DOODLE_CANVAS_SIZE * scale) / 2

      // Use consistent line width (5.0) that scales proportionally
      // This ensures the doodle looks "normal" regardless of widget size
      let lineWidth: CGFloat = 5.0 * scale

      for pathData in paths {
        var scaledPath = Path()

        if pathData.isDot && pathData.points.count >= 1 {
          // Draw dot as filled circle (not stroked, to avoid hollow appearance)
          let center = pathData.points[0]
          let scaledCenter = CGPoint(
            x: center.x * scale + offsetX,
            y: center.y * scale + offsetY
          )
          // Dot radius should match half the line width for visual consistency
          let dotRadius: CGFloat = lineWidth / 2
          scaledPath.addEllipse(
            in: CGRect(
              x: scaledCenter.x - dotRadius,
              y: scaledCenter.y - dotRadius,
              width: dotRadius * 2,
              height: dotRadius * 2
            ))
          // Fill the dot instead of stroking to avoid hollow circle appearance
          context.fill(scaledPath, with: .color(themeColor))
        } else if pathData.points.count > 1 {
          // Draw path
          let firstPoint = pathData.points[0]
          let scaledFirst = CGPoint(
            x: firstPoint.x * scale + offsetX,
            y: firstPoint.y * scale + offsetY
          )
          scaledPath.move(to: scaledFirst)

          for point in pathData.points.dropFirst() {
            let scaledPoint = CGPoint(
              x: point.x * scale + offsetX,
              y: point.y * scale + offsetY
            )
            scaledPath.addLine(to: scaledPoint)
          }
          context.stroke(
            scaledPath,
            with: .color(themeColor),
            style: StrokeStyle(
              lineWidth: lineWidth,
              lineCap: .round,
              lineJoin: .round
            )
          )
        }
      }
    }
  }

  private func decodePaths(from data: Data) -> [PathData] {
    do {
      return try JSONDecoder().decode([PathData].self, from: data)
    } catch {
      print("Failed to decode drawing: \(error)")
      return []
    }
  }

  struct PathData: Codable {
    let points: [CGPoint]
    let isDot: Bool
  }
}

// MARK: - No Today Doodle View

struct NoTodayDoodleView: View {
  let family: WidgetFamily

  var body: some View {
    if family == .accessoryCircular {
      ZStack {
        Circle()
          .strokeBorder(lineWidth: 2)
          .foregroundStyle(.secondary.opacity(0.3))

        Image(systemName: "scribble.variable")
          .font(.appFont(size: 24))
          .foregroundStyle(.secondary)
      }
      .containerBackground(for: .widget) {
        Color.clear
      }
    } else {
      VStack(alignment: .center, spacing: 8) {
        Image(systemName: "scribble.variable")
          .font(.appFont(size: family == .systemSmall ? 32 : family == .systemMedium ? 40 : 48))
          .foregroundColor(.secondary.opacity(0.3))
        Text("No Joodle today")
          .font(family == .systemSmall ? .appFont(size: 11) : family == .systemMedium ? .appFont(size: 11) : .appFont(size: 15))
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding()
      .containerBackground(for: .widget) {
        Color(UIColor.systemBackground)
      }
    }
  }
}

// MARK: - Widget Configuration

struct TodayDoodleWidget: Widget {
  let kind: String = "TodayDoodleWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: TodayDoodleProvider()) { entry in
      TodayDoodleWidgetView(entry: entry)
        .environment(\.locale, WidgetDataManager.shared.loadAppLocale() ?? .current)
    }
    .configurationDisplayName("Today's Joodle")
    .description("Shows today's Joodle entry.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular])
  }
}
