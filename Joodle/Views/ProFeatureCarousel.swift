//
//  ProFeatureCarousel.swift
//  Joodle
//
//  A swipeable, auto-advancing showcase of Joodle Pro features rendered as live
//  SwiftUI demos (no screenshots or video). Sits above the comparison table on
//  the paywall to create desire before the rational Free-vs-Pro breakdown.
//

import SwiftUI
import UIKit

// MARK: - ProFeatureCarousel

struct ProFeatureCarousel: View {
  private enum Feature: CaseIterable, Identifiable {
    case unlimited, autotrace, rainbow, wiggly, watermark, backdrop

    var id: Self { self }

    /// The card that best matches the paywall source that triggered this screen,
    /// so the carousel opens on the feature the user was reaching for. Unmapped
    /// sources fall back to the first card.
    static func matching(source: String) -> Feature {
      switch source {
      case "auto_trace", "auto_trace_limit": return .autotrace
      case "watermark_toggle", "wiggly_share_card": return .watermark
      case "wiggly_strokes_toggle": return .wiggly
      case "locked_color": return .rainbow
      case "experimental_time_backdrop_toggle": return .backdrop
      // The two count-based names predate the day-scoped model; they stay mapped
      // so the trial-claim sheet and any lingering link still land on this card.
      case "entry_limit", "doodle_limit", "backfill", "move_doodle": return .unlimited
      default: return .unlimited
      }
    }

    var title: LocalizedStringResource {
      switch self {
      case .unlimited: return "Doodle every day, forever"
      case .autotrace: return "Trace a photo into a doodle"
      case .rainbow:   return "A color for every month"
      case .wiggly:    return "Strokes that come alive"
      case .watermark: return "Share without the watermark"
      case .backdrop:  return "Access to fun experiments"
      }
    }

    var subtitle: LocalizedStringResource {
      switch self {
      case .unlimited: return "Free fills today, one doodle a day. Pro backfills any day — move, catch up, stack up to three, and complete your whole year."
      case .autotrace: return "Point Joodle at any photo and it sketches the outline for you. Free traces once a day — Pro, as many as you like."
      case .rainbow:   return "Let your year bloom into more vibrant colors, or all twelve shades of the rainbow theme."
      case .wiggly:    return "Give every stroke a lively, hand-drawn wiggle."
      case .watermark: return "Free adds a small Joodle mark. Pro exports are clean — just your doodle."
      case .backdrop:  return "A pool of liquid drifts with passing time, and more future experiments!"
      }
    }

    var next: Feature {
      let all = Feature.allCases
      let index = all.firstIndex(of: self) ?? 0
      return all[(index + 1) % all.count]
    }

    /// How long this card's demo takes to play its story once. The animated
    /// cards report their own play-through; the continuously-looping ones (a
    /// boil, a settling pool) get a sensible fixed viewing time.
    var playDuration: Double {
      switch self {
      case .unlimited: return UnlimitedDoodlesDemo.playThroughDuration
      case .autotrace: return AutoTraceDemo.playThroughDuration
      case .rainbow:   return RainbowThemeDemo.playThroughDuration
      case .wiggly:    return WigglyStrokesDemo.playThroughDuration
      case .watermark: return WatermarkFreeDemo.playThroughDuration
      case .backdrop:  return 4.5
      }
    }
  }

  @State private var selection: Feature

  /// The paywall source that triggered this carousel; picks the starting card.
  init(source: String = "unknown") {
    _selection = State(initialValue: Feature.matching(source: source))
  }

  private let showcaseHeight: CGFloat = 300
  private let cornerRadius: CGFloat = 28
  private let blurBandHeight: CGFloat = 88

  /// Beat of stillness on the finished demo before advancing, so a card doesn't
  /// snap away the instant its animation lands.
  private let trailingDelay: Double = 1.2

