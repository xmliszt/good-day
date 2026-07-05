//
//  DayEntryModel.swift
//  Joodle
//
//  Created by Li Yuxuan on 10/8/25.
//

import Foundation
import SwiftData

@Model
final class DayEntry {
  /// The unique identifier for this entry in "yyyy-MM-dd" format
  /// This is the SINGLE SOURCE OF TRUTH for the entry's date - timezone-agnostic.
  /// Once set, it represents that calendar day forever, regardless of timezone changes.
  /// Note: Uniqueness is enforced in code during creation, not via @Attribute(.unique)
  /// to allow lightweight schema migration from older versions without dateString
  var dateString: String = ""

  var body: String = ""

  /// Legacy timestamp - kept for backward compatibility and sorting
  /// For new entries, this is set to noon UTC of the dateString date
  /// DO NOT use this for date identification - use dateString or calendarDate instead
  var createdAt: Date = Date()

  var drawingData: Data?

  // Pre-rendered thumbnails for optimized display
  var drawingThumbnail20: Data?   // 20px with thicker strokes for year grid minimized mode & widgets
  var drawingThumbnail200: Data?  // 200px for grid and detail views

  /// Additional doodles beyond the first, JSON-encoded `[Doodle]`.
  /// The FIRST doodle for a day is always stored on the scalar `drawingData`/
  /// `drawingThumbnail20`/`drawingThumbnail200` fields above (so all existing
  /// read paths — grid, widgets, backup — keep working unchanged); doodles 2…N
  /// live here. Access the full ordered list via `doodles`, never these two
  /// representations directly. Nil means the day has at most one doodle.
  /// Optional with a nil default so it's a lightweight additive schema change
  /// (CloudKit-safe, no migration needed).
  var extraDoodlesData: Data?

  // MARK: - Legacy thumbnail (kept for migration cleanup, will be removed in future version)
  // This property exists only to allow the migration to nil it out and reclaim storage
  // DO NOT USE - it is deprecated and will be removed
  var drawingThumbnail1080: Data?

  // MARK: - Initialization

  /// Creates a new DayEntry for a specific calendar date (preferred initializer)
  /// - Parameters:
  ///   - body: The text content of the entry
  ///   - calendarDate: The timezone-agnostic calendar date for this entry
  ///   - drawingData: Optional drawing data
  init(body: String, calendarDate: CalendarDate, drawingData: Data? = nil) {
    self.body = body
    self.dateString = calendarDate.dateString
    // Store as noon UTC to avoid any edge-case timezone issues with the legacy Date field
    self.createdAt = Self.stringToDate(calendarDate.dateString) ?? calendarDate.displayDate
    self.drawingData = drawingData
    self.drawingThumbnail20 = nil
    self.drawingThumbnail200 = nil
  }

  /// Creates a new DayEntry for a specific date
  /// - Parameters:
  ///   - body: The text content of the entry
  ///   - date: The date this entry represents (will be converted to dateString using local calendar)
  ///   - drawingData: Optional drawing data
  /// - Note: Prefer using `init(body:calendarDate:drawingData:)` for new code
  init(body: String, createdAt date: Date, drawingData: Data? = nil) {
    self.body = body
    self.dateString = CalendarDate.from(date).dateString
    // Store as noon UTC to avoid any edge-case timezone issues with the legacy Date field
    self.createdAt = Self.stringToDate(self.dateString) ?? date
    self.drawingData = drawingData
    self.drawingThumbnail20 = nil
    self.drawingThumbnail200 = nil
  }

  // MARK: - CalendarDate Integration

  /// Type-safe accessor for the calendar date (preferred for all date operations)
  /// Returns nil only if dateString is malformed (should not happen in practice)
  var calendarDate: CalendarDate? {
    CalendarDate(dateString: dateString)
  }

  /// Returns a Date representation of this entry's date (at start of day in user's current timezone)
  /// Use this for display purposes, countdown calculations, and when you need a Date object
  var displayDate: Date {
    calendarDate?.displayDate ?? createdAt
  }

  /// Returns a formatted display string for the date in "d MMMM yyyy" format (e.g., "25 December 2025")
  var dateToDisplayString: String {
    calendarDate?.displayString ?? dateString
  }

  /// Returns the year component of this entry
  var year: Int {
    calendarDate?.year ?? Calendar.current.component(.year, from: createdAt)
  }

  /// Returns the month component of this entry (1-12)
  var month: Int {
    calendarDate?.month ?? Calendar.current.component(.month, from: createdAt)
  }

