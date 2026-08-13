//
//  DuplicateEntryCleanup.swift
//  Joodle
//
//  Migration helper to clean up duplicate DayEntry records for the same date
//

import Foundation
import SwiftData

/// Handles cleanup of duplicate DayEntry records that have the same dateString
/// This can happen due to iCloud sync conflicts, race conditions, or edge cases
class DuplicateEntryCleanup {
  static let shared = DuplicateEntryCleanup()

  private static let cleanupKey = "hasCleansedDuplicateEntries_v1"

  private init() {}

  /// Check if cleanup has already been performed
  var hasPerformedCleanup: Bool {
    UserDefaults.standard.bool(forKey: Self.cleanupKey)
  }

  /// Cleans up duplicate entries by merging content and deleting redundant entries
  /// - Parameter modelContext: The SwiftData model context
  /// - Returns: A tuple with (mergedCount, deletedCount)
  func cleanupDuplicates(modelContext: ModelContext) -> (merged: Int, deleted: Int) {
    // Skip if already performed
    guard !hasPerformedCleanup else {
      return (0, 0)
    }

    return forceCleanupDuplicates(modelContext: modelContext, markAsCompleted: true)
  }

  /// Force cleanup duplicates regardless of whether it was already performed
  /// Used for manual cleanup from developer tools
  /// - Parameters:
  ///   - modelContext: The SwiftData model context
  ///   - markAsCompleted: Whether to mark the cleanup as completed in UserDefaults
  /// - Returns: A tuple with (mergedCount, deletedCount)
  func forceCleanupDuplicates(modelContext: ModelContext, markAsCompleted: Bool = false) -> (merged: Int, deleted: Int) {
    let descriptor = FetchDescriptor<DayEntry>()

    do {
      let allEntries = try modelContext.fetch(descriptor)

      // Group entries by their effective dateString
      // For entries with empty dateString, derive it from createdAt
      var entriesByDate: [String: [DayEntry]] = [:]
      for entry in allEntries {
        let key = effectiveDateString(for: entry)
        if entriesByDate[key] == nil {
          entriesByDate[key] = []
        }
        entriesByDate[key]?.append(entry)
      }

      var mergedCount = 0
      var deletedCount = 0

      // Process dates with duplicates
      for (dateString, entries) in entriesByDate {
        guard entries.count > 1 else { continue }

        print("DuplicateEntryCleanup: Found \(entries.count) entries for \(dateString)")

        // Find the best entry to keep (prioritize one with content)
        let sortedEntries = entries.sorted { entry1, entry2 in
          // Priority: drawing > text > empty
          let score1 = entryContentScore(entry1)
          let score2 = entryContentScore(entry2)
          return score1 > score2
        }

        guard let primaryEntry = sortedEntries.first else { continue }
        let duplicates = Array(sortedEntries.dropFirst())

        // Ensure primary entry has the correct dateString
        if primaryEntry.dateString.isEmpty {
          primaryEntry.dateString = dateString
        }

        // Merge content from duplicates into primary entry
        for duplicate in duplicates {
          let didMerge = mergeContent(from: duplicate, into: primaryEntry)
          if didMerge {
            mergedCount += 1
          }

          // Delete the duplicate
          modelContext.delete(duplicate)
          deletedCount += 1
        }
      }

      if mergedCount > 0 || deletedCount > 0 {
        try modelContext.save()
        print("DuplicateEntryCleanup: Merged content \(mergedCount) times, deleted \(deletedCount) duplicate entries")
      }

      // Mark as completed if requested
      if markAsCompleted {
        UserDefaults.standard.set(true, forKey: Self.cleanupKey)
      }

      return (mergedCount, deletedCount)

    } catch {
      print("DuplicateEntryCleanup: Failed to clean up duplicates: \(error)")
      return (0, 0)
    }
  }

  /// Get the effective dateString for an entry
  /// If dateString is empty, derive it from createdAt
  private func effectiveDateString(for entry: DayEntry) -> String {
    if !entry.dateString.isEmpty {
      return entry.dateString
    }
    // Derive from createdAt for legacy entries
    return DayEntry.dateToString(entry.createdAt)
  }

  /// Calculate a score for entry content priority
  /// Higher score = more content = should be kept
  private func entryContentScore(_ entry: DayEntry) -> Int {
    var score = 0

    // Drawing data is most valuable
    if let drawingData = entry.drawingData, !drawingData.isEmpty {
      score += 100
    }

    // Text content is also valuable
    if !entry.body.isEmpty {
      score += 50 + min(entry.body.count, 50) // Up to 100 points for text
    }

    // Having thumbnails indicates a valid drawing was saved
    if entry.drawingThumbnail20 != nil {
      score += 10
    }
    if entry.drawingThumbnail200 != nil {
      score += 10
    }

    return score
  }

