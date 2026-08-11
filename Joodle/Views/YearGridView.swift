//
//  YearGridView.swift
//  Joodle
//
//  Created by Li Yuxuan on 11/8/25.
//

import SwiftUI

// MARK: - Constants
let GRID_HORIZONTAL_PADDING: CGFloat = 40
let MAX_SCALE: CGFloat = 1.5
let MAX_SCALE_DISTANCE: CGFloat = 2.5

struct DateItem: Identifiable, Equatable {
  var id: String
  var date: Date
}

struct YearGridView: View {

  // MARK: Environment
  @Environment(\.userPreferences) private var userPreferences
  @Environment(\.locale) private var locale

  // MARK: Params
  /// The year to display
  let year: Int
  /// The mode to display the grid in
  let viewMode: ViewMode
  /// The spacing between dots
  let dotsSpacing: CGFloat
  /// The items to display in the grid
  let items: [DateItem]
  /// The entries to display in the grid
  let entries: [DayEntry]
  /// The id of the highlighted item
  let highlightedItemId: String?
  /// The id of the selected item
  let selectedItemId: String?
  /// Whether we're in move-drawing mode
  let isInMoveMode: Bool
  /// The source date string for the drawing being moved
  let moveSourceDateString: String?

  // MARK: Animation State
  /// Tracks whether the entry animation has completed
  @State private var hasAnimated = false
  /// Animation trigger ID that changes when viewMode changes
  @State private var animationTriggerID = UUID()

  // MARK: Cached Computed Properties
  /// Pre-computed layout metrics to avoid repeated calculations
  private var layoutMetrics: LayoutMetrics {
    let numberOfRows = (items.count + viewMode.dotsPerRow - 1) / viewMode.dotsPerRow
    let totalContentHeight = CGFloat(numberOfRows) * (viewMode.dotSize + dotsSpacing)
    return LayoutMetrics(
      numberOfRows: numberOfRows,
      totalContentHeight: totalContentHeight
    )
  }

  private struct LayoutMetrics {
    let numberOfRows: Int
    let totalContentHeight: CGFloat
  }

  /// Pre-computed today's date for comparison
  private var todayStart: Date {
    Calendar.current.startOfDay(for: Date())
  }

  /// Calculate the number of empty slots needed at the beginning of the grid
  /// to align the first day of the year with the correct weekday column
  private var leadingEmptySlots: Int {
    // Only apply calendar alignment for .now mode (7 days per row = calendar week)
    guard viewMode == .now else { return 0 }
    return CalendarGridHelper.leadingEmptySlots(for: year, startOfWeek: userPreferences.startOfWeek)
  }

  /// Localized very-short weekday labels, reordered for the user's start-of-week.
  /// `veryShortWeekdaySymbols` is always Sunday-first, so the Monday variant
  /// rotates Sunday to the end. Uses the app's locale so it follows the in-app
  /// language override, matching the widgets.
  private var weekdayLabels: [String] {
    var calendar = Calendar.current
    calendar.locale = locale
    let symbols = calendar.veryShortWeekdaySymbols
    return userPreferences.startOfWeek.lowercased() == "monday"
      ? Array(symbols[1...]) + [symbols[0]]
      : symbols
  }

