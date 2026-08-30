//
//  AutoTraceButton.swift
//  Joodle
//
//  The standalone auto-trace control: a circular Liquid Glass button, sibling to
//  the canvas's other glass buttons (clear / undo / redo / confirm). A plain tap
//  traces the reference photo at the default detail; a long-press blooms a fan of
//  three detail levels you swipe through and release to pick.
//
//  The fan is three more glass circles that morph straight out of the source
//  button: on iOS 26 a shared `GlassEffectContainer` fuses them, so they stretch
//  apart like liquid and neck back together on collapse — the real thing, no
//  hand-drawn metaball. Older systems fall back to three circles that fade and
//  scale out of the source and back in.
//
//  The button rests in the bottom corner on the user's handedness side, so the
//  fan opens toward the screen interior — up-and-inward, away from the corner.
//  Dragging a press clear across to the opposite side flings the button to the
//  other corner (the host owns that position, so it can spring across).
//

import SwiftUI
import UIKit

struct AutoTraceButton: View {
  /// Which bottom corner the button rests in. The side also fixes the fan
  /// direction: it always opens toward the screen interior.
  enum Corner: Equatable {
    case bottomLeading
    case bottomTrailing

    var opposite: Corner { self == .bottomLeading ? .bottomTrailing : .bottomLeading }
    /// Horizontal sign of the fan direction: +1 opens rightward, −1 leftward.
    var fanSign: CGFloat { self == .bottomLeading ? 1 : -1 }
  }

  /// Resolved rest corner — the handedness side, or a transient relocation.
  var corner: Corner
  /// The in-session detail profile: what a plain tap traces at, and what the
  /// base glyph shows. Fanning out and picking a level overwrites it for the
  /// rest of the session (it is not written back to the user's setting).
  @Binding var activeDetail: AutoTraceDetail
  /// True while a trace runs — the button goes busy and stops taking input.
  var isTracing: Bool
  /// Fired on tap, and on release of a fan swipe that landed on a level.
  var onTrace: (AutoTraceDetail) -> Void
  /// Fired when a press drags across to the opposite side of the screen.
  var onRelocate: (Corner) -> Void
  /// Fired the instant a press begins — before the fan blooms — so a feature tip
  /// can clear itself out of the way of the buttons about to appear underneath.
  var onPressBegan: () -> Void = {}
  /// Fired when the press ends, pairing with `onPressBegan` so a feature tip can
  /// resolve the stage it hid and advance to the next.
  var onPressEnded: () -> Void = {}
  /// Available width, for sizing the "drag to the opposite side" threshold.
  var screenWidth: CGFloat

  // MARK: - Layout constants

  /// Diameter of the glass button — `circularGlassButton` renders 40pt of content
  /// plus 2pt of padding all round.
  private static let buttonDiameter: CGFloat = 44
  /// Distance from the button center to each fanned-out level.
  private static let fanRadius: CGFloat = 68
  /// Hold this long, without moving, to bloom the fan. Dragging out into the
  /// cone opens it sooner (see `fanTriggerDistance`).
  private static let longPressDelay: TimeInterval = 0.16
  /// A press that drags this far out into the fan cone opens the fan immediately.
  private static let fanTriggerDistance: CGFloat = 26
  /// The finger must be at least this far from center to light up any level, so a
  /// press that never travels releases onto nothing and dismisses.
  private static let minHighlightDistance: CGFloat = 26
  /// A sideways drag toward the opposite corner relocates once it passes
  /// `relocateFlickFraction` of the width *at speed*, or `relocateFarFraction`
  /// however slowly — kept well beyond the fan so picking the horizontal level
  /// never trips it.
  private static let relocateFlickFraction: CGFloat = 0.34
  private static let relocateFarFraction: CGFloat = 0.6
  /// Horizontal drag speed (pt/s) that counts as a decisive relocate flick.
  private static let relocateFlickVelocity: CGFloat = 800
  /// Container blend distance. Above the ~60pt edge-to-edge gap between the source
  /// and a fanned level, so the two morph into and out of one another.
  private static let glassBlendSpacing: CGFloat = 45
  /// Pop given to a pressed source button, and to the level under the finger, so
  /// the two read as the same "active" state.
  private static let pressedScale: CGFloat = 1.08

  /// Levels top-to-bottom in the fan: less detailed, normal, more detailed. The
  /// most vertical slot sits topmost; angles rake toward the interior as the
  /// level rises.
  private static let fanLevels: [AutoTraceDetail] = [.simple, .balanced, .detailed]
  private static let anglesFromVertical: [CGFloat] = [0, 45, 90]

  // MARK: - State