  var body: some View {
    VStack(spacing: 18) {
      showcase
      caption
    }
    // Dwell = the current card's play-through + a trailing pause. Re-armed every
    // time the visible card changes, so a manual swipe resets the timer and it
    // never advances mid-animation or fights the user.
    .task(id: selection) {
      try? await Task.sleep(for: .seconds(selection.playDuration + trailingDelay))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut) { selection = selection.next }
    }
  }

  // MARK: Showcase

  private var showcase: some View {
    TabView(selection: $selection) {
      ForEach(Feature.allCases) { feature in
        demo(for: feature).tag(feature)
      }
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
    .frame(height: showcaseHeight)
    .overlay(alignment: .bottom) {
      // Fade the demo's bottom edge into the paywall background so the page dots
      // read cleanly over it. Matched to the real background color (not a frosted
      // material) so it dissolves seamlessly instead of showing as a gray band.
      LinearGradient(
        colors: [.clear, Color(uiColor: .systemBackground)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: blurBandHeight)
      .allowsHitTesting(false)
    }
    .overlay(alignment: .bottom) {
      pageDots.padding(.bottom, 4)
    }
  }

  @ViewBuilder
  private func demo(for feature: Feature) -> some View {
    switch feature {
    case .unlimited: showcaseTile { UnlimitedDoodlesDemo(isActive: feature == selection) }
    case .autotrace: showcaseTile { AutoTraceDemo(isActive: feature == selection) }
    case .rainbow:   showcaseTile { RainbowThemeDemo(isActive: feature == selection) }
    case .wiggly:    showcaseTile { WigglyStrokesDemo(isActive: feature == selection) }
    case .watermark: showcaseTile { WatermarkFreeDemo(isActive: feature == selection) }
    case .backdrop:  LivingBackdropDemo()
    }
  }

  private func showcaseTile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    // Transparent so the demo sits directly on the paywall's (dark) background
    // and the carousel blends in rather than reading as a separate card.
    ZStack {
      Color.clear
      content().padding(24)
    }
  }

  private var pageDots: some View {
    HStack(spacing: 7) {
      ForEach(Feature.allCases) { feature in
        Capsule()
          .fill(feature == selection ? Color.appAccent : Color.white.opacity(0.3))
          .frame(width: feature == selection ? 20 : 7, height: 7)
      }
    }
    .animation(.springFkingSatifying, value: selection)
  }

  private var caption: some View {
    VStack(spacing: 6) {
      Text(selection.title)
        .font(.appFont(size: 22, weight: .bold))
        .foregroundColor(.appTextPrimary)

      Text(selection.subtitle)
        .font(.appSubheadline())
        .foregroundColor(.appTextSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .id(selection)
    .transition(.opacity)
    .animation(.easeInOut, value: selection)
  }
}

// MARK: - Year Grid (shared by unlimited + rainbow demos)

/// Smoothstep easing on 0…1.
private func smoothstep(_ t: Double) -> Double {
  let x = min(max(t, 0), 1)
  return x * x * (3 - 2 * x)
}

/// Alpha for a dot given the wavefront position (in day units) and a ramp width:
/// 1 well behind the front, easing to 0 across the ramp band so the sweep reads
/// soft instead of snapping dot-by-dot.
private func frontAlpha(front: Double, day: Int, ramp: Double) -> Double {
  min(max((front - Double(day)) / ramp, 0), 1)
}

/// A grid where an empty day is a small dot and a doodled day is a real doodle
/// (from `CAROUSEL_DOODLES`) — a doodle is a stroke, not a fill. `doodle`
/// crossfades each cell from dot (0) to drawing (1); `strokeColor` is the
/// drawing's color, and the optional `overlayColor` fades a second color on top
/// (the rainbow recolor). Each day gets a fixed doodle from the set, cycled so
/// the field reads as a varied year rather than one repeated glyph.
private struct YearGridCanvas: View {
  let totalDays: Int
  let columns: Int
  let doodle: (Int) -> Double
  var strokeColor: (Int) -> Color = { _ in .appAccent }
  var overlayColor: (Int) -> Color = { _ in .clear }

  var body: some View {
    Canvas { context, size in
      let rows = Int(ceil(Double(totalDays) / Double(columns)))
      // Square cells so every row is the same height and the grid reads as an
      // even field regardless of which card it's on.
      let cell = min(size.width / CGFloat(columns), size.height / CGFloat(rows))
      let originX = (size.width - cell * CGFloat(columns)) / 2
      let originY = (size.height - cell * CGFloat(rows)) / 2
      let glyphBox = cell * 0.78
      let dotRadius = cell * 0.11
      let doodleLineWidth = max(0.6, cell * 0.025)
      let lineStyle = StrokeStyle(lineWidth: doodleLineWidth, lineCap: .round, lineJoin: .round)
      let doodleCount = CAROUSEL_DOODLES.count

      for day in 0..<totalDays {
        let cellX = originX + CGFloat(day % columns) * cell
        let cellY = originY + CGFloat(day / columns) * cell
        let progress = doodle(day)

        // Empty day: a placeholder dot that fades out as it becomes a doodle.
        if progress < 1 {
          let center = CGPoint(x: cellX + cell / 2, y: cellY + cell / 2)
          let dot = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
          context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.12 * (1 - progress))))
        }

        // Doodled day: a real drawing, fit and centered into the cell, fading in.
        if progress > 0, doodleCount > 0 {
          let art = CAROUSEL_DOODLES[day % doodleCount]
          let box = CGRect(
            x: cellX + (cell - glyphBox) / 2,
            y: cellY + (cell - glyphBox) / 2,
            width: glyphBox,
            height: glyphBox
          )
          let fit = fittedTransform(bounds: art.bounds, in: box)

          var strokes = Path()
          for pathData in art.paths {
            if pathData.isDot {
              if let p = pathData.points.first {
                let c = CGPoint(x: p.x * fit.scale + fit.tx, y: p.y * fit.scale + fit.ty)
                // A pen dot is a single tap of the nib — its diameter matches the
                // stroke width, not the cell's placeholder dot. Otherwise a
                // heavily-stippled doodle (e.g. the cactus) floods its whole cell.
                let r = doodleLineWidth / 2
                let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                context.fill(dot, with: .color(strokeColor(day).opacity(progress)))
                context.fill(dot, with: .color(overlayColor(day).opacity(progress)))
              }
            } else if pathData.points.count > 1 {
              for (index, point) in pathData.points.enumerated() {
                let pt = CGPoint(x: point.x * fit.scale + fit.tx, y: point.y * fit.scale + fit.ty)
                if index == 0 { strokes.move(to: pt) } else { strokes.addLine(to: pt) }
              }
            }
          }
          context.stroke(strokes, with: .color(strokeColor(day).opacity(progress)), style: lineStyle)
          context.stroke(strokes, with: .color(overlayColor(day).opacity(progress)), style: lineStyle)
        }
      }
    }
  }
}

