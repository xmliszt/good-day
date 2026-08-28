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

  private let cornerRadius: CGFloat = 18
  /// Width of the leading action cap.
  private let capWidth: CGFloat = 68
  /// Target spacing between minor creases along the ruler.
  private let creaseSpacing: CGFloat = 13

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
      if isTracing {
        ProgressView()
          .progressViewStyle(.circular)
          .tint(Color.white.opacity(0.8))
          .scaleEffect(0.8)
      } else {
        Image(systemName: "wand.and.sparkles")
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(Color.white.opacity(0.9))
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

    // Minor creases — a plain ruler field, densest information, lowest contrast.
    let creaseCount = max(Int((size.width / creaseSpacing).rounded()), 1)
    let step = size.width / CGFloat(creaseCount)
    for i in 0...creaseCount {
      let x = step * CGFloat(i)
      var path = Path()
      path.move(to: CGPoint(x: x, y: midY - 4))
      path.addLine(to: CGPoint(x: x, y: midY + 4))
      context.stroke(path, with: .color(.white.opacity(0.16)), lineWidth: 1)
    }

    // Detents — the three levels, taller and brighter so they read as stops.
    for level in AutoTraceDetail.allCases {
      let x = detentX(level, width: size.width)
      let isActive = level == shownLevel
      var path = Path()
      path.move(to: CGPoint(x: x, y: midY - 9))
      path.addLine(to: CGPoint(x: x, y: midY + 9))
      context.stroke(
        path,
        with: .color(isActive ? accent : .white.opacity(0.42)),
        lineWidth: isActive ? 2 : 1
      )

      if isActive {
        // Accent bloom behind the live detent, swelling while a finger is down.
        let radius = 10 + 6 * strength
        let bloom = Path(
          ellipseIn: CGRect(
            x: x - radius, y: midY - radius, width: radius * 2, height: radius * 2))
        context.fill(bloom, with: .color(accent.opacity(0.10 + 0.16 * strength)))
      }
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
