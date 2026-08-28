//
//  DoodleCarouselCell.swift
//  Joodle
//
//  Renders a day's doodles. For the common single-doodle day it's a plain
//  `DrawingDisplayView` with no timer; a multi-doodle day owns a self-driving
//  `TimelineView` clock that cross-fades through its doodles.
//

import SwiftUI

struct DoodleCarouselCell: View {
  let entry: DayEntry?
  let doodles: [Doodle]
  let displaySize: CGFloat
  let dotStyle: DotStyle
  var accent: Bool = false
  let highlighted: Bool
  let scale: CGFloat
  var strokeMultiplier: CGFloat = 1.0

  /// Seconds each doodle stays fully visible before cross-fading to the next.
  private static let cycleInterval: TimeInterval = 2.5

  /// A stable per-cell key used to stagger this day's cross-fade phase. Days with
  /// no entry fall back to an empty key (they never reach the multi-doodle path).
  private var phaseKey: String { entry?.dateString ?? "" }

  var body: some View {
    if doodles.count <= 1 {
      // Overwhelmingly common case: keep it as cheap as a single static view.
      DrawingDisplayView(
        entry: entry,
        doodle: doodles.first,
        displaySize: displaySize,
        dotStyle: dotStyle,
        accent: accent,
        highlighted: highlighted,
        scale: scale,
        useThumbnail: true,
        strokeMultiplier: strokeMultiplier
      )
    } else {
      // The clock lives inside this view and derives its index purely from the
      // timeline date, so it keeps advancing even while an Equatable parent gate
      // skips re-rendering the surrounding cell. The schedule is anchored to this
      // cell's own phase so redraws land on its staggered boundaries — not the
      // global grid every other cell would share with a `.now` anchor.
      TimelineView(.periodic(from: Self.scheduleAnchor(for: phaseKey), by: Self.cycleInterval)) { timeline in
        let index = currentIndex(at: timeline.date)
        ZStack {
          ForEach(Array(doodles.enumerated()), id: \.element.id) { offset, doodle in
            DrawingDisplayView(
              entry: entry,
              doodle: doodle,
              displaySize: displaySize,
              dotStyle: dotStyle,
              accent: accent,
              highlighted: highlighted,
              scale: scale,
              useThumbnail: true,
              strokeMultiplier: strokeMultiplier
            )
            .opacity(offset == index ? 1 : 0)
          }
        }
        .animation(.springFkingSatifying, value: index)
      }
    }
  }

  private func currentIndex(at date: Date) -> Int {
    Self.displayedIndex(count: doodles.count, seed: phaseKey, at: date)
  }

  /// The doodle index this cell is showing for a day with `count` doodles at a
  /// given instant. Derived from absolute time plus a deterministic per-cell
  /// phase offset (see `phaseOffset(for:)`), so any caller (e.g. the grid tap
  /// handler opening the bottom sheet) can recover the on-screen doodle without
  /// the cell exposing state — and different days advance at different instants
  /// instead of all swapping at once. Returns 0 for 0/1-doodle days.
  static func displayedIndex(count: Int, seed: String, at date: Date = Date()) -> Int {
    guard count > 1 else { return 0 }
    let shifted = date.timeIntervalSinceReferenceDate + phaseOffset(for: seed)
    let step = Int(shifted / cycleInterval)
    return ((step % count) + count) % count
  }

  /// A deterministic offset in `[0, cycleInterval)` derived from a per-cell key
  /// (the day's dateString), FNV-1a hashed. Adding it before the divide shifts
  /// each cell's swap boundaries, so multi-doodle days cross-fade at staggered,
  /// seemingly-random times rather than in unison. Same key → same offset every
  /// run, so the value is stable and never true randomness.
  static func phaseOffset(for key: String) -> TimeInterval {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in key.utf8 {
      hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    // 10_000 buckets is far finer than the eye can resolve, so offsets read as
    // random while staying integer-stable and independent of the cycle length.
    let fraction = Double(hash % 10_000) / 10_000
    return cycleInterval * fraction
  }

  /// The `TimelineView` schedule anchor for a cell with the given phase key. The
  /// cell's swap boundaries sit at `k * cycleInterval - phaseOffset` in reference
  /// time, so anchoring at `k = 0` lines every scheduled redraw up with a swap.
  private static func scheduleAnchor(for key: String) -> Date {
    Date(timeIntervalSinceReferenceDate: -phaseOffset(for: key))
  }
}
