//
//  TraceControl.swift
//  Joodle
//
//  The auto-trace control: a slim plate that docks flush under the rotation
//  dial, completing the photo-adjust console.
//
//  Action and detail live in one component on purpose. Detail is a re-roll knob
//  — you cannot know which level you want until you have seen a result — so
//  splitting "trace" from "how much detail" into two controls would put the two
//  halves of a single decision in different places. Here, nudging the ruler *is*
//  asking for another trace.
//
//  Visually it belongs to the pad and dial rather than to the canvas's Liquid
//  Glass buttons: a black continuous-corner plate, hairline stroke, creases
//  drawn in `Canvas`, and the same accent bloom and per-crease haptic under a
//  moving finger.
//

import SwiftUI
import UIKit

struct TraceControl: View {
  /// Currently selected detail level.
  @Binding var detail: AutoTraceDetail
  /// True while a trace is running — the plate goes busy and stops taking input.
  var isTracing: Bool
  /// Fired on tap of the action cap, and on release of a ruler drag that landed
  /// on a different level.
  var onTrace: (AutoTraceDetail) -> Void

  /// Matches the rotation dial's outer edge so the console reads as one stack.
  static var width: CGFloat {
    PhotoTranslationPad.containerSide + PhotoRotationDial.defaultBandWidth * 2
  }
  static let height: CGFloat = 44
  /// Gap between the dial's bottom edge and this plate.
  static let dialSpacing: CGFloat = 8

  private let cornerRadius: CGFloat = 14
  /// Width of the leading action cap.
  private let capWidth: CGFloat = 62
  /// Diameter of the circular well the wand sits in, so the action reads as a
  /// button rather than a bare glyph floating on the plate.
  private let capButtonSide: CGFloat = 34
  /// Target spacing between minor creases along the ruler.
  private let creaseSpacing: CGFloat = 11

  @State private var glow = TouchGlow()
  @State private var touchX: CGFloat?
  /// Level the finger is currently over, so the ruler can track the drag before
  /// the trace is actually requested on release.
  @State private var draggingLevel: AutoTraceDetail?

  private static var darkAccent: Color {
    Color(UIColor(.appAccent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
  }

  private var shownLevel: AutoTraceDetail { draggingLevel ?? detail }

  var body: some View {
    HStack(spacing: 0) {
      actionCap
      Rectangle()
        .fill(Color.white.opacity(0.12))
        .frame(width: 1, height: Self.height - 18)
      ruler
    }
    .frame(width: Self.width, height: Self.height)
    .background(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Color.black)
    )
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("Auto-trace", comment: "Button that converts the reference photo into a doodle"))
    .accessibilityValue(Text(shownLevel.accessibilityName))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { requestTrace(detail) }
    .accessibilityAdjustableAction { direction in
      let next = direction == .increment ? detail.increased : detail.decreased
      guard next != detail else { return }
      detail = next
      requestTrace(next)
    }
  }

  // MARK: - Action cap