  /// Returns the day component of this entry (1-31)
  var day: Int {
    calendarDate?.day ?? Calendar.current.component(.day, from: createdAt)
  }

  /// Check if this entry is for today
  var isToday: Bool {
    calendarDate?.isToday ?? false
  }

  /// Check if this entry is for a future date
  var isFuture: Bool {
    calendarDate?.isFuture ?? false
  }

  /// Check if this entry is for a past date
  var isPast: Bool {
    calendarDate?.isPast ?? true
  }

  /// Checks if this entry matches a given CalendarDate
  /// - Parameter calendarDate: The calendar date to compare against
  /// - Returns: True if this entry represents the same calendar day
  func matches(calendarDate: CalendarDate) -> Bool {
    return dateString == calendarDate.dateString
  }

  /// Checks if this entry matches a given date (using dateString comparison)
  /// - Parameter date: The date to compare against
  /// - Returns: True if this entry represents the same calendar day
  func matches(date: Date) -> Bool {
    return dateString == CalendarDate.from(date).dateString
  }

  // MARK: - Date String Conversion Helpers (Legacy Support)

  /// UTC DateFormatter for creating stable Date objects from dateString
  private static let utcDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  /// Converts a Date to a dateString using the current calendar/timezone
  /// - Parameter date: The date to convert
  /// - Returns: A string in "yyyy-MM-dd" format representing the local calendar date
  /// - Note: Prefer using `CalendarDate.from(date).dateString` for new code
  static func dateToString(_ date: Date) -> String {
    CalendarDate.from(date).dateString
  }

  /// Converts a dateString back to a Date (at noon UTC for internal storage stability)
  /// - Parameter dateString: A string in "yyyy-MM-dd" format
  /// - Returns: A Date representing noon UTC on that day, or nil if parsing fails
  static func stringToDate(_ dateString: String) -> Date? {
    return utcDateFormatter.date(from: "\(dateString) 12:00:00")
  }

  /// Converts a dateString to a Date at start of day in the user's current timezone
  /// This is appropriate for countdown calculations and display
  /// - Parameter dateString: A string in "yyyy-MM-dd" format
  /// - Returns: A Date representing start of day in current timezone, or nil if parsing fails
  /// - Note: Prefer using `CalendarDate(dateString:)?.displayDate` for new code
  static func stringToLocalDate(_ dateString: String) -> Date? {
    CalendarDate(dateString: dateString)?.displayDate
  }

  /// Converts a dateString to a display-friendly format (e.g., "25 December 2025")
  /// - Parameter dateString: A string in "yyyy-MM-dd" format
  /// - Returns: A formatted string in "d MMMM yyyy" format
  /// - Note: Prefer using `CalendarDate(dateString:)?.displayString` for new code
  static func formatDateStringForDisplay(_ dateString: String) -> String {
    CalendarDate(dateString: dateString)?.displayString ?? dateString
  }

  // MARK: - Multiple Doodles Per Day

  /// The maximum number of doodles a single day can hold.
  static let maxDoodlesPerDay = 5

  /// The day's doodles as an ordered list. Index 0 is the primary doodle backed
  /// by the scalar `drawingData`/thumbnail fields; indices 1… are decoded from
  /// `extraDoodlesData`. Returns `[]` when the day has no drawing.
  var doodles: [Doodle] {
    var result: [Doodle] = []
    if let data = drawingData, !data.isEmpty {
      result.append(
        Doodle(
          id: Self.primaryDoodleID(for: dateString),
          drawingData: data,
          thumbnail20: drawingThumbnail20,
          thumbnail200: drawingThumbnail200
        )
      )
    }
    if let extra = extraDoodlesData, !extra.isEmpty,
       let decoded = try? JSONDecoder().decode([Doodle].self, from: extra) {
      result.append(contentsOf: decoded)
    }
    return result
  }

  /// Number of doodles on this day.
  var doodleCount: Int { doodles.count }

  /// Whether another doodle can be added to this day.
  var canAddDoodle: Bool { doodleCount < Self.maxDoodlesPerDay }

  /// Replaces the day's entire ordered doodle list, re-persisting the first as
  /// the primary scalar fields and the rest into `extraDoodlesData`. Excess
  /// beyond `maxDoodlesPerDay` is dropped. Passing `[]` clears all drawing data.
  func setDoodles(_ newDoodles: [Doodle]) {
    let capped = Array(newDoodles.prefix(Self.maxDoodlesPerDay))
    if let primary = capped.first {
      drawingData = primary.drawingData
      drawingThumbnail20 = primary.thumbnail20
      drawingThumbnail200 = primary.thumbnail200
    } else {
      drawingData = nil
      drawingThumbnail20 = nil
      drawingThumbnail200 = nil
    }
    let extras = Array(capped.dropFirst())
    extraDoodlesData = extras.isEmpty ? nil : try? JSONEncoder().encode(extras)
  }