  private enum Phase {
    case idle
    /// Finger down, waiting to become a tap, a hold, or a relocation.
    case pressing
    /// Fan is out; the finger is choosing a level.
    case fanned
    /// The press dragged across to the opposite corner.
    case relocated
  }

  /// The app's real appearance (read before `body` forces the button's own glass
  /// to render dark). Drives the black glass tint below.
  @Environment(\.colorScheme) private var colorScheme

  @State private var phase: Phase = .idle
  /// Finger position relative to the button center.
  @State private var fingerOffset: CGPoint = .zero
  @State private var highlighted: AutoTraceDetail?
  @State private var longPressTask: Task<Void, Never>?
  @Namespace private var glassNamespace

  private var fanOpen: Bool { phase == .fanned }
  private var pressScale: CGFloat { phase == .pressing || phase == .fanned ? Self.pressedScale : 1 }

  private static var darkAccent: Color {
    Color(UIColor(.appAccent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
  }

  /// Black glass tint only in light appearance — it keeps the button dark over
  /// the light canvas. In dark appearance the plain (untinted) liquid glass
  /// already reads dark, so no tint is applied.
  private var glassBacking: Color? {
    colorScheme == .light ? .black : nil
  }

  // MARK: - Body

  var body: some View {
    fan
      // The button sits over the always-black floating-canvas chrome, so its
      // Liquid Glass must render its dark variant regardless of the app's
      // appearance (its tint is already the dark-resolved accent).
      .environment(\.colorScheme, .dark)
      .scaleEffect(pressScale)
      .gesture(pressGesture)
      .accessibilityElement()
      .accessibilityLabel(Text("Auto-trace", comment: "Button that converts the reference photo into a doodle"))
      .accessibilityValue(Text(activeDetail.accessibilityName))
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { onTrace(activeDetail) }
      .accessibilityAdjustableAction { direction in
        activeDetail = direction == .increment
          ? activeDetail.increased
          : activeDetail.decreased
        onTrace(activeDetail)
      }
  }

  @ViewBuilder
  private var fan: some View {
    if #available(iOS 26, *) {
      GlassEffectContainer(spacing: Self.glassBlendSpacing) {
        ZStack {
          if fanOpen {
            ForEach(Self.fanLevels) { level in
              levelButton(level)
                .glassEffectID("level-\(level.rawValue)", in: glassNamespace)
                .offset(offset(for: level))
            }
          }
          sourceButton
            .glassEffectID("source", in: glassNamespace)
        }
      }
    } else {
      // Pre-Liquid-Glass: the levels just fade and scale out of the source.
      ZStack {
        ForEach(Self.fanLevels) { level in
          if fanOpen {
            levelButton(level)
              .offset(offset(for: level))
              .transition(.scale(scale: 0.2).combined(with: .opacity))
          }
        }
        sourceButton
      }
    }
  }

  private var sourceButton: some View {
    // The base glyph is the active profile's own sparkle cluster, so the button
    // shows at a glance what a tap will trace at. While a trace runs it bounces
    // as its own busy indicator — avoiding a UIKit `ProgressView`, which the
    // pre-iOS 26 `drawingGroup()` in `circularGlassButton` can't rasterize
    // ("Unable to render flattened version of ...CircularUIKitProgressView").
    SparkleCluster(detail: activeDetail, busy: isTracing)
      .circularGlassButton(tintColor: Self.darkAccent, backgroundColor: glassBacking)
      .animation(.spring(response: 0.35, dampingFraction: 0.7), value: activeDetail)
  }

  private func levelButton(_ level: AutoTraceDetail) -> some View {
    SparkleCluster(detail: level)
      .circularGlassButton(tintColor: Self.darkAccent, backgroundColor: glassBacking)
      // The level under the finger pops exactly like the pressed source button —
      // same scale, from center so the glyph stays put as it grows.
      .scaleEffect(highlighted == level ? Self.pressedScale : 1, anchor: .center)
      .animation(.easeOut(duration: 0.12), value: highlighted)
  }

  // MARK: - Geometry

  /// Offset from the button center to a level's resting spot in the fan.
  private func offset(for level: AutoTraceDetail) -> CGSize {
    let index = Self.fanLevels.firstIndex(of: level) ?? 0
    let radians = Self.anglesFromVertical[index] * .pi / 180
    return CGSize(
      width: corner.fanSign * sin(radians) * Self.fanRadius,
      height: -cos(radians) * Self.fanRadius
    )
  }

  // MARK: - Gesture

  private var pressGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .onChanged { value in
        guard !isTracing else { return }

        if phase == .idle {
          highlighted = nil
          onPressBegan()
          withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            phase = .pressing
          }
          scheduleLongPress()
        }
        guard phase != .relocated else { return }

        trackFinger(value.location)

        // A decisive sideways flick toward the opposite corner relocates —
        // checked first and from any phase, so it can override an open fan.
        if shouldRelocate(value) {
          beginRelocate(corner.opposite)
          return
        }

        // Dragging out into the fan cone opens the fan early; a still hold opens
        // it on the long-press timer instead.
        if phase == .pressing,
           hypot(fingerOffset.x, fingerOffset.y) > Self.fanTriggerDistance,
           levelForFingerAngle() != nil {
          openFan()
        }

        if phase == .fanned {
          updateHighlight()
        }
      }
      .onEnded { value in
        longPressTask?.cancel()
        onPressEnded()
        let endedPhase = phase
        let landed = highlighted
        guard !isTracing else { collapse(); return }

        switch endedPhase {
        case .pressing:
          collapse()
          let moved = hypot(value.translation.width, value.translation.height)
          if moved < 12 {
            Haptic.play(with: .medium)
            onTrace(activeDetail)
          }
        case .fanned:
          if let landed {
            Haptic.play(with: .medium)
            // Landing on a level overwrites the in-session profile, so the base
            // glyph updates and later taps trace at this level too.
            activeDetail = landed
            // Fold the fan back into the source first, then kick off the trace —
            // the source stays put and carries on into its pending busy state.
            collapse()
            traceAfterCollapse(landed)
          } else {
            // Released without landing on a level: just dismiss.
            collapse()
          }
        case .idle, .relocated:
          collapse()
        }
      }
  }

  /// Duration of the fan-in used both by the collapse spring and the delay before
  /// a landed trace starts, so the source is settled before it goes busy.
  private static let collapseDuration: TimeInterval = 0.3

  private func collapse() {
    withAnimation(.spring(response: Self.collapseDuration, dampingFraction: 0.8)) {
      highlighted = nil
      phase = .idle
    }
  }

  private func traceAfterCollapse(_ level: AutoTraceDetail) {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(Self.collapseDuration * 1_000_000_000))
      onTrace(level)
    }
  }

  /// Whether this drag is a decisive relocate flick toward the opposite corner:
  /// mostly sideways, and either fast past the near threshold or slow past the
  /// far one. Both thresholds sit well beyond the fan, so dragging out to the
  /// horizontal level to pick it never trips relocation.
  private func shouldRelocate(_ value: DragGesture.Value) -> Bool {
    let dx = value.translation.width
    let toward: Corner = dx > 0 ? .bottomTrailing : .bottomLeading
    guard toward == corner.opposite else { return false }
    guard abs(dx) > abs(value.translation.height) * 1.2 else { return false }
    let fastAndFar = abs(value.velocity.width) > Self.relocateFlickVelocity
      && abs(dx) > screenWidth * Self.relocateFlickFraction
    let simplyFar = abs(dx) > screenWidth * Self.relocateFarFraction
    return fastAndFar || simplyFar
  }

  private func scheduleLongPress() {
    longPressTask?.cancel()
    longPressTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(Self.longPressDelay * 1_000_000_000))
      guard !Task.isCancelled, phase == .pressing else { return }
      openFan()
    }
  }

  /// Bloom the fan and reflect whatever the finger is already pointing at.
  private func openFan() {
    guard phase == .pressing else { return }
    longPressTask?.cancel()
    Haptic.play(with: .medium)
    withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
      phase = .fanned
    }
    updateHighlight()
  }

  private func trackFinger(_ location: CGPoint) {
    fingerOffset = CGPoint(
      x: location.x - Self.buttonDiameter / 2,
      y: location.y - Self.buttonDiameter / 2
    )
  }

  /// The level the finger's angle selects, splitting the 0°–90° cone (measured
  /// from straight up toward the interior) into equal thirds, with a little slack
  /// past each end. `nil` when the finger points outside the cone.
  private func levelForFingerAngle() -> AutoTraceDetail? {
    let up = -fingerOffset.y
    let interior = corner.fanSign * fingerOffset.x
    let degrees = atan2(interior, up) * 180 / .pi
    switch degrees {
    case (-15)..<30: return .simple
    case 30..<60: return .balanced
    case 60...105: return .detailed
    default: return nil
    }
  }

  private func updateHighlight() {
    let fromCenter = hypot(fingerOffset.x, fingerOffset.y)
    let candidate = fromCenter > Self.minHighlightDistance ? levelForFingerAngle() : nil
    guard candidate != highlighted else { return }
    highlighted = candidate
    if candidate != nil { Haptic.play(with: .light) }
  }

  private func beginRelocate(_ toward: Corner) {
    longPressTask?.cancel()
    highlighted = nil
    Haptic.play(with: .rigid)
    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      phase = .relocated
    }
    onRelocate(toward)
  }
}