/// A uniform scale + translation that fits `bounds` into `rect`, preserving
/// aspect ratio and centering. Apply as `point * scale + (tx, ty)`.
private func fittedTransform(bounds: CGRect, in rect: CGRect) -> (scale: CGFloat, tx: CGFloat, ty: CGFloat) {
  let width = max(bounds.width, 0.0001)
  let height = max(bounds.height, 0.0001)
  let scale = min(rect.width / width, rect.height / height)
  let tx = rect.minX + (rect.width - width * scale) / 2 - bounds.minX * scale
  let ty = rect.minY + (rect.height - height * scale) / 2 - bounds.minY * scale
  return (scale, tx, ty)
}

private let demoCellCount = 150
private let demoGridColumns = 15
/// Where "today" sits in the demo year — about two thirds through, so the card
/// has a visibly empty past to backfill and a shorter future still to come.
private let demoTodayCell = 100

// MARK: - Demo Badge

/// The consistent state pill shown at the top of every card. It normally only
/// says Free or Pro — the demo itself shows what changes, so the badge stays
/// terse. `detail` is an opt-in qualifier for the one card whose story is a
/// per-day *quantity* the grid can't legibly draw (1 free vs up to 3 Pro); every
/// other card leaves it nil.
private struct DemoBadge: View {
  let isPro: Bool
  var detail: LocalizedStringResource? = nil

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: isPro ? "crown.fill" : "lock.fill")
        .font(.appFont(size: 11, weight: .bold))
      Text(isPro ? String(localized: "Pro") : String(localized: "Free"))
        .font(.appCaption(weight: .bold))
      if let detail {
        Text(detail)
          .font(.appCaption())
          .foregroundColor(.white.opacity(0.45))
      }
    }
    .foregroundColor(isPro ? .appAccent : .white.opacity(0.6))
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Capsule().fill(.white.opacity(0.08)))
    .animation(.easeInOut, value: isPro)
  }
}