  /// Appends a new doodle if under the per-day cap. No-op when already at the cap.
  @discardableResult
  func appendDoodle(drawingData: Data, thumbnail20: Data?, thumbnail200: Data?) -> Bool {
    var current = doodles
    guard current.count < Self.maxDoodlesPerDay else { return false }
    current.append(Doodle(drawingData: drawingData, thumbnail20: thumbnail20, thumbnail200: thumbnail200))
    setDoodles(current)
    return true
  }

  /// Overwrites the doodle at `index`, preserving its stable id. Appends when
  /// `index` is exactly one past the end (and under the cap); otherwise no-op.
  func updateDoodle(at index: Int, drawingData: Data, thumbnail20: Data?, thumbnail200: Data?) {
    var current = doodles
    if current.indices.contains(index) {
      current[index] = Doodle(
        id: current[index].id,
        drawingData: drawingData,
        thumbnail20: thumbnail20,
        thumbnail200: thumbnail200
      )
      setDoodles(current)
    } else if index == current.count {
      _ = appendDoodle(drawingData: drawingData, thumbnail20: thumbnail20, thumbnail200: thumbnail200)
    }
  }

  /// Removes the doodle at `index`, compacting the remaining ones (a removed
  /// primary is replaced by the next doodle). No-op for an out-of-range index.
  func removeDoodle(at index: Int) {
    var current = doodles
    guard current.indices.contains(index) else { return }
    current.remove(at: index)
    setDoodles(current)
  }

  /// Merges `source`'s doodles into `target`, skipping duplicates (by drawing
  /// bytes) and respecting the per-day cap. Used when collapsing duplicate rows
  /// for the same date (CloudKit sync conflicts) so extra doodles aren't lost.
  /// - Returns: true if any doodle was added to `target`.
  @discardableResult
  static func mergeDoodles(from source: DayEntry, into target: DayEntry) -> Bool {
    let sourceDoodles = source.doodles
    guard !sourceDoodles.isEmpty else { return false }

    var targetDoodles = target.doodles
    var existingKeys = Set(targetDoodles.map(\.drawingData))
    var didAdd = false

    for doodle in sourceDoodles {
      guard targetDoodles.count < maxDoodlesPerDay else { break }
      guard !existingKeys.contains(doodle.drawingData) else { continue }
      targetDoodles.append(doodle)
      existingKeys.insert(doodle.drawingData)
      didAdd = true
    }

    if didAdd { target.setDoodles(targetDoodles) }
    return didAdd
  }