  private var actionCap: some View {
    ZStack {
      // The well. Faint fill plus a hairline ring — the same recipe as the
      // plate itself, one step brighter, so the action reads as raised out of
      // the console rather than printed on it.
      Circle()
        .fill(Color.white.opacity(0.07))
        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .frame(width: capButtonSide, height: capButtonSide)

      if isTracing {
        ProgressView()
          .progressViewStyle(.circular)
          .tint(Self.darkAccent)
          .scaleEffect(0.7)
      } else {
        // Accent, not white: this is the plate's one action, and the accent tie
        // to the live detent is what makes the two halves read as one control.
        Image(systemName: "wand.and.sparkles")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Self.darkAccent)
      }
    }
    .frame(width: capWidth, height: Self.height)
    .contentShape(Rectangle())
    .onTapGesture {
      guard !isTracing else { return }
      Haptic.play(with: .medium)
      requestTrace(detail)
    }
  }

  // MARK: - Detail ruler

  private var ruler: some View {
    GeometryReader { proxy in
      TimelineView(.animation(paused: !glow.animating)) { timeline in
        Canvas { context, size in
          draw(
            context: context,
            size: size,
            strength: glow.strength(at: timeline.date)
          )
        }
      }
      .contentShape(Rectangle())
      .gesture(rulerGesture(width: proxy.size.width))
      .opacity(isTracing ? 0.45 : 1)
      .allowsHitTesting(!isTracing)
    }
    .frame(height: Self.height)
  }

  private func rulerGesture(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        setGlow(true)
        touchX = value.location.x
        let level = level(atX: value.location.x, width: width)
        if level != shownLevel {
          Haptic.playTick(major: true)
        }
        draggingLevel = level
      }
      .onEnded { value in
        setGlow(false)
        touchX = nil
        let level = level(atX: value.location.x, width: width)
        draggingLevel = nil
        detail = level
        // Always re-trace on release, even at an unchanged level: the user may
        // have moved the photo since, and the tap-through case should feel like
        // pressing a button.
        requestTrace(level)
      }
  }

  /// Nearest detent to an x position, splitting the ruler into equal thirds.
  private func level(atX x: CGFloat, width: CGFloat) -> AutoTraceDetail {
    guard width > 0 else { return detail }
    let slot = Int(floor(x / (width / CGFloat(AutoTraceDetail.allCases.count))))
    let clamped = min(max(slot, 0), AutoTraceDetail.allCases.count - 1)
    return AutoTraceDetail(rawValue: clamped) ?? detail
  }

  /// Centre x of each detent, in ruler-local coordinates.
  private func detentX(_ level: AutoTraceDetail, width: CGFloat) -> CGFloat {
    let slotWidth = width / CGFloat(AutoTraceDetail.allCases.count)
    return slotWidth * (CGFloat(level.rawValue) + 0.5)
  }

  private func draw(context: GraphicsContext, size: CGSize, strength: CGFloat) {
    let midY = size.height / 2
    let accent = Self.darkAccent
    let detents = AutoTraceDetail.allCases.map { (level: $0, x: detentX($0, width: size.width)) }

    // Bloom first, so it sits behind every tick it touches.
    if let live = detents.first(where: { $0.level == shownLevel }) {
      let radius = 14 + 6 * strength
      let bloom = Path(
        ellipseIn: CGRect(
          x: live.x - radius, y: midY - radius, width: radius * 2, height: radius * 2))
      context.fill(bloom, with: .color(accent.opacity(0.12 + 0.14 * strength)))
    }

    // Minor creases — the ruler field. Skipped near a detent so the two never
    // collide into a smudge; the gap is what makes a detent read as a stop.
    let creaseCount = max(Int((size.width / creaseSpacing).rounded()), 1)
    let step = size.width / CGFloat(creaseCount)
    for i in 0...creaseCount {
      let x = step * CGFloat(i)
      guard detents.allSatisfy({ abs($0.x - x) > detentClearance }) else { continue }
      var path = Path()
      path.move(to: CGPoint(x: x, y: midY - 4.5))
      path.addLine(to: CGPoint(x: x, y: midY + 4.5))
      context.stroke(
        path, with: .color(.white.opacity(0.3)),
        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    // Detents. Height encodes the level — short, taller, tallest reads as
    // "more detail" without needing three words that would have to localize.
    for detent in detents {
      let isActive = detent.level == shownLevel
      let half = detentHalfHeight(detent.level)
      var path = Path()
      path.move(to: CGPoint(x: detent.x, y: midY - half))
      path.addLine(to: CGPoint(x: detent.x, y: midY + half))
      context.stroke(
        path,
        with: .color(isActive ? accent : .white.opacity(0.5)),
        style: StrokeStyle(lineWidth: isActive ? 3 : 2, lineCap: .round)
      )

      if isActive {
        // A dot under the live detent: the one unambiguous "you are here" mark,
        // readable even when the accent tick sits against a bright bloom.
        let dot = Path(
          ellipseIn: CGRect(x: detent.x - 2.5, y: size.height - 9, width: 5, height: 5))
        context.fill(dot, with: .color(accent))
      }
    }
  }

  /// How far a minor crease must stay clear of a detent.
  private var detentClearance: CGFloat { 9 }

  /// Half-height of a detent tick, ascending with the level.
  private func detentHalfHeight(_ level: AutoTraceDetail) -> CGFloat {
    switch level {
    case .simple: return 7
    case .balanced: return 9.5
    case .detailed: return 12
    }
  }

  // MARK: - Plumbing

  private func requestTrace(_ level: AutoTraceDetail) {
    guard !isTracing else { return }
    onTrace(level)
  }

  private func setGlow(_ on: Bool) {
    guard glow.setOn(on) else { return }
    let generation = glow.generation
    DispatchQueue.main.asyncAfter(deadline: .now() + glow.fadeDuration) {
      guard glow.generation == generation else { return }
      glow.settle()
    }
  }
}

extension AutoTraceDetail {
  /// Spoken name for the level. The visible control is glyph-only — three
  /// creases on a ruler — so these exist for VoiceOver rather than for layout.
  var accessibilityName: LocalizedStringKey {
    switch self {
    case .simple: return "Simple"
    case .balanced: return "Balanced"
    case .detailed: return "Detailed"
    }
  }
}

// MARK: - Previews

#Preview("Trace control") {
  struct Harness: View {
    @State private var detail: AutoTraceDetail = .balanced
    @State private var tracing = false
    var body: some View {
      VStack(spacing: 24) {
        TraceControl(detail: $detail, isTracing: false, onTrace: { _ in })
        TraceControl(detail: .constant(.simple), isTracing: false, onTrace: { _ in })
        TraceControl(detail: .constant(.detailed), isTracing: true, onTrace: { _ in })
      }
      .padding(40)
      .background(Color.gray.opacity(0.3))
    }
  }
  return Harness()
}
