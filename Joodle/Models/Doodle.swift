//
//  Doodle.swift
//  Joodle
//
//  A single drawing within a day. A `DayEntry` holds an ordered array of these
//  (up to `DayEntry.maxDoodlesPerDay`). Index 0 is persisted on the entry's
//  scalar `drawingData`/thumbnail fields for backward compatibility; the rest
//  live in the entry's `extraDoodlesData` blob. See `DayEntry.doodles`.
//

import Foundation

struct Doodle: Codable, Identifiable, Equatable {
  var id: UUID
  /// JSON-encoded `[PathData]` — the same wire format as `DayEntry.drawingData`.
  var drawingData: Data
  var thumbnail20: Data?
  var thumbnail200: Data?

  init(id: UUID = UUID(), drawingData: Data, thumbnail20: Data? = nil, thumbnail200: Data? = nil) {
    self.id = id
    self.drawingData = drawingData
    self.thumbnail20 = thumbnail20
    self.thumbnail200 = thumbnail200
  }
}