// MARK: - Display corner radius

extension UIScreen {
  /// The device's physical display corner radius, for seating corner-hugging
  /// controls concentric with the rounded screen. Read from the undocumented
  /// `_displayCornerRadius` key (assembled at runtime to keep the literal out of
  /// the binary) with a conservative fallback for anything that doesn't answer.
  static var joodleDisplayCornerRadius: CGFloat {
    let fallback: CGFloat = 39
    let key = ["Radius", "Corner", "display", "_"].reversed().joined()
    guard let screen = UIApplication.shared.connectedScenes
      .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.screen })
      .first
    else { return fallback }
    return (screen.value(forKey: key) as? CGFloat) ?? fallback
  }
}

// MARK: - Sparkle cluster

/// The glyph shown for a fan level: a hand-composed cluster of plain `sparkle`
/// symbols whose count and size climb with detail — one for simple, two for
/// balanced, three for detailed. It stands in for `sparkle` → `sparkles.2` →
/// `sparkles` (the `.2` variant is iOS 26-only and won't render on the older
/// systems this control still supports). While `busy`, the whole cluster pulses
/// its opacity as a calm in-flight-trace indicator.
struct SparkleCluster: View {
  let detail: AutoTraceDetail
  /// When true, the cluster pulses its opacity to signal a running trace.
  var busy: Bool = false
  /// Extra scale applied to the largest (primary) sparkle only. At the small icon
  /// size of a Form row the full-size primary crowds the accent sparkles, so
  /// callers there pass a value below 1 to open the cluster up.
  var primaryScale: CGFloat = 1