// MARK: - Unlimited Doodles Demo

/// Loops the day-scoped story: free lights exactly one cell (today), then Pro
/// backfills the empty past *backwards* from today before carrying on forwards
/// through the rest of the year. The backward front is the point — a plain
/// left-to-right fill would read as "keep going" instead of "catch up". Driven
/// off a `TimelineView` clock (not `withAnimation`) because `Canvas` won't
/// interpolate an animated `@State` — it would snap to the final frame.
private struct UnlimitedDoodlesDemo: View {
  let isActive: Bool
  @State private var epoch = Date()

  /// Today's single cell lighting up — one cell, so it needs no travel time.
  static let todayFillDuration = 0.8
  static let freeHold = 1.2
  /// The catch-up beat: a front travelling from today back to the start of the year.
  static let backfillDuration = 2.0
  /// The rest of the year, filled forwards from today.
  static let forwardFillDuration = 1.4
  static let proHold = 1.8
  static let drainDuration = 1.3
  static let emptyHold = 0.8

  /// One full loop, including the drain-and-reset tail — only seen if the viewer
  /// lingers past the carousel's dwell.
  static var cycleDuration: Double {
    playThroughDuration + drainDuration + emptyHold
  }

  /// Time to reach the end of the story beat (the complete year). The carousel
  /// advances after this plus its trailing delay, before the drain.
  static var playThroughDuration: Double {
    todayFillDuration + freeHold + backfillDuration + forwardFillDuration + proHold
  }

  /// The demo's two wavefronts plus the erase tail, for a point in the loop.
  ///
  /// - `today`: alpha of today's cell, the only thing free lights up.
  /// - `backFront`: descends from `demoTodayCell` to −1; a past day is drawn once
  ///   the front has travelled below it.
  /// - `forwardFront`: ascends from `demoTodayCell` to `demoCellCount`.
  /// - `eraseFront`: descends through the grid during the reset tail, clearing
  ///   what the two fronts drew; parked past the end for the rest of the loop.
  private struct Beat {
    var today: Double
    var backFront: Double
    var forwardFront: Double
    var eraseFront: Double
    var isPro: Bool
  }

  private func beat(at time: Double) -> Beat {
    let today = Double(demoTodayCell)
    let end = Double(demoCellCount)
    // Parked one ramp past the last cell, so nothing is being erased.
    let noErase = end + 1

    var x = time.truncatingRemainder(dividingBy: Self.cycleDuration)

    if x < Self.todayFillDuration {
      return Beat(today: smoothstep(x / Self.todayFillDuration),
                  backFront: today, forwardFront: today, eraseFront: noErase, isPro: false)
    }
    x -= Self.todayFillDuration
    if x < Self.freeHold {
      return Beat(today: 1, backFront: today, forwardFront: today, eraseFront: noErase, isPro: false)
    }
    x -= Self.freeHold
    if x < Self.backfillDuration {
      // today → −1, so cell 0 lands fully drawn at the end of the beat.
      let p = smoothstep(x / Self.backfillDuration)
      return Beat(today: 1,
                  backFront: today - (today + 1) * p,
                  forwardFront: today, eraseFront: noErase, isPro: true)
    }
    x -= Self.backfillDuration
    if x < Self.forwardFillDuration {
      let p = smoothstep(x / Self.forwardFillDuration)
      return Beat(today: 1, backFront: -1,
                  forwardFront: today + (end - today) * p,
                  eraseFront: noErase, isPro: true)
    }
    x -= Self.forwardFillDuration
    if x < Self.proHold {
      return Beat(today: 1, backFront: -1, forwardFront: end, eraseFront: noErase, isPro: true)
    }
    x -= Self.proHold
    if x < Self.drainDuration {
      return Beat(today: 1, backFront: -1, forwardFront: end,
                  eraseFront: noErase - (noErase + 1) * smoothstep(x / Self.drainDuration),
                  isPro: true)
    }
    return Beat(today: 0, backFront: today, forwardFront: today, eraseFront: noErase, isPro: false)
  }

