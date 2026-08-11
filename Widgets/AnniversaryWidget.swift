//
//  AnniversaryWidget.swift
//  Widgets
//
//  Created by Widget Extension
//

import AppIntents
import SwiftUI
import WidgetKit
import Foundation

// MARK: - Constants

private let kRandomAnniversaryID = "random_anniversary"

/// Subtitle for the "random anniversary" option in the widget configuration picker.
///
/// The picker is an AppIntents surface: the system resolves it in the device
/// language, the same as the sibling `DisplayRepresentation` titles. It therefore
/// does not follow Joodle's in-app language override the way the widget body does.
private var randomAnniversaryPreview: String {
  String(localized: "🎲 Random anniversary (changes daily)")
}

// MARK: - Anniversary Entry Entity

struct AnniversaryEntryEntity: AppEntity {
  let id: String
  /// The timezone-agnostic date string in "yyyy-MM-dd" format
  let dateString: String?
  let preview: String

  /// Computed display date from dateString (for UI components that need Date)
  var date: Date? {
    guard let dateString = dateString else { return nil }
    let components = dateString.split(separator: "-")
    guard components.count == 3,
          let year = Int(components[0]),
          let month = Int(components[1]),
          let day = Int(components[2]) else { return nil }
    var dateComponents = DateComponents()
    dateComponents.year = year
    dateComponents.month = month
    dateComponents.day = day
    return Calendar.current.date(from: dateComponents)
  }

  var displayRepresentation: DisplayRepresentation {
    if let dateString = dateString {
      // Regular anniversary with date
      return DisplayRepresentation(
        title: "\(formatDateString(dateString))",
        subtitle: "\(preview)"
      )
    } else {
      // Random anniversary option
      return DisplayRepresentation(title: "Random", subtitle: "\(preview)")
    }
  }

  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Anniversary"
  static var defaultQuery = AnniversaryEntryQuery()

  private func formatDateString(_ dateString: String) -> String {
    guard let date = self.date else { return dateString }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }
}

// MARK: - Anniversary Entry Query

struct AnniversaryEntryQuery: EntityQuery, EntityStringQuery {
  func entities(for identifiers: [AnniversaryEntryEntity.ID]) async throws
    -> [AnniversaryEntryEntity]
  {
    let randomEntity = AnniversaryEntryEntity(
      id: kRandomAnniversaryID,
      dateString: nil,
      preview: randomAnniversaryPreview
    )

    var results: [AnniversaryEntryEntity] = []
    if identifiers.contains(kRandomAnniversaryID) {
      results.append(randomEntity)
    }

    let allEntries = loadFutureAnniversaries()
    results += allEntries.filter { identifiers.contains($0.id) }

    return results
  }

  func suggestedEntities() async throws -> [AnniversaryEntryEntity] {
    let randomEntity = AnniversaryEntryEntity(
      id: kRandomAnniversaryID,
      dateString: nil,
      preview: randomAnniversaryPreview
    )
    return [randomEntity] + loadFutureAnniversaries()
  }

  func entities(matching string: String) async throws -> [AnniversaryEntryEntity] {
    let randomEntity = AnniversaryEntryEntity(
      id: kRandomAnniversaryID,
      dateString: nil,
      preview: randomAnniversaryPreview
    )

    let allEntries = loadFutureAnniversaries()
    let lowercasedString = string.lowercased()

    var results: [AnniversaryEntryEntity] = []

    // Check if random entity matches
    if "random".contains(lowercasedString) || randomEntity.preview.lowercased().contains(lowercasedString) {
      results.append(randomEntity)
    }

    // Add matching anniversaries
    results += allEntries.filter { entity in
      entity.preview.lowercased().contains(lowercasedString)
        || formatDate(entity.date!).lowercased().contains(lowercasedString)
    }

    return results
  }