  private struct Sparkle {
    let offset: CGSize
    let scale: CGFloat
  }

  /// Base point size each sparkle scales from — kept under the 40pt glass
  /// content frame so the accent sparkles clear the button edge.
  private static let baseSize: CGFloat = 16
  /// Opacity the cluster dips to at the bottom of the busy pulse.
  private static let busyDimOpacity: Double = 0.35

  private static func sparkles(for detail: AutoTraceDetail) -> [Sparkle] {
    switch detail {
    case .simple:
      return [Sparkle(offset: .zero, scale: 1.0)]
    case .balanced:
      return [
        Sparkle(offset: CGSize(width: -3, height: -2), scale: 1.0),
        Sparkle(offset: CGSize(width: 5, height: 5), scale: 0.55),
      ]
    case .detailed:
      return [
        Sparkle(offset: CGSize(width: -4, height: -3), scale: 1.0),
        Sparkle(offset: CGSize(width: 5, height: 3), scale: 0.6),
        Sparkle(offset: CGSize(width: 0, height: 6), scale: 0.42),
      ]
    }
  }

  /// Oscillates while `busy`, driving the opacity pulse.
  @State private var dimmed = false

  var body: some View {
    ZStack {
      ForEach(Array(Self.sparkles(for: detail).enumerated()), id: \.offset) { index, spec in
        Image(systemName: "sparkle")
          .font(.system(size: Self.baseSize))
          .scaleEffect(spec.scale * (index == 0 ? primaryScale : 1))
          .offset(x: spec.offset.width, y: spec.offset.height)
      }
    }
    .opacity(busy && dimmed ? Self.busyDimOpacity : 1)
    .animation(
      busy ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .easeOut(duration: 0.2),
      value: dimmed
    )
    .onChange(of: busy) { _, now in dimmed = now }
  }
}

// MARK: - Detail names

extension AutoTraceDetail {
  /// Spoken name for the level. The visible control is glyph-only, so these
  /// exist for VoiceOver rather than for layout.
  var accessibilityName: LocalizedStringKey {
    switch self {
    case .simple: return "Simple"
    case .balanced: return "Balanced"
    case .detailed: return "Detailed"
    }
  }
}

// MARK: - Previews

#Preview("Auto-trace button") {
  struct Harness: View {
    @State private var corner: AutoTraceButton.Corner = .bottomTrailing
    @State private var detail: AutoTraceDetail = .default
    var body: some View {
      GeometryReader { geo in
        let inset: CGFloat = 44
        let x = corner == .bottomTrailing ? geo.size.width - inset : inset
        AutoTraceButton(
          corner: corner,
          activeDetail: $detail,
          isTracing: false,
          onTrace: { _ in },
          onRelocate: { corner = $0 },
          screenWidth: geo.size.width
        )
        .position(x: x, y: geo.size.height - inset)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: corner)
      }
      .background(Color.black)
      .ignoresSafeArea()
    }
  }
  return Harness()
}