  /// Ramp of 1: a soft leading edge wider than one cell can't fully resolve when
  /// a front parks on an integer plateau (today, then the year's two ends), which
  /// would leave the last doodles frozen half-faded. One cell keeps them crisp.
  private static let ramp = 1.0

  private func alpha(day: Int, beat: Beat) -> Double {
    let drawn: Double
    if day == demoTodayCell {
      drawn = beat.today
    } else if day < demoTodayCell {
      // Mirror of `frontAlpha`: lit once the backward front has passed below.
      drawn = min(max((Double(day) - beat.backFront) / Self.ramp, 0), 1)
    } else {
      drawn = frontAlpha(front: beat.forwardFront, day: day, ramp: Self.ramp)
    }
    return min(drawn, frontAlpha(front: beat.eraseFront, day: day, ramp: Self.ramp))
  }

  var body: some View {
    TimelineView(.animation(paused: !isActive)) { timeline in
      let beat = beat(at: timeline.date.timeIntervalSince(epoch))

      VStack(spacing: 14) {
        DemoBadge(
          isPro: beat.isPro,
          detail: beat.isPro ? "Any day, up to 3" : "Today, 1 a day"
        )
        YearGridCanvas(
          totalDays: demoCellCount,
          columns: demoGridColumns,
          doodle: { day in alpha(day: day, beat: beat) }
        )
      }
    }
    // Restart the beat each time this card becomes visible, so its play-through
    // stays in step with the carousel's dwell timer.
    .onChange(of: isActive) { _, active in
      if active { epoch = Date() }
    }
  }
}

// MARK: - Auto-Trace Demo

/// A reference photo that a Joodle line-drawing traces itself onto, then the
/// photo fades to leave the clean doodle — the auto-trace feature shown rather
/// than described. Strokes are baked (`AUTO_TRACE_DEMO_STROKES`) and revealed by
/// marching one wavefront through them in draw order, so it reads as being drawn.
private struct AutoTraceDemo: View {
  let isActive: Bool
  @State private var epoch = Date()

  static let photoHold = 1.1
  static let drawDuration = 2.6
  static let cleanHold = 1.8
  static let resetHold = 0.6

  static var cycleDuration: Double { photoHold + drawDuration + cleanHold + resetHold }

  /// Ends on the clean doodle; the reset tail runs only if the viewer lingers.
  static var playThroughDuration: Double { photoHold + drawDuration + cleanHold }

  /// Fraction of strokes drawn (0…1) and the photo's opacity for a point in the
  /// loop: the photo dims to a tracing reference while drawing, fades out for the
  /// clean reveal, then returns so the loop is seamless.
  private func state(at time: Double) -> (reveal: Double, photo: Double) {
    var x = time.truncatingRemainder(dividingBy: Self.cycleDuration)
    if x < Self.photoHold { return (0, 1) }
    x -= Self.photoHold
    if x < Self.drawDuration {
      let p = smoothstep(x / Self.drawDuration)
      return (p, 1 - 0.72 * p)
    }
    x -= Self.drawDuration
    if x < Self.cleanHold {
      let p = smoothstep(x / Self.cleanHold)
      return (1, 0.28 * (1 - p))
    }
    x -= Self.cleanHold
    let p = smoothstep(x / Self.resetHold)
    return (1 - p, p)
  }

