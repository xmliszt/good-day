//
//  DayEntryDoodleTests.swift
//  JoodleTests
//
//  Invariants for the multiple-doodles-per-day model API on `DayEntry`. Doodle 0
//  is mirrored on the scalar `drawingData`/thumbnail fields for backward
//  compatibility; doodles 1… live in the additive `extraDoodlesData` blob. These
//  tests pin the ordering, the per-day cap, primary-promotion on delete, the
//  duplicate-merge used for CloudKit conflict cleanup, and the storage split.
//

import Foundation
import Testing

@testable import Joodle

struct DayEntryDoodleTests {
  private func bytes(_ s: String) -> Data { Data(s.utf8) }

  private func makeEntry(_ ymd: (Int, Int, Int) = (2025, 3, 14)) -> DayEntry {
    DayEntry(body: "", calendarDate: CalendarDate(year: ymd.0, month: ymd.1, day: ymd.2))
  }

  // MARK: - Empty state

  @Test func emptyDayHasNoDoodles() {
    let entry = makeEntry()
    #expect(entry.doodles.isEmpty)
    #expect(entry.doodleCount == 0)
    #expect(entry.canAddDoodle)
  }

  // MARK: - Cap

  @Test func perDayCapIsThree() {
    #expect(DayEntry.maxDoodlesPerDay == 3)
  }

  @Test func appendFillsToCapThenRefuses() {
    let entry = makeEntry()
    #expect(entry.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil))
    #expect(entry.appendDoodle(drawingData: bytes("b"), thumbnail20: nil, thumbnail200: nil))
    #expect(entry.appendDoodle(drawingData: bytes("c"), thumbnail20: nil, thumbnail200: nil))
    #expect(entry.doodleCount == DayEntry.maxDoodlesPerDay)
    #expect(!entry.canAddDoodle)
    // The one past the cap is refused and leaves the list untouched.
    #expect(entry.appendDoodle(drawingData: bytes("d"), thumbnail20: nil, thumbnail200: nil) == false)
    #expect(entry.doodleCount == DayEntry.maxDoodlesPerDay)
    #expect(!entry.doodles.map(\.drawingData).contains(bytes("d")))
  }

  // MARK: - Primary mirror / storage split

  @Test func firstDoodleBacksScalarFieldsAndExtrasSpillToBlob() {
    let entry = makeEntry()
    entry.appendDoodle(drawingData: bytes("primary"), thumbnail20: bytes("t20"), thumbnail200: bytes("t200"))
    #expect(entry.drawingData == bytes("primary"))
    #expect(entry.drawingThumbnail20 == bytes("t20"))
    #expect(entry.drawingThumbnail200 == bytes("t200"))
    // A single doodle keeps the extras blob empty.
    #expect(entry.extraDoodlesData == nil)

    entry.appendDoodle(drawingData: bytes("second"), thumbnail20: nil, thumbnail200: nil)
    #expect(entry.drawingData == bytes("primary"))
    #expect(entry.extraDoodlesData != nil)
    #expect(entry.doodleCount == 2)
  }