  /// Merge content from source entry into target entry
  /// Only merges if target is missing content that source has
  /// - Returns: true if any content was merged
  private func mergeContent(from source: DayEntry, into target: DayEntry) -> Bool {
    var didMerge = false

    // Merge text content if target is empty but source has text
    if target.body.isEmpty && !source.body.isEmpty {
      target.body = source.body
      didMerge = true
      print("DuplicateEntryCleanup: Merged text content for \(target.dateString)")
    } else if !target.body.isEmpty && !source.body.isEmpty && target.body != source.body {
      // Both have different text - append source text to target
      // Use newlines to separate
      target.body = target.body + "\n\n---\n\n" + source.body
      didMerge = true
      print("DuplicateEntryCleanup: Combined text content for \(target.dateString)")
    }

    // Merge the source's doodles into the target (skips dupes by drawing bytes,
    // honors the per-day cap). This covers the primary drawing, its thumbnails,
    // and any extra doodles — so a sync-conflict duplicate never loses doodles.
    if DayEntry.mergeDoodles(from: source, into: target) {
      didMerge = true
      print("DuplicateEntryCleanup: Merged doodles for \(target.dateString)")
    }

    return didMerge
  }

  /// Check how many dates have duplicate entries
  /// - Parameter modelContext: The SwiftData model context
  /// - Returns: Number of dates with duplicates
  func checkDuplicateCount(modelContext: ModelContext) -> Int {
    var descriptor = FetchDescriptor<DayEntry>()
    descriptor.propertiesToFetch = [\.dateString, \.createdAt]

    do {
      let allEntries = try modelContext.fetch(descriptor)

      // Group entries by effective dateString (handles empty dateString)
      var entriesByDate: [String: Int] = [:]
      for entry in allEntries {
        let key = effectiveDateString(for: entry)
        entriesByDate[key, default: 0] += 1
      }

      // Count dates with more than one entry
      let duplicateDates = entriesByDate.filter { $0.value > 1 }
      return duplicateDates.count

    } catch {
      print("DuplicateEntryCleanup: Failed to check duplicate count: \(error)")
      return 0
    }
  }

  /// Get detailed info about duplicates (for debugging)
  /// - Parameter modelContext: The SwiftData model context
  /// - Returns: Dictionary of dateString -> entry count for dates with duplicates
  func getDuplicateDetails(modelContext: ModelContext) -> [String: Int] {
    var descriptor = FetchDescriptor<DayEntry>()
    descriptor.propertiesToFetch = [\.dateString, \.createdAt]

    do {
      let allEntries = try modelContext.fetch(descriptor)

      // Group entries by effective dateString (handles empty dateString)
      var entriesByDate: [String: Int] = [:]
      for entry in allEntries {
        let key = effectiveDateString(for: entry)
        entriesByDate[key, default: 0] += 1
      }

      // Return only dates with duplicates
      return entriesByDate.filter { $0.value > 1 }

    } catch {
      print("DuplicateEntryCleanup: Failed to get duplicate details: \(error)")
      return [:]
    }
  }

  /// Get total entry count (for stats)
  /// - Parameter modelContext: The SwiftData model context
  /// - Returns: Total number of entries
  func getTotalEntryCount(modelContext: ModelContext) -> Int {
    let descriptor = FetchDescriptor<DayEntry>()
    do {
      return try modelContext.fetchCount(descriptor)
    } catch {
      print("DuplicateEntryCleanup: Failed to get total entry count: \(error)")
      return 0
    }
  }

  /// Get count of unique dates (entries after deduplication)
  /// - Parameter modelContext: The SwiftData model context
  /// - Returns: Number of unique dates with entries
  func getUniqueDateCount(modelContext: ModelContext) -> Int {
    var descriptor = FetchDescriptor<DayEntry>()
    descriptor.propertiesToFetch = [\.dateString, \.createdAt]

    do {
      let allEntries = try modelContext.fetch(descriptor)
      var uniqueDates = Set<String>()
      for entry in allEntries {
        uniqueDates.insert(effectiveDateString(for: entry))
      }
      return uniqueDates.count
    } catch {
      print("DuplicateEntryCleanup: Failed to get unique date count: \(error)")
      return 0
    }
  }

  /// Reset the cleanup flag (for testing purposes)
  func resetCleanupFlag() {
    UserDefaults.standard.removeObject(forKey: Self.cleanupKey)
  }
}