  var body: some View {
    TimelineView(.animation(paused: !isActive)) { timeline in
      let s = state(at: timeline.date.timeIntervalSince(epoch))
      VStack(spacing: 14) {
        DemoBadge(isPro: s.reveal > 0.02)
        art(reveal: s.reveal, photoOpacity: s.photo)
      }
    }
    .onChange(of: isActive) { _, active in
      if active { epoch = Date() }
    }
  }

  private func art(reveal: Double, photoOpacity: Double) -> some View {
    ZStack {
      Image("AutoTraceSample")
        .resizable()
        .scaledToFill()
        .opacity(photoOpacity)

      Canvas { context, size in
        let scale = size.width / CANVAS_SIZE
        let lineWidth = max(DRAWING_LINE_WIDTH * scale, 1.5)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        var budget = Int((reveal * Double(AUTO_TRACE_DEMO_TOTAL_POINTS)).rounded())
        guard budget > 0 else { return }

        for stroke in AUTO_TRACE_DEMO_STROKES {
          if budget <= 0 { break }
          let n = min(stroke.points.count, budget)
          budget -= stroke.points.count
          let pts = stroke.points.prefix(n).map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
          guard let first = pts.first else { continue }
          if pts.count == 1 || stroke.isDot {
            let r = lineWidth / 2
            context.fill(
              Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2)),
              with: .color(.appAccent))
            continue
          }
          var path = Path()
          path.move(to: first)
          for point in pts.dropFirst() { path.addLine(to: point) }
          context.stroke(path, with: .color(.appAccent), style: style)
        }
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
    )
  }
}

// MARK: - Rainbow Theme Demo

/// A sweep recolors a full year of doodles from the single accent color into the
/// per-month rainbow palette, then resets and loops. Clock-driven so the Canvas
/// redraws every frame (see `UnlimitedDoodlesDemo`).
private struct RainbowThemeDemo: View {
  let isActive: Bool
  @State private var epoch = Date()

  static let pause = 0.6
  static let revealDuration = 2.2
  static let hold = 2.6
  static let resetDuration = 0.8

  static var cycleDuration: Double { pause + revealDuration + hold + resetDuration }

  /// Ends on the fully-rainbow year; the reset tail runs only if the viewer lingers.
  static var playThroughDuration: Double { pause + revealDuration + hold }

  /// Sweep position (0…1) across the year, eased in and out.
  private func reveal(at time: Double) -> Double {
    var x = time.truncatingRemainder(dividingBy: Self.cycleDuration)
    if x < Self.pause { return 0 }
    x -= Self.pause
    if x < Self.revealDuration { return smoothstep(x / Self.revealDuration) }
    x -= Self.revealDuration
    if x < Self.hold { return 1 }
    x -= Self.hold
    return 1 - smoothstep(x / Self.resetDuration)
  }

  var body: some View {
    TimelineView(.animation(paused: !isActive)) { timeline in
      let fraction = reveal(at: timeline.date.timeIntervalSince(epoch))
      let front = fraction * Double(demoCellCount)
      let isRainbow = fraction > 0.02

      VStack(spacing: 14) {
        DemoBadge(isPro: isRainbow)
        YearGridCanvas(
          totalDays: demoCellCount,
          columns: demoGridColumns,
          doodle: { _ in 1 },
          strokeColor: { _ in .appAccent },
          overlayColor: { day in
            let month = min(RainbowPalette.colors.count - 1, day * RainbowPalette.colors.count / demoCellCount)
            return RainbowPalette.colors[month].opacity(frontAlpha(front: front, day: day, ramp: 6))
          }
        )
      }
    }
    .onChange(of: isActive) { _, active in
      if active { epoch = Date() }
    }
  }
}

// MARK: - Wiggly Strokes Demo

/// A real doodle drawn 1:1 in canvas space, starting still then easing into the
/// live wigglypaint boil — so the Free→Pro difference is shown, not just stated.
/// The boil amplitude ramps from 0 to full over the transition.
private struct WigglyStrokesDemo: View {
  let isActive: Bool
  @State private var epoch = Date()