  private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }

  private func loadFutureAnniversaries() -> [AnniversaryEntryEntity] {
    let entries = WidgetDataManager.shared.loadAllEntries()

    // Get today's dateString for comparison (timezone-agnostic)
    let todayComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    let todayString = String(format: "%04d-%02d-%02d", todayComponents.year ?? 0, todayComponents.month ?? 1, todayComponents.day ?? 1)

    // Filter future entries that have either text or drawing
    // Using dateString comparison ensures timezone-agnostic behavior
    let futureEntries = entries.filter { entry in
      entry.dateString > todayString && (entry.hasText || entry.hasDrawing)
    }

    // Sort by dateString (lexicographic order works for yyyy-MM-dd format)
    let sortedEntries = futureEntries.sorted { $0.dateString < $1.dateString }

    // Convert to entities using dateString as the stable identifier
    return sortedEntries.map { entry in
      let preview = makePreview(for: entry)
      return AnniversaryEntryEntity(
        id: entry.dateString,  // Use dateString as stable ID
        dateString: entry.dateString,
        preview: preview
      )
    }
  }

  private func makePreview(for entry: WidgetEntryData) -> String {
    // If have text, show text
    if let text = entry.body, !text.isEmpty {
      // Show first 40 characters of text
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.count > 40 {
        return String(trimmed.prefix(40)) + "..."
      }
      return trimmed
    }
    // Otherwise, only has drawing, show an emoji
    else if entry.hasDrawing {
      return "🎨"
    }
    // This is not possible, a future entry in this list should have at least either text or drawing
    else {
      fatalError("Future entry in anniversary list must have either text or drawing")
    }
  }
}

// MARK: - Configuration Intent

struct AnniversaryOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [AnniversaryEntryEntity] {
        let query = AnniversaryEntryQuery()
        return try await query.suggestedEntities()
    }
}

struct AnniversaryConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Anniversary"
    static var description = IntentDescription("Select an anniversary to display.")

    @Parameter(
      title: "Anniversary",
      description: "Choose an anniversary to display in the widget.",
      default: nil
    )
    var selectedEntry: AnniversaryEntryEntity?
}

// MARK: - Timeline Provider

struct AnniversaryProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> AnniversaryEntry {
    return AnniversaryEntry(
      date: Date(),
      anniversaryData: nil,
      configuration: AnniversaryConfigurationIntent(),
      hasPremiumAccess: true
    )
  }

  func snapshot(for configuration: AnniversaryConfigurationIntent, in context: Context) async
    -> AnniversaryEntry
  {
    let hasPremiumAccess = WidgetDataManager.shared.hasPremiumAccess()
    let anniversaryData = hasPremiumAccess ? getAnniversary(for: configuration) : nil
    return AnniversaryEntry(
      date: Date(),
      anniversaryData: anniversaryData,
      configuration: configuration,
      hasPremiumAccess: hasPremiumAccess
    )
  }

  func timeline(for configuration: AnniversaryConfigurationIntent, in context: Context) async
    -> Timeline<AnniversaryEntry>
  {
    let currentDate = Date()
    let hasPremiumAccess = WidgetDataManager.shared.hasPremiumAccess()
    let anniversaryData = hasPremiumAccess ? getAnniversary(for: configuration) : nil

    let entry = AnniversaryEntry(
      date: currentDate,
      anniversaryData: anniversaryData,
      configuration: configuration,
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
    return timeline
  }

  /// Load a doodle for the given entry, picking a random slot when the day has
  /// multiple doodles (unseeded, so it varies per refresh tick).
  /// Two-tier fallback: file-based drawing → inline UserDefaults (backward compat) → nil.
  private func loadDoodleData(for entry: WidgetEntryData) -> Data? {
    guard entry.hasDrawing else { return nil }
    let index = entry.drawingCount > 1 ? Int.random(in: 0..<entry.drawingCount) : 0
    return WidgetDataManager.shared.loadDrawingData(for: entry.dateString, index: index)
      ?? entry.drawingData
  }

  private func getAnniversary(for configuration: AnniversaryConfigurationIntent) -> AnniversaryData?
  {
    let entries = WidgetDataManager.shared.loadAllEntries()

    // Get today's dateString for comparison (timezone-agnostic)
    let todayComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    let todayString = String(format: "%04d-%02d-%02d", todayComponents.year ?? 0, todayComponents.month ?? 1, todayComponents.day ?? 1)

    // Filter future entries using dateString comparison (timezone-agnostic)
    let futureEntries = entries.filter { entry in
      entry.dateString > todayString && (entry.hasText || entry.hasDrawing)
    }

    guard !futureEntries.isEmpty else {
      return nil
    }

    // If user selected a specific entry (not random or nil), use that
    if let selectedEntry = configuration.selectedEntry,
       selectedEntry.id != kRandomAnniversaryID,
       let targetDateString = selectedEntry.dateString {
      // Match by dateString (timezone-agnostic)
      if let matchingEntry = futureEntries.first(where: { $0.dateString == targetDateString }) {
        let drawingData = loadDoodleData(for: matchingEntry)
        return AnniversaryData(
          dateString: matchingEntry.dateString,
          text: matchingEntry.body,
          drawingData: drawingData
        )
      }

      // Selected entry has passed - automatically select the next closest anniversary
      // Sort by dateString and pick the earliest one
      let sortedEntries = futureEntries.sorted { $0.dateString < $1.dateString }
      if let nextEntry = sortedEntries.first {
        let drawingData = loadDoodleData(for: nextEntry)
        return AnniversaryData(
          dateString: nextEntry.dateString,
          text: nextEntry.body,
          drawingData: drawingData
        )
      }
    }

    // Use true random selection (default behavior when nil or when random is selected)
    guard let selectedEntry = futureEntries.randomElement() else {
      return nil
    }

    let drawingData = loadDoodleData(for: selectedEntry)

    return AnniversaryData(
      dateString: selectedEntry.dateString,
      text: selectedEntry.body,
      drawingData: drawingData
    )
  }
}