  /// A stable, deterministic id for the primary doodle of a given date, so that
  /// re-reading `doodles` yields consistent SwiftUI identities (needed for the
  /// carousel cross-fade and card animations). FNV-1a over the dateString.
  private static func primaryDoodleID(for dateString: String) -> UUID {
    func fnv1a(seed: UInt64) -> UInt64 {
      var hash = seed
      for byte in dateString.utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
      }
      return hash
    }
    let hi = fnv1a(seed: 0xcbf2_9ce4_8422_2325)
    let lo = fnv1a(seed: 0x8422_2325_cbf2_9ce4)
    let bytes = withUnsafeBytes(of: (hi.bigEndian, lo.bigEndian)) { Array($0) }
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }

  // MARK: - Find or Create Entry

  /// Finds an existing entry for the given calendar date, or creates a new one if none exists.
  /// This is the preferred method to get/create entries to avoid duplicates.
  /// If multiple entries exist for the same date, they will be merged and duplicates deleted.
  /// - Parameters:
  ///   - calendarDate: The calendar date to find or create an entry for
  ///   - modelContext: The SwiftData model context
  /// - Returns: The single entry for this date (existing or newly created)
  static func findOrCreate(for calendarDate: CalendarDate, in modelContext: ModelContext) -> DayEntry {
    let targetDateString = calendarDate.dateString
    let predicate = #Predicate<DayEntry> { entry in
      entry.dateString == targetDateString
    }
    let descriptor = FetchDescriptor<DayEntry>(predicate: predicate)

    do {
      let existingEntries = try modelContext.fetch(descriptor)

      if existingEntries.isEmpty {
        // No entry exists - create new one
        let newEntry = DayEntry(body: "", calendarDate: calendarDate)
        modelContext.insert(newEntry)
        try? modelContext.save()
        return newEntry
      } else if existingEntries.count == 1 {
        // Exactly one entry - return it
        return existingEntries[0]
      } else {
        // Multiple entries exist - merge and return the primary one
        return mergeAndCleanup(entries: existingEntries, in: modelContext)
      }
    } catch {
      print("DayEntry.findOrCreate: Failed to fetch entries: \(error)")
      // Fallback: create new entry
      let newEntry = DayEntry(body: "", calendarDate: calendarDate)
      modelContext.insert(newEntry)
      try? modelContext.save()
      return newEntry
    }
  }

  /// Finds an existing entry for the given date, or creates a new one if none exists.
  /// This is the preferred method to get/create entries to avoid duplicates.
  /// If multiple entries exist for the same date, they will be merged and duplicates deleted.
  /// - Parameters:
  ///   - date: The date to find or create an entry for (converted to CalendarDate using current timezone)
  ///   - modelContext: The SwiftData model context
  /// - Returns: The single entry for this date (existing or newly created)
  /// - Note: Prefer using `findOrCreate(for:CalendarDate, in:)` for new code
  static func findOrCreate(for date: Date, in modelContext: ModelContext) -> DayEntry {
    findOrCreate(for: CalendarDate.from(date), in: modelContext)
  }

  /// Merges multiple entries for the same date into one, deleting duplicates
  /// - Parameters:
  ///   - entries: Array of entries to merge (must have same dateString)
  ///   - modelContext: The SwiftData model context
  /// - Returns: The merged primary entry
  private static func mergeAndCleanup(entries: [DayEntry], in modelContext: ModelContext) -> DayEntry {
    // Sort by content priority: drawing > text > empty
    let sortedEntries = entries.sorted { entry1, entry2 in
      contentScore(entry1) > contentScore(entry2)
    }

    guard let primaryEntry = sortedEntries.first else {
      fatalError("mergeAndCleanup called with empty array")
    }

    let duplicates = Array(sortedEntries.dropFirst())

    // Merge content from duplicates into primary entry
    for duplicate in duplicates {
      // Merge text if primary is empty but duplicate has text
      if primaryEntry.body.isEmpty && !duplicate.body.isEmpty {
        primaryEntry.body = duplicate.body
      } else if !primaryEntry.body.isEmpty && !duplicate.body.isEmpty && primaryEntry.body != duplicate.body {
        // Both have different text - combine them
        primaryEntry.body = primaryEntry.body + "\n\n---\n\n" + duplicate.body
      }

      // Merge the duplicate's doodles into the primary (skips dupes, honors the
      // per-day cap) so a sync-conflict duplicate never drops extra doodles.
      DayEntry.mergeDoodles(from: duplicate, into: primaryEntry)

      // Delete the duplicate
      modelContext.delete(duplicate)
    }

    if !duplicates.isEmpty {
      try? modelContext.save()
      print("DayEntry.mergeAndCleanup: Merged \(duplicates.count) duplicate(s) for \(primaryEntry.dateString)")
    }

    return primaryEntry
  }

  /// Calculate content priority score for an entry
  private static func contentScore(_ entry: DayEntry) -> Int {
    var score = 0
    if let drawingData = entry.drawingData, !drawingData.isEmpty {
      score += 100
    }
    if !entry.body.isEmpty {
      score += 50 + min(entry.body.count, 50)
    }
    if entry.drawingThumbnail20 != nil { score += 10 }
    if entry.drawingThumbnail200 != nil { score += 10 }
    return score
  }

  /// Deletes this entry and ALL other entries for the same date
  /// Use this when user explicitly wants to delete/clear a day's entry
  /// - Parameter modelContext: The SwiftData model context
  func deleteAllForSameDate(in modelContext: ModelContext) {
    let targetDateString = self.dateString
    let predicate = #Predicate<DayEntry> { entry in
      entry.dateString == targetDateString
    }
    let descriptor = FetchDescriptor<DayEntry>(predicate: predicate)

    do {
      let allEntriesForDate = try modelContext.fetch(descriptor)
      for entry in allEntriesForDate {
        modelContext.delete(entry)
      }
      try modelContext.save()
      print("DayEntry.deleteAllForSameDate: Deleted \(allEntriesForDate.count) entry(ies) for \(targetDateString)")
    } catch {
      print("DayEntry.deleteAllForSameDate: Failed to delete entries: \(error)")
      // At minimum, delete this entry
      modelContext.delete(self)
      try? modelContext.save()
    }
  }
}