  static let stillHold = 1.6
  static let rampDuration = 1.0
  static let wiggleHold = 2.2
  static let resetHold = 0.6

  static var cycleDuration: Double { stillHold + rampDuration + wiggleHold + resetHold }
  static var playThroughDuration: Double { stillHold + rampDuration + wiggleHold }

  private var paths: [DoodlePathData] {
    CAROUSEL_DOODLES.first?.paths ?? []
  }

  /// Boil strength (0…1): 0 while still, easing to 1 as the strokes come alive.
  private func amplitudeFactor(at time: Double) -> Double {
    var x = time.truncatingRemainder(dividingBy: Self.cycleDuration)
    if x < Self.stillHold { return 0 }
    x -= Self.stillHold
    if x < Self.rampDuration { return smoothstep(x / Self.rampDuration) }
    x -= Self.rampDuration
    if x < Self.wiggleHold { return 1 }
    x -= Self.wiggleHold
    return 1 - smoothstep(x / Self.resetHold)
  }

  var body: some View {
    TimelineView(.animation(paused: !isActive)) { timeline in
      let time = timeline.date.timeIntervalSince(epoch)
      let factor = amplitudeFactor(at: time)
      let isWiggly = factor > 0.05

      VStack(spacing: 14) {
        DemoBadge(isPro: isWiggly)
        // Nudge the drawing up so it sits a touch higher in the tile.
        doodle(time: time, amplitudeFactor: factor)
          .padding(.bottom, 28)
      }
    }
    .onChange(of: isActive) { _, active in
      if active { epoch = Date() }
    }
  }

  private func doodle(time: Double, amplitudeFactor: Double) -> some View {
    Canvas { context, size in
      let scale = min(size.width, size.height) / DOODLE_CANVAS_SIZE
      context.translateBy(
        x: (size.width - DOODLE_CANVAS_SIZE * scale) / 2,
        y: (size.height - DOODLE_CANVAS_SIZE * scale) / 2
      )
      context.scaleBy(x: scale, y: scale)

      let frame = WigglyStroke.frameIndex(at: time)
      let amplitude = WigglyStroke.defaultAmplitude * amplitudeFactor
      for pathData in paths {
        let path = WigglyStroke.path(points: pathData.points, isDot: pathData.isDot, frame: frame, amplitude: amplitude)
        context.stroke(
          path,
          with: .color(.appAccent),
          style: StrokeStyle(lineWidth: DRAWING_LINE_WIDTH, lineCap: .round, lineJoin: .round)
        )
      }
    }
  }
}

// MARK: - Watermark-Free Sharing Demo

/// A boiling doodle — a shared Wiggly Minimal card — toggling between the Free
/// export (with the "Made with Joodle" watermark) and the clean Pro export, so
/// the difference is felt rather than described. Transparent like the other
/// cards, with the watermark tucked below the doodle where the carousel's bottom
/// fade won't swallow it.
private struct WatermarkFreeDemo: View {
  let isActive: Bool
  @State private var isPro = false

  static let freeHold = 2.0
  static let proHold = 2.4

  /// Ends on the clean Pro state; the loop keeps toggling if the viewer lingers.
  static var playThroughDuration: Double { freeHold + proHold }

  /// A fixed doodle — the second of the 2026 sample — so the card reads the same
  /// every time it comes around.
  private var paths: [DoodlePathData] {
    let doodle = CAROUSEL_DOODLES.count > 1 ? CAROUSEL_DOODLES[1] : CAROUSEL_DOODLES.first
    return doodle?.paths ?? []
  }

