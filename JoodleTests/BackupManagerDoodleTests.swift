//
//  BackupManagerDoodleTests.swift
//  JoodleTests
//
//  Pins the backup export/restore round-trip for multi-doodle days (JOO-155).
//  The backup DTO round-trips the primary doodle on the scalar
//  `drawingData`/thumbnail fields AND the extra doodles (slots 2…N) via
//  `extraDoodlesData`, so restoring an iCloud backup no longer silently drops a
//  multi-doodle day's extra doodles. Also pins backward-compatibility: a backup
//  written before the multi-doodle feature (no `extraDoodlesData` key) still
//  restores its single doodle.
//

import Foundation
import SwiftData
import Testing

@testable import Joodle

struct BackupManagerDoodleTests {
  private func bytes(_ s: String) -> Data { Data(s.utf8) }

  private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([DayEntry.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    return try ModelContainer(for: schema, configurations: [config])
  }

  /// Serializes `entries`, writes the blob to a temp file, and restores it into
  /// a fresh in-memory container — the full export/restore path a user hits when
  /// saving to and reloading from iCloud Drive.
  private func roundTrip(_ entries: [DayEntry]) throws -> [DayEntry] {
    let data = try BackupManager.shared.serializeEntries(entries)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("joodle-backup-test-\(UUID().uuidString).json")
    try data.write(to: url, options: .atomic)
    defer { try? FileManager.default.removeItem(at: url) }

    let container = try makeInMemoryContainer()
    _ = try BackupManager.shared.restoreBackup(from: url, into: container)
    let context = ModelContext(container)
    return try context.fetch(FetchDescriptor<DayEntry>())
  }

  // MARK: - Multi-doodle round-trip (the JOO-155 fix)

  @Test func multiDoodleDaySurvivesBackupRoundTrip() throws {
    let entry = DayEntry(body: "hello", calendarDate: CalendarDate(year: 2025, month: 3, day: 14))
    entry.setDoodles([
      Doodle(drawingData: bytes("primary"), thumbnail20: bytes("p20"), thumbnail200: bytes("p200")),
      Doodle(drawingData: bytes("second"), thumbnail20: bytes("s20"), thumbnail200: bytes("s200")),
      Doodle(drawingData: bytes("third")),
    ])

    let restored = try roundTrip([entry])
    #expect(restored.count == 1)
    let day = try #require(restored.first)

    // All three doodles survive, in order — not just the primary.
    #expect(day.doodleCount == 3)
    #expect(day.doodles.map(\.drawingData) == [bytes("primary"), bytes("second"), bytes("third")])
    // Primary still backs the scalar fields; extras live in the blob.
    #expect(day.drawingData == bytes("primary"))
    #expect(day.drawingThumbnail20 == bytes("p20"))
    #expect(day.drawingThumbnail200 == bytes("p200"))
    #expect(day.extraDoodlesData != nil)
    // Extra doodles keep their thumbnails too.
    #expect(day.doodles[1].thumbnail20 == bytes("s20"))
    #expect(day.doodles[1].thumbnail200 == bytes("s200"))
    #expect(day.body == "hello")
  }

  // MARK: - Single-doodle day stays byte-identical

  @Test func singleDoodleDayHasNoExtrasAfterRoundTrip() throws {
    let entry = DayEntry(body: "", calendarDate: CalendarDate(year: 2025, month: 7, day: 20))
    entry.appendDoodle(drawingData: bytes("only"), thumbnail20: bytes("t20"), thumbnail200: nil)

    let restored = try roundTrip([entry])
    let day = try #require(restored.first)
    #expect(day.doodleCount == 1)
    #expect(day.drawingData == bytes("only"))
    #expect(day.drawingThumbnail20 == bytes("t20"))
    #expect(day.extraDoodlesData == nil)
  }

  // MARK: - Backward compatibility with pre-multi-doodle backups

  @Test func legacyBackupWithoutExtraDoodlesKeyStillRestores() throws {
    // A backup written before the multi-doodle feature has no `extraDoodlesData`
    // key at all — it must still decode (as a single-doodle day), not throw.
    let legacyJSON = """
    [{
      "body": "legacy",
      "createdAt": 764726400,
      "dateString": "2025-03-14",
      "drawingData": "\(bytes("legacy-drawing").base64EncodedString())"
    }]
    """
    let data = try #require(legacyJSON.data(using: .utf8))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("joodle-legacy-test-\(UUID().uuidString).json")
    try data.write(to: url, options: .atomic)
    defer { try? FileManager.default.removeItem(at: url) }

    let container = try makeInMemoryContainer()
    let count = try BackupManager.shared.restoreBackup(from: url, into: container)
    #expect(count == 1)

    let context = ModelContext(container)
    let day = try #require(try context.fetch(FetchDescriptor<DayEntry>()).first)
    #expect(day.body == "legacy")
    #expect(day.drawingData == bytes("legacy-drawing"))
    #expect(day.extraDoodlesData == nil)
    #expect(day.doodleCount == 1)
  }
}