// MARK: - Timeline Entry

struct AnniversaryEntry: TimelineEntry {
  let date: Date
  let anniversaryData: AnniversaryData?
  let configuration: AnniversaryConfigurationIntent
  let hasPremiumAccess: Bool
}

struct AnniversaryData {
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

struct AnniversaryWidgetView: View {
  var entry: AnniversaryProvider.Entry
  @Environment(\.widgetFamily) var family

  var body: some View {
    // Check subscription status first
    if !entry.hasPremiumAccess {
      AnniversaryWidgetLockedView(family: family)
        .widgetURL(URL(string: "joodle://paywall"))
        .containerBackground(for: .widget) {
          Color(UIColor.systemBackground)
        }
    } else if let anniversaryData = entry.anniversaryData {
      Group {
        switch family {
        case .systemSmall:
          SmallAnniversaryView(anniversaryData: anniversaryData, currentDate: entry.date)
        case .systemMedium:
          MediumAnniversaryView(anniversaryData: anniversaryData, currentDate: entry.date)
        case .systemLarge:
          LargeAnniversaryView(anniversaryData: anniversaryData, currentDate: entry.date)
        default:
          NoAnniversaryView(family: family)
        }
      }
      .widgetURL(URL(string: "joodle://date/\(anniversaryData.dateString)"))
    } else {
      NoAnniversaryView(family: family)
    }
  }
}

// MARK: - Anniversary Widget Locked View (Premium Required)

struct AnniversaryWidgetLockedView: View {
  let family: WidgetFamily

  private var themeColor: Color {
    WidgetDataManager.shared.loadThemeColor()
  }