  var body: some View {
    VStack(spacing: 12) {
      DemoBadge(isPro: isPro)
      doodle
        .frame(maxWidth: .infinity)
        .frame(height: 120)
      watermark
        .opacity(isPro ? 0 : 1)
      Spacer(minLength: 0)
    }
    // Flip Free <-> Pro on a loop while visible, crossfading the watermark so the
    // "clean export" payoff lands. Paused off-screen to stay in step with the
    // carousel's dwell timer.
    .task(id: isActive) {
      guard isActive else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(isPro ? Self.proHold : Self.freeHold))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.5)) { isPro.toggle() }
      }
    }
    // Reset to Free each time the card appears so the reveal always plays
    // Free -> Pro in step with the dwell timer.
    .onChange(of: isActive) { _, active in
      if active { isPro = false }
    }
  }

  private var doodle: some View {
    TimelineView(.animation(paused: !isActive)) { timeline in
      Canvas { context, size in
        let scale = min(size.width, size.height) / DOODLE_CANVAS_SIZE
        context.translateBy(
          x: (size.width - DOODLE_CANVAS_SIZE * scale) / 2,
          y: (size.height - DOODLE_CANVAS_SIZE * scale) / 2
        )
        context.scaleBy(x: scale, y: scale)

        let frame = WigglyStroke.frameIndex(at: timeline.date.timeIntervalSinceReferenceDate)
        for pathData in paths {
          let path = WigglyStroke.path(points: pathData.points, isDot: pathData.isDot, frame: frame, amplitude: WigglyStroke.defaultAmplitude)
          context.stroke(
            path,
            with: .color(.appAccent),
            style: StrokeStyle(lineWidth: DRAWING_LINE_WIDTH, lineCap: .round, lineJoin: .round)
          )
        }
      }
    }
  }

  /// The same mark the Free export carries, mirrored inline so it sits where the
  /// viewer can see it rather than pinned to the clipped bottom-right corner.
  private var watermark: some View {
    HStack(spacing: 6) {
      Image("LaunchIcon")
        .resizable()
        .scaledToFit()
        .frame(width: 22, height: 22)
        .opacity(0.8)
      Text("Made with Joodle")
        .font(.appFont(size: 14))
        .foregroundColor(.appTextSecondary)
        .opacity(0.6)
    }
  }
}

// MARK: - Living Backdrop Demo

/// The real liquid metaball backdrop pinned at half fill, sitting *behind* a
/// year grid exactly as it does in the app — the feature in its true context.
private struct LivingBackdropDemo: View {
  private let filledThroughCell = Int(Double(demoCellCount) * 0.6)

  var body: some View {
    ZStack {
      Color.clear
      LiquidMetaballBackdropView(liquidOpacity: 0.4, fixedFillLevel: 0.5)
      VStack(spacing: 14) {
        DemoBadge(isPro: true)
        YearGridCanvas(
          totalDays: demoCellCount,
          columns: demoGridColumns,
          doodle: { day in day < filledThroughCell ? 1 : 0 }
        )
      }
      .padding(24)
    }
  }
}

// MARK: - Preview

#Preview("Pro Feature Carousel") {
  ZStack {
//    Color.black.ignoresSafeArea()
    ProFeatureCarousel()
  }
}

#Preview("Backdrop demo · grid over liquid") {
  ZStack {
    Color.black.ignoresSafeArea()
    LivingBackdropDemo()
      .frame(width: 320, height: 300)
      .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
  }
}

#Preview("Auto-trace demo · alignment check") {
  ZStack {
    Color.black.ignoresSafeArea()
    ZStack {
      Image("AutoTraceSample")
        .resizable()
        .scaledToFill()
        .opacity(0.3)
      Canvas { context, size in
        let scale = size.width / CANVAS_SIZE
        let style = StrokeStyle(lineWidth: max(DRAWING_LINE_WIDTH * scale, 1.5), lineCap: .round, lineJoin: .round)
        for stroke in AUTO_TRACE_DEMO_STROKES {
          let pts = stroke.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
          guard let first = pts.first else { continue }
          var path = Path()
          path.move(to: first)
          for point in pts.dropFirst() { path.addLine(to: point) }
          context.stroke(path, with: .color(.appAccent), style: style)
        }
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .frame(width: 280, height: 280)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

#Preview("Watermark demo · wiggly share card") {
  ZStack {
    Color.black.ignoresSafeArea()
    WatermarkFreeDemo(isActive: true)
      .frame(width: 320, height: 300)
      .padding(24)
  }
}
