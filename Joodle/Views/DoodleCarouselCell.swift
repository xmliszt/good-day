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
      // skips re-rendering the surrounding cell.
      TimelineView(.periodic(from: .now, by: Self.cycleInterval)) { timeline in
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
    Self.displayedIndex(count: doodles.count, at: date)
  }

  /// The doodle index this cell is showing for a day with `count` doodles at a
  /// given instant. Derived purely from absolute time, so any caller (e.g. the
  /// grid tap handler opening the bottom sheet) can recover the on-screen doodle
  /// without the cell exposing state. Returns 0 for 0/1-doodle days.
  static func displayedIndex(count: Int, at date: Date = Date()) -> Int {
    guard count > 1 else { return 0 }
    let step = Int(date.timeIntervalSinceReferenceDate / cycleInterval)
    return ((step % count) + count) % count
  }
}