  var body: some View {
    VStack(spacing: family == .systemLarge ? 16 : (family == .systemMedium ? 12 : 8)) {
      Image(systemName: "crown.fill")
        .font(.appFont(size: family == .systemLarge ? 40 : (family == .systemMedium ? 28 : 24)))
        .foregroundStyle(
          LinearGradient(
            colors: [themeColor.opacity(0.5), themeColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )

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
    }
    .padding()
  }
}

// MARK: - Small Widget View

struct SmallAnniversaryView: View {
  let anniversaryData: AnniversaryData
  let currentDate: Date
  /// Set by `AnniversaryWidget` from the app-group language override, so the
  /// countdown follows the in-app language rather than the device language.
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(spacing: 0) {
      VStack {
        Spacer()
        // Joodle or text content
        if anniversaryData.hasDrawing, let drawingData = anniversaryData.drawingData {
          AnniversaryJoodleView(
            drawingData: drawingData,
            month: WidgetDataManager.shared.month(fromDateString: anniversaryData.dateString)
          )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if anniversaryData.hasText, let text = anniversaryData.text {
          Text(text)
            .font(.appFont(size: 12))
            .lineLimit(4)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
        }
        Spacer()
      }

      Spacer()

      // Countdown text at bottom
      Text(CountdownHelper.countdownText(from: currentDate, to: anniversaryData.date, locale: locale))
        .font(.appFont(size: 10))
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .multilineTextAlignment(.center)
    }
    .containerBackground(for: .widget) {
      Color(UIColor.systemBackground)
    }
  }
}

// MARK: - Medium Widget View

struct MediumAnniversaryView: View {
  let anniversaryData: AnniversaryData
  let currentDate: Date
  /// Set by `AnniversaryWidget` from the app-group language override, so the
  /// date and countdown follow the in-app language rather than the device language.
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(spacing: 0) {
      // Top bar with date and countdown
      HStack {
        Text(CountdownHelper.dateText(for: anniversaryData.date, locale: locale))
          .font(.appFont(size: 12))
          .foregroundColor(.secondary)
        Spacer()
        Text(CountdownHelper.countdownText(from: currentDate, to: anniversaryData.date, locale: locale))
          .font(.appFont(size: 12))
          .foregroundColor(.secondary)
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 8)

      // Main content area
      HStack(spacing: 12) {
        // Left side: Joodle or placeholder
        if anniversaryData.hasDrawing, let drawingData = anniversaryData.drawingData {
          AnniversaryJoodleView(
            drawingData: drawingData,
            month: WidgetDataManager.shared.month(fromDateString: anniversaryData.dateString)
          )
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
        if anniversaryData.hasText, let text = anniversaryData.text {
          Text(text)
            .font(.appFont(size: 12))
            .lineLimit(5)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Text("No notes for this special day.")
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
}

// MARK: - Large Widget View

struct LargeAnniversaryView: View {
  let anniversaryData: AnniversaryData
  let currentDate: Date
  /// Set by `AnniversaryWidget` from the app-group language override, so the
  /// countdown follows the in-app language rather than the device language.
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(spacing: 8) {
      VStack {
        Spacer()
        // Joodle or text content
        if anniversaryData.hasDrawing, let drawingData = anniversaryData.drawingData {
          AnniversaryJoodleView(
            drawingData: drawingData,
            month: WidgetDataManager.shared.month(fromDateString: anniversaryData.dateString)
          )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if anniversaryData.hasText, let text = anniversaryData.text {
          Text(text)
            .font(.appFont(size: 20))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
        }
        Spacer()
      }

      // Countdown text at bottom
      Text(CountdownHelper.countdownText(from: currentDate, to: anniversaryData.date, locale: locale))
        .font(.appFont(size: 16))
        .foregroundColor(.secondary)
        .padding(.horizontal, 16)
    }
    .containerBackground(for: .widget) {
      Color(UIColor.systemBackground)
    }
    .padding()
  }
}

// MARK: - Joodle View

struct AnniversaryJoodleView: View {
  let drawingData: Data
  /// The doodle's month (1-12), used to pick its rainbow color.
  let month: Int

  /// Stroke color for the anniversary doodle — its month's color under the rainbow theme.
  private var themeColor: Color {
    WidgetDataManager.shared.doodleStrokeColor(forMonth: month)
  }

  var body: some View {
    Canvas { context, size in
      let paths = decodePaths(from: drawingData)

      // Calculate scale to fit drawing in widget
      let scale = min(size.width / DOODLE_CANVAS_SIZE, size.height / DOODLE_CANVAS_SIZE)
      let offsetX = (size.width - DOODLE_CANVAS_SIZE * scale) / 2
      let offsetY = (size.height - DOODLE_CANVAS_SIZE * scale) / 2

      for pathData in paths {
        var scaledPath = Path()

        if pathData.isDot && pathData.points.count >= 1 {
          // Draw dot as filled circle
          let center = pathData.points[0]
          let scaledCenter = CGPoint(
            x: center.x * scale + offsetX,
            y: center.y * scale + offsetY
          )
          // Use consistent dot radius (DRAWING_LINE_WIDTH / 2 = 2.5)
          let radius: CGFloat = 2.5 * scale
          scaledPath.addEllipse(
            in: CGRect(
              x: scaledCenter.x - radius,
              y: scaledCenter.y - radius,
              width: radius * 2,
              height: radius * 2
            ))
          // Fill dot instead of stroke to avoid hollow circle appearance
          context.fill(scaledPath, with: .color(themeColor))
          continue
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
        }
        // Only stroke non-dot paths
        if !pathData.isDot {
          context.stroke(
            scaledPath,
            with: .color(themeColor),
            style: StrokeStyle(
              lineWidth: 5.0 * scale,
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

// MARK: - No Anniversary View

struct NoAnniversaryView: View {
  let family: WidgetFamily

  var body: some View {
    VStack(alignment: .center, spacing: 8) {
      Image(systemName: "calendar.badge.clock")
        .font(.appFont(size: family == .systemSmall ? 32 : family == .systemMedium ? 40 : 48))
        .foregroundColor(.secondary.opacity(0.3))
      Text("No future anniversaries")
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

// MARK: - Widget Configuration

struct AnniversaryWidget: Widget {
  let kind: String = "AnniversaryWidget"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind, intent: AnniversaryConfigurationIntent.self, provider: AnniversaryProvider()
    ) { entry in
      AnniversaryWidgetView(entry: entry)
        .environment(\.locale, WidgetDataManager.shared.loadAppLocale() ?? .current)
    }
    .configurationDisplayName("Anniversary")
    .description("Anniversary Joodle with countdown.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

// MARK: - Previews

/// Helper to create a dateString for a future date
private func futureDateString(daysFromNow: Int) -> String {
  let futureDate = Calendar.current.date(byAdding: .day, value: daysFromNow, to: Date())!
  let components = Calendar.current.dateComponents([.year, .month, .day], from: futureDate)
  return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 1, components.day ?? 1)
}

#Preview("Small - Drawing", as: .systemSmall) {
  AnniversaryWidget()
} timeline: {
  let futureDateStr = futureDateString(daysFromNow: 30)

  AnniversaryEntry(
    date: Date(),
    anniversaryData: AnniversaryData(
      dateString: futureDateStr,
      text: nil,
      drawingData: createMockDrawingData()
    ),
    configuration: AnniversaryConfigurationIntent(),
    hasPremiumAccess: true
  )

  // Preview with text only
  AnniversaryEntry(
    date: Date(),
    anniversaryData: AnniversaryData(
      dateString: futureDateStr,
      text: "This is a special anniversary!",
      drawingData: nil
    ),
    configuration: AnniversaryConfigurationIntent(),
    hasPremiumAccess: true
  )

  // Preview with no anniversary
  AnniversaryEntry(
    date: Date(),
    anniversaryData: nil,
    configuration: AnniversaryConfigurationIntent(),
    hasPremiumAccess: true
  )
}

#Preview("Medium", as: .systemMedium) {
  AnniversaryWidget()
} timeline: {
  let futureDateStr = futureDateString(daysFromNow: 30)

  // Preview with drawing
  AnniversaryEntry(
    date: Date(),
    anniversaryData: AnniversaryData(
      dateString: futureDateStr,
      text: nil,
      drawingData: createMockDrawingData()
    ),
    configuration: AnniversaryConfigurationIntent(),
    hasPremiumAccess: true
  )

  // Preview with text only
  AnniversaryEntry(
    date: Date(),
    anniversaryData: AnniversaryData(
      dateString: futureDateStr,
      text: "This is a special anniversary!",
      drawingData: nil
    ),
    configuration: AnniversaryConfigurationIntent(),
    hasPremiumAccess: true
  )

  // Preview with both
  AnniversaryEntry(
    date: Date(),
    anniversaryData: AnniversaryData(
      dateString: futureDateStr,
      text: "Parents coming to Singapore! Finally!",
      drawingData: createMockDrawingData()
    ),
    configuration: AnniversaryConfigurationIntent(),
    hasPremiumAccess: true
  )

  // Preview with no anniversary
  AnniversaryEntry(
    date: Date(),
    anniversaryData: nil,
    configuration: AnniversaryConfigurationIntent(),
    hasPremiumAccess: true
  )
}

#Preview("Large", as: .systemLarge) {
  AnniversaryWidget()
} timeline: {
  let futureDateStr = futureDateString(daysFromNow: 30)

  // Preview with drawing
  AnniversaryEntry(
    date: Date(),
    anniversaryData: AnniversaryData(
      dateString: futureDateStr,
      text: nil,
      drawingData: createMockDrawingData()
    ),
    configuration: AnniversaryConfigurationIntent(),
    hasPremiumAccess: true
  )

  // Preview with text only
  AnniversaryEntry(
    date: Date(),
    anniversaryData: AnniversaryData(
      dateString: futureDateStr,
      text:
        "This is a special anniversary that I want to remember forever! This is a special anniversary that I want to remember forever! This is a special anniversary that I want to remember forever! This is a special anniversary that I want to remember forever! This is a special anniversary that I want to remember forever!",
      drawingData: nil
    ),
    configuration: AnniversaryConfigurationIntent(),
    hasPremiumAccess: true
  )

  // Preview with no anniversary
  AnniversaryEntry(
    date: Date(),
    anniversaryData: nil,
    configuration: AnniversaryConfigurationIntent(),
    hasPremiumAccess: true
  )
}