  // MARK: View
  var body: some View {
    let entriesByDateKey = buildEntriesLookup()

    // Find the index of the highlighted item for distance calculation
    let highlightedIndex = items.firstIndex { $0.id == highlightedItemId }

    // Calculate leading offset for calendar week alignment
    let leadingOffset = leadingEmptySlots
    let totalVirtualItems = leadingOffset + items.count

    // Adjust highlighted index to account for leading offset (computed once)
    let adjustedHighlightedIndex = highlightedIndex.map { $0 + leadingOffset }

    // Split into rows accounting for leading empty slots
    let rows: [(virtualStart: Int, count: Int)] = stride(from: 0, to: totalVirtualItems, by: viewMode.dotsPerRow).map { rowStart in
      (rowStart, min(viewMode.dotsPerRow, totalVirtualItems - rowStart))
    }

    VStack(spacing: dotsSpacing) {
      ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowInfo in
        HStack(alignment: .top, spacing: dotsSpacing) {
          ForEach(0..<rowInfo.count, id: \.self) { colIndex in
            let virtualIndex = rowInfo.virtualStart + colIndex
            let isEmptySlot = virtualIndex < leadingOffset
            let itemIndex = isEmptySlot ? 0 : virtualIndex - leadingOffset
            let item: DateItem? = isEmptySlot ? nil : items[itemIndex]

            // Use plain item ID for scroll targeting (ContentView uses this for scrollTo)
            // Empty slots get a unique ID that won't be targeted by scroll
            let scrollId = item?.id ?? "empty-\(virtualIndex)"

            if let item = item {
              // Pre-compute all cell state to pass to equatable cell view
              let dotStyle = getDotStyle(for: item.date)
              let entry = getEntryForDate(item.date, from: entriesByDateKey)
              let hasEntry = entry != nil && entry!.body.isEmpty == false
              let hasDrawing = entry?.drawingData != nil && !(entry?.drawingData?.isEmpty ?? true)
              let doodleCount = entry?.doodleCount ?? 0
              let isHighlighted = highlightedItemId == item.id
              let isSelected = selectedItemId == item.id
              let scale = calculateScale(
                currentIndex: virtualIndex,
                highlightedIndex: adjustedHighlightedIndex,
                dotsPerRow: viewMode.dotsPerRow,
                isEmpty: entry == nil
              )
              let hashValue = abs(item.id.hashValue)
              let animationDelay = Double(hashValue % 500) / 1000.0
              let dateString = CalendarDate.from(item.date).dateString
              let isSourceDate = isInMoveMode && moveSourceDateString == dateString
              // A day is a valid drop target as long as it can still hold another
              // doodle (up to the per-day cap) — matches ContentView.handleMoveModeTap,
              // so days that already have 1..4 doodles stay available (not just empty days).
              let isAvailableForMove = isInMoveMode && doodleCount < DayEntry.maxDoodlesPerDay && !isSourceDate
              let month = Calendar.current.component(.month, from: item.date)

              YearGridDotCell(
                viewMode: viewMode,
                dotStyle: dotStyle,
                hasEntry: hasEntry,
                hasDrawing: hasDrawing,
                doodleCount: doodleCount,
                entry: entry,
                isHighlighted: isHighlighted,
                isSelected: isSelected,
                scale: scale,
                hasAnimated: hasAnimated,
                animationDelay: animationDelay,
                isInMoveMode: isInMoveMode,
                isAvailableForMove: isAvailableForMove,
                isSourceDate: isSourceDate,
                month: month
              )
              .equatable()
              .id(scrollId)
            } else {
              // Empty slot - render invisible spacer
              Color.clear
                .frame(width: viewMode.dotSize, height: viewMode.dotSize)
                .id(scrollId)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(
      .init(
        top: 0, leading: GRID_HORIZONTAL_PADDING, bottom: GRID_HORIZONTAL_PADDING,
        trailing: GRID_HORIZONTAL_PADDING)
    )
    .frame(maxWidth: .infinity, alignment: .top)
    .overlay(alignment: .top) {
      // Weekday labels row - only show in .now mode (7 days per row = calendar week)
      // Positioned above the grid using negative offset so it doesn't affect layout
      // Hidden by header space on top, revealed when user pulls down
      if viewMode == .now {
        HStack(alignment: .center, spacing: dotsSpacing) {
          ForEach(0..<7, id: \.self) { index in
            Color.clear
              .frame(width: viewMode.dotSize, height: viewMode.dotSize)
              .overlay {
                Text(weekdayLabels[index])
                  .font(.appFont(size: 10, weight: .medium))
                  .foregroundStyle(.secondary)
                  .fixedSize()
              }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, GRID_HORIZONTAL_PADDING)
        .offset(y: -(dotsSpacing + 10)) // Position above the first row of dots
      }
    }
    .onAppear {
      // Trigger initial animation
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        hasAnimated = true
      }
    }
    .onChange(of: viewMode) { _, _ in
      // Reset and replay animation when view mode changes
      hasAnimated = false
      animationTriggerID = UUID()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        hasAnimated = true
      }
    }
  }

  // MARK: Functions
  /// Get the style of the dot for a given date (optimized)
  private func getDotStyle(for date: Date) -> DotStyle {
    if date < todayStart {
      return .past
    } else if Calendar.current.isDate(date, inSameDayAs: todayStart) {
      return .present
    }
    return .future
  }

  /// Build a dictionary for O(1) entry lookups by date
  /// When there are duplicate entries for the same date, prioritize entries with content
  private func buildEntriesLookup() -> [String: DayEntry] {
    var lookup: [String: DayEntry] = [:]
    for entry in entries {
      // Use the timezone-agnostic dateString directly as the key
      let key = entry.dateString

      // Check if we already have an entry for this date
      if let existing = lookup[key] {
        // Prioritize entry with drawing data
        let existingHasDrawing = existing.drawingData != nil && !(existing.drawingData?.isEmpty ?? true)
        let newHasDrawing = entry.drawingData != nil && !(entry.drawingData?.isEmpty ?? true)

        if newHasDrawing && !existingHasDrawing {
          // New entry has drawing, existing doesn't - use new
          lookup[key] = entry
        } else if !existingHasDrawing && !newHasDrawing {
          // Neither has drawing - prioritize one with text
          let existingHasText = !existing.body.isEmpty
          let newHasText = !entry.body.isEmpty
          if newHasText && !existingHasText {
            lookup[key] = entry
          }
        }
        // Otherwise keep existing (it already has drawing or both have same content type)
      } else {
        // No existing entry for this date
        lookup[key] = entry
      }
    }
    return lookup
  }

  /// Find the entry for a given date using pre-built lookup
  private func getEntryForDate(_ date: Date, from lookup: [String: DayEntry]) -> DayEntry? {
    // Use CalendarDate for timezone-agnostic date string
    let key = CalendarDate.from(date).dateString
    return lookup[key]
  }

  /// Find the entry for a given date (legacy method for backward compatibility)
  private func entryForDate(_ date: Date) -> DayEntry? {
    return entries.first { entry in
      entry.matches(date: date)
    }
  }

  /// Check if a given date is today's date (optimized)
  private func isToday(for date: Date) -> Bool {
    return Calendar.current.isDate(date, inSameDayAs: todayStart)
  }

  /// Check if a given date is in the past (before today) (optimized)
  private func isPastDay(for date: Date) -> Bool {
    return date < todayStart
  }

  /// Calculate scale for a dot based on its distance from the highlighted dot
  private func calculateScale(currentIndex: Int, highlightedIndex: Int?, dotsPerRow: Int, isEmpty: Bool) -> CGFloat
  {
    // If no highlighted dot, return default scale
    guard let highlightedIndex = highlightedIndex else {
      return 1.0
    }

    // Calculate row and column for both dots
    let currentRow = currentIndex / dotsPerRow
    let currentCol = currentIndex % dotsPerRow
    let highlightedRow = highlightedIndex / dotsPerRow
    let highlightedCol = highlightedIndex % dotsPerRow

    // Calculate distance
    let rowDiff = abs(currentRow - highlightedRow)
    let colDiff = abs(currentCol - highlightedCol)

    // Calculate distance with diagonal penalty
    // Adjacent dots (horizontal/vertical) = 1.0
    // Diagonal dots = 1.5 (sqrt(2) ≈ 1.414, rounded to 1.5 for smoother effect)
    let distance: CGFloat
    if rowDiff == 0 && colDiff == 0 {
      // Center dot
      distance = 0
    } else if rowDiff == 0 || colDiff == 0 {
      // Same row or column (horizontal/vertical)
      distance = CGFloat(max(rowDiff, colDiff))
    } else {
      // Diagonal - use the larger diff plus 0.5 per diagonal step
      distance = CGFloat(max(rowDiff, colDiff)) + CGFloat(min(rowDiff, colDiff)) * 0.5
    }

    // Apply decay effect
    if distance > MAX_SCALE_DISTANCE {
      return 1.0
    }

    // Linear interpolation from MAX_SCALE at distance 0 to 1.0 at MAX_SCALE_DISTANCE
    let scaleFactor = 1.0 - (distance / MAX_SCALE_DISTANCE)

    // If it is non-drawing dot view, we magnify the scale effect
    return (1.0 + (MAX_SCALE - 1.0) * scaleFactor) * (
      isEmpty ? 1.5 : 1
    )
  }
}

// MARK: - Equatable Cell View

/// Individual grid dot cell that conforms to Equatable to prevent unnecessary re-renders.
/// When only `selectedItemId` changes (e.g. a tap), only the 2 affected cells (old and new selection)
/// have their body re-evaluated; the other ~363 cells are skipped by SwiftUI's diffing.
private struct YearGridDotCell: View, Equatable {
  let viewMode: ViewMode
  let dotStyle: DotStyle
  let hasEntry: Bool
  let hasDrawing: Bool
  let doodleCount: Int
  let entry: DayEntry?
  let isHighlighted: Bool
  let isSelected: Bool
  let scale: CGFloat
  let hasAnimated: Bool
  let animationDelay: Double
  let isInMoveMode: Bool
  let isAvailableForMove: Bool
  let isSourceDate: Bool
  let month: Int

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isHighlighted == rhs.isHighlighted &&
    lhs.isSelected == rhs.isSelected &&
    lhs.scale == rhs.scale &&
    lhs.hasAnimated == rhs.hasAnimated &&
    lhs.hasEntry == rhs.hasEntry &&
    lhs.hasDrawing == rhs.hasDrawing &&
    lhs.doodleCount == rhs.doodleCount &&
    lhs.dotStyle == rhs.dotStyle &&
    lhs.viewMode == rhs.viewMode &&
    lhs.isInMoveMode == rhs.isInMoveMode &&
    lhs.isAvailableForMove == rhs.isAvailableForMove &&
    lhs.isSourceDate == rhs.isSourceDate &&
    lhs.month == rhs.month
  }

  var body: some View {
    if hasDrawing {
      // Show drawing instead of dot with specific frame sizes
      // Use thumbnail for performance optimization. Multi-doodle days cross-fade
      // through their doodles; single-doodle days render one static drawing.
      DoodleCarouselCell(
        entry: entry,
        doodles: entry?.doodles ?? [],
        displaySize: viewMode.drawingSize,
        dotStyle: isInMoveMode && !isSourceDate ? .past : dotStyle,
        accent: false,
        highlighted: isHighlighted || isSelected,
        scale: scale
      )
      .frame(width: viewMode.dotSize, height: viewMode.dotSize)
      // Jelly bounce animation from bottom for drawings
      .offset(y: hasAnimated ? 0 : 50)
      .scaleEffect(
        x: hasAnimated ? 1.0 : 0.1,
        y: hasAnimated ? 1.0 : 0.1,
        anchor: .bottom
      )
      .opacity(hasAnimated ? 1.0 : 0.0)
      .animation(
        .spring(
          response: 0.4,
          dampingFraction: 0.35,
          blendDuration: 0
        )
        .delay(animationDelay),
        value: hasAnimated
      )
      .opacity(isInMoveMode ? ((isSourceDate || isAvailableForMove) ? 1.0 : 0.3) : 1.0)
    } else {
      // Show regular dot
      DotView(
        size: viewMode.dotSize,
        highlighted: isHighlighted || isSelected,
        withEntry: hasEntry,
        dotStyle: dotStyle,
        scale: scale,
        isAvailableForMove: isAvailableForMove,
        month: month
      )
      .frame(width: viewMode.dotSize, height: viewMode.dotSize)
    }
  }
}

#Preview {
  let calendar = Calendar.current
  let currentYear = calendar.component(.year, from: Date())

  // Generate sample items for the year
  let startOfYear = calendar.date(from: DateComponents(year: currentYear, month: 1, day: 1))!
  let daysInYear = calendar.dateInterval(of: .year, for: Date())!.duration / (24 * 60 * 60)
  let sampleItems = (0..<Int(daysInYear)).map { dayOffset in
    let date = calendar.date(byAdding: .day, value: dayOffset, to: startOfYear)!
    return DateItem(
      id: "\(Int(date.timeIntervalSince1970))",
      date: date
    )
  }

  // Generate sample entries with some having text and some having drawings
  let sampleEntries: [DayEntry] = {
    var entries: [DayEntry] = []

    // Add entries for random past days
    for dayOffset in [5, 12, 18, 23, 30, 45, 52, 67, 89, 100, 125, 150, 180, 200, 234, 267, 290] {
      if dayOffset < Int(daysInYear) {
        let date = calendar.date(byAdding: .day, value: dayOffset, to: startOfYear)!

        // Some entries have text
        if dayOffset % 3 == 0 {
          entries.append(
            DayEntry(
              body: "Sample entry for day \(dayOffset)",
              createdAt: date,
              drawingData: nil
            ))
        }
        // Some entries have drawings (mock with non-empty data)
        else if dayOffset % 3 == 1 {
          entries.append(
            DayEntry(
              body: "",
              createdAt: date,
              drawingData: Data([0x01, 0x02, 0x03])  // Mock drawing data
            ))
        }
        // Some have both
        else {
          entries.append(
            DayEntry(
              body: "Entry with drawing",
              createdAt: date,
              drawingData: Data([0x01, 0x02, 0x03])
            ))
        }
      }
    }

    return entries
  }()

  ScrollView {
    VStack {
      YearGridView(
        year: currentYear,
        viewMode: .now,
        dotsSpacing: 25,
        items: sampleItems,
        entries: sampleEntries,
        highlightedItemId: nil,
        selectedItemId: nil,
        isInMoveMode: false,
        moveSourceDateString: nil
      )
      YearGridView(
        year: currentYear,
        viewMode: .year,
        dotsSpacing: 8,
        items: sampleItems,
        entries: sampleEntries,
        highlightedItemId: nil,
        selectedItemId: nil,
        isInMoveMode: false,
        moveSourceDateString: nil
      )
    }
  }
}