  @Test func extrasRoundTripThroughStorage() throws {
    let entry = makeEntry()
    entry.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil)
    entry.appendDoodle(drawingData: bytes("b"), thumbnail20: bytes("b20"), thumbnail200: bytes("b200"))
    let extra = try #require(entry.extraDoodlesData)
    let decoded = try JSONDecoder().decode([Doodle].self, from: extra)
    #expect(decoded.count == 1)
    #expect(decoded[0].drawingData == bytes("b"))
    #expect(decoded[0].thumbnail20 == bytes("b20"))
    #expect(decoded[0].thumbnail200 == bytes("b200"))
  }

  // MARK: - Update

  @Test func updateOverwritesPreservingID() throws {
    let entry = makeEntry()
    entry.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil)
    entry.appendDoodle(drawingData: bytes("b"), thumbnail20: nil, thumbnail200: nil)
    let idBefore = try #require(entry.doodles[safe: 1]?.id)
    entry.updateDoodle(at: 1, drawingData: bytes("b2"), thumbnail20: nil, thumbnail200: nil)
    #expect(entry.doodles.count == 2)
    #expect(entry.doodles[1].drawingData == bytes("b2"))
    #expect(entry.doodles[1].id == idBefore)
  }

  @Test func updateOnePastEndAppends() {
    let entry = makeEntry()
    entry.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil)
    entry.updateDoodle(at: 1, drawingData: bytes("b"), thumbnail20: nil, thumbnail200: nil)
    #expect(entry.doodleCount == 2)
    #expect(entry.doodles[1].drawingData == bytes("b"))
  }

  @Test func updateOutOfRangeIsNoOp() {
    let entry = makeEntry()
    entry.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil)
    entry.updateDoodle(at: 5, drawingData: bytes("x"), thumbnail20: nil, thumbnail200: nil)
    #expect(entry.doodleCount == 1)
    #expect(entry.doodles[0].drawingData == bytes("a"))
  }

  // MARK: - Remove / primary promotion

  @Test func removingPrimaryPromotesNextIntoScalarFields() {
    let entry = makeEntry()
    entry.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil)
    entry.appendDoodle(drawingData: bytes("b"), thumbnail20: bytes("bt20"), thumbnail200: nil)
    entry.removeDoodle(at: 0)
    #expect(entry.doodleCount == 1)
    #expect(entry.drawingData == bytes("b"))
    #expect(entry.drawingThumbnail20 == bytes("bt20"))
    #expect(entry.extraDoodlesData == nil)
  }

  @Test func removingOnlyDoodleClearsAllDrawingData() {
    let entry = makeEntry()
    entry.appendDoodle(drawingData: bytes("a"), thumbnail20: bytes("t"), thumbnail200: nil)
    entry.removeDoodle(at: 0)
    #expect(entry.doodles.isEmpty)
    #expect(entry.drawingData == nil)
    #expect(entry.drawingThumbnail20 == nil)
    #expect(entry.extraDoodlesData == nil)
    #expect(entry.canAddDoodle)
  }

  @Test func removeOutOfRangeIsNoOp() {
    let entry = makeEntry()
    entry.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil)
    entry.removeDoodle(at: 9)
    #expect(entry.doodleCount == 1)
  }

  // MARK: - setDoodles

  @Test func setDoodlesCapsToMaxAndMirrorsPrimary() {
    let entry = makeEntry()
    let many = (0..<10).map { Doodle(drawingData: bytes("d\($0)")) }
    entry.setDoodles(many)
    #expect(entry.doodleCount == DayEntry.maxDoodlesPerDay)
    #expect(entry.drawingData == bytes("d0"))
  }

  @Test func setDoodlesEmptyClears() {
    let entry = makeEntry()
    entry.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil)
    entry.setDoodles([])
    #expect(entry.doodles.isEmpty)
    #expect(entry.drawingData == nil)
    #expect(entry.extraDoodlesData == nil)
  }

  // MARK: - Stable primary identity

  @Test func primaryDoodleIDIsStableAcrossReads() throws {
    let entry = makeEntry((2025, 7, 20))
    entry.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil)
    let idA = try #require(entry.doodles.first?.id)
    // Mutating the list (adding a second doodle) must not change doodle 0's id —
    // the carousel cross-fade and card animations rely on stable identity.
    entry.appendDoodle(drawingData: bytes("b"), thumbnail20: nil, thumbnail200: nil)
    let idB = try #require(entry.doodles.first?.id)
    #expect(idA == idB)
  }

  // MARK: - mergeDoodles (CloudKit-conflict cleanup)

  @Test func mergeAddsNonDuplicatesAndRespectsCap() {
    let target = makeEntry((2025, 1, 1))
    target.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil)
    let source = makeEntry((2025, 1, 1))
    source.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil)  // duplicate of target
    source.appendDoodle(drawingData: bytes("b"), thumbnail20: nil, thumbnail200: nil)
    source.appendDoodle(drawingData: bytes("c"), thumbnail20: nil, thumbnail200: nil)

    let didAdd = DayEntry.mergeDoodles(from: source, into: target)
    #expect(didAdd)
    // a (kept) + b + c = 3, exactly the cap; the duplicate "a" is skipped.
    #expect(target.doodleCount == DayEntry.maxDoodlesPerDay)
    let allBytes = target.doodles.map(\.drawingData)
    #expect(allBytes.contains(bytes("a")))
    #expect(allBytes.contains(bytes("b")))
    #expect(allBytes.contains(bytes("c")))
  }

  @Test func mergeFromEmptySourceReturnsFalse() {
    let target = makeEntry()
    target.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil)
    let source = makeEntry()
    #expect(DayEntry.mergeDoodles(from: source, into: target) == false)
    #expect(target.doodleCount == 1)
  }

  @Test func mergeStopsAtCapWithoutOverflowing() {
    let target = makeEntry((2025, 2, 2))
    target.appendDoodle(drawingData: bytes("a"), thumbnail20: nil, thumbnail200: nil)
    target.appendDoodle(drawingData: bytes("b"), thumbnail20: nil, thumbnail200: nil)
    let source = makeEntry((2025, 2, 2))
    source.appendDoodle(drawingData: bytes("c"), thumbnail20: nil, thumbnail200: nil)
    source.appendDoodle(drawingData: bytes("d"), thumbnail20: nil, thumbnail200: nil)

    #expect(DayEntry.mergeDoodles(from: source, into: target))
    #expect(target.doodleCount == DayEntry.maxDoodlesPerDay)  // a, b, c — d dropped at cap
    #expect(!target.doodles.map(\.drawingData).contains(bytes("d")))
  }
}

// MARK: - Test helpers

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
