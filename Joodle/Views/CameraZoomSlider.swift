//
//  CameraZoomSlider.swift
//  Joodle
//

import SwiftUI
import UIKit

/// Pure geometry for the temporary edge-drag zoom reveal (JOO-147): maps how far
/// the finger has dragged inward from a screen edge into a 0…1 "reveal" fraction,
/// and decides whether a released drag has come out far enough to stay put.
///
/// Deliberately free of any view state so the interaction math can be unit-tested
/// without driving the SwiftUI layer.
enum EdgeDragReveal {
  /// Fraction (0…1) the control has emerged from the edge for a given inward drag
  /// distance. `inwardTranslation` is positive toward screen center; a negative
  /// value (dragging back out past the edge) or a non-positive `pullDistance`
  /// clamps to 0, and anything past `pullDistance` clamps to 1.
  static func revealFraction(inwardTranslation: CGFloat, pullDistance: CGFloat) -> CGFloat {
    guard pullDistance > 0 else { return 0 }
    return min(max(inwardTranslation / pullDistance, 0), 1)
  }

  /// Whether a released drag has revealed the control far enough to commit (stay
  /// out) rather than retract back into the edge.
  static func shouldCommit(reveal: CGFloat, threshold: CGFloat = 0.5) -> Bool {
    reveal >= threshold
  }
}

/// Bridges a `UIScreenEdgePanGestureRecognizer` into SwiftUI so an inward drag
/// starting at a specific screen edge is reliably recognized (JOO-147). A pure
/// SwiftUI `DragGesture` on an edge strip loses the extreme-edge touch-down to
/// the system's own screen-edge pan, so the ruler never emerges; the dedicated
/// recognizer is the platform's own tool for exactly this and claims the touch.
///
/// `onChanged` reports the inward translation in points (clamped ≥ 0, positive
/// toward screen center); `onEnded` fires once on release/cancel with the final
/// inward translation.
struct ScreenEdgePanCatcher: UIViewRepresentable {
  let edge: HorizontalEdge
  let onChanged: (CGFloat) -> Void
  let onEnded: (CGFloat) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(edge: edge, onChanged: onChanged, onEnded: onEnded)
  }

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .clear
    let recognizer = UIScreenEdgePanGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handlePan(_:))
    )
    recognizer.edges = edge == .leading ? .left : .right
    view.addGestureRecognizer(recognizer)
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    // Keep the coordinator's captured closures/edge current across re-renders so
    // the callbacks always mutate the latest SwiftUI state.
    context.coordinator.edge = edge
    context.coordinator.onChanged = onChanged
    context.coordinator.onEnded = onEnded
    for recognizer in uiView.gestureRecognizers ?? [] {
      if let edgeRecognizer = recognizer as? UIScreenEdgePanGestureRecognizer {
        edgeRecognizer.edges = edge == .leading ? .left : .right
      }
    }
  }

  final class Coordinator: NSObject {
    var edge: HorizontalEdge
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void

    init(
      edge: HorizontalEdge,
      onChanged: @escaping (CGFloat) -> Void,
      onEnded: @escaping (CGFloat) -> Void
    ) {
      self.edge = edge
      self.onChanged = onChanged
      self.onEnded = onEnded
    }

    @objc func handlePan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
      guard let view = recognizer.view else { return }
      let translationX = recognizer.translation(in: view).x
      // Inward is toward screen center: rightward for a left edge, leftward for
      // a right edge. Clamp so dragging back past the edge never goes negative.
      let inward = edge == .leading ? translationX : -translationX
      let clamped = max(inward, 0)
      switch recognizer.state {
      case .began, .changed:
        onChanged(clamped)
      case .ended, .cancelled, .failed:
        onEnded(clamped)
      default:
        break
      }
    }
  }
}

/// A screen-edge camera zoom ruler, modelled on the native iOS Camera fine-zoom
/// control. The value label stays pinned at the vertical center while the tick
/// ruler scrolls beneath it; ticks toward the two ends progressively scale down
/// and blur, magnifying the focused tick at center. Major zoom levels (the
/// `keyFactors`) fire a haptic as they cross center.
///
/// Purely presentational: it renders the current `zoomFactor` and reports new
/// values through `onChange`. The only mutable state is the in-flight drag.
struct CameraZoomSlider: View {
  var zoomFactor: CGFloat
  var range: ClosedRange<CGFloat>
  var keyFactors: [CGFloat]
  /// Which screen edge the slider hugs — drives the corner morph and which side
  /// the value label sits on.
  var edge: HorizontalEdge
  var onChange: (CGFloat) -> Void

  private let containerWidth: CGFloat = 48
  /// Height of the slider tab. Static so an edge-drag reveal overlay (JOO-157)
  /// can size its grab band to the ruler's vertical band instead of the whole
  /// screen edge, and never drift out of sync with the ruler's real height.
  static let tabHeight: CGFloat = 275
  private var containerHeight: CGFloat { Self.tabHeight }
  /// Inset of the ruler's outer (edge-side) end from the container edge.
  private let outerInset: CGFloat = 10
  /// Width of the value label's pill. Kept just wide enough for "0.5x" so it
  /// hugs the screen edge without floating over the ruler.
  private let labelWidth: CGFloat = 40
  /// Vertical span of each ogee that sweeps the panel from its straight inner
  /// edge out to the screen edge. Taller = a longer, gentler S-curve.
  private let flareHeight: CGFloat = 64
  /// Points of travel per natural-log unit of zoom — sets how far apart the
  /// octaves (0.5→1→2) sit. Log spacing makes them evenly spaced.
  private let pointsPerLogUnit: CGFloat = 104
  /// Minor-tick interval in log space — eight ticks per octave.
  private let minorStepLog: CGFloat = 0.08664339 // ln(2) / 8
  /// Time constant of a tick's magnification decay after it leaves center. Larger
  /// is a longer, slower-fading trail.
  private let waveReleaseSeconds: CGFloat = 0.12

  /// Live zoom while dragging, in log space. `nil` when not dragging, so the
  /// ruler follows the externally driven `zoomFactor`.
  @State private var dragLog: CGFloat?
  /// Log-zoom captured at the start of a drag, so movement is relative.
  @State private var dragAnchorLog: CGFloat?
  /// Grid index of the tick currently at center — a change means a tick just
  /// crossed center, which is when a haptic fires (every tick, not just majors).
  @State private var lastTickIndex: Int = .min
  /// Per-tick magnification "charge": it attacks instantly to the spatial lens
  /// value as a tick reaches center, then releases slowly once center moves on —
  /// leaving a decaying scale/opacity trail behind the drag (the native Camera
  /// ruler's wavy feel). Held in a reference type so the per-frame `TimelineView`
  /// redraw can update it in place without invalidating the view.
  @State private var wave = WaveState()

  private var currentLog: CGFloat { dragLog ?? logZoom(zoomFactor) }
  private var currentZoom: CGFloat { clampZoom(exp(currentLog)) }

  /// The slider sits on an always-black background, so the theme accent is pinned
  /// to its dark-mode variant regardless of the system appearance.
  private static var darkAccent: Color {
    Color(UIColor(.appAccent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
  }

  var body: some View {
    ZStack {
      container
      ruler
        .clipShape(tabShape)
      valueLabel
    }
    .frame(width: containerWidth, height: containerHeight)
    .contentShape(tabShape)
    .gesture(dragGesture)
    .onAppear { lastTickIndex = tickIndex(for: currentLog) }
  }

  // MARK: - Container

  private var tabShape: EdgeMorphTab {
    EdgeMorphTab(edge: edge, flareHeight: flareHeight)
  }

  private var container: some View {
    // Pure, opaque black — no glass or translucency — flush against the screen
    // edge with concave corners morphing into it, with a hairline white outline.
    tabShape
      .fill(Color.black)
      .overlay(
        EdgeMorphTabOutline(edge: edge, flareHeight: flareHeight)
          .stroke(Color.white.opacity(0.2), lineWidth: 1)
      )
  }

  // MARK: - Value label

  private var valueLabel: some View {
    let value = Self.format(currentZoom)
    return Text(value)
      .font(.appFont(size: 13, weight: .bold))
      .monospacedDigit()
      .foregroundStyle(Self.darkAccent)
      // Roll the digits over as the displayed value changes, like the native
      // control. Keyed on the formatted string so it fires only at display-value
      // boundaries, not on every sub-step of the drag.
      .contentTransition(.numericText())
      .animation(.snappy(duration: 0.2), value: value)
      .frame(width: labelWidth, height: 24)
      // Opaque black pill (same as the container) masks the ticks directly
      // beneath the value, so the label reads cleanly over the ruler.
      .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .circular))
      .position(x: labelCenterX, y: containerHeight / 2)
  }

  /// Center of the value label — pinned hard against the screen edge (a couple
  /// points of breathing room) while still overlapping the ruler, so the value
  /// hugs the edge and masks the focused tick beneath it.
  private var labelCenterX: CGFloat {
    let edgeGap: CGFloat = 2
    switch edge {
    case .trailing: return containerWidth - edgeGap - labelWidth / 2
    case .leading: return edgeGap + labelWidth / 2
    }
  }

  // MARK: - Ruler

  /// The whole ruler is drawn in a single `Canvas` rather than ~30 individual
  /// views. This is the key to a smooth drag: there are no per-tick layers,
  /// `scaleEffect`s, or (the former bottleneck) per-tick blur passes — just one
  /// draw call per frame. The magnify is baked into each tick's drawn size and
  /// the end-softness into its alpha, so both are free.
  private var ruler: some View {
    // A continuous clock so each tick's charge keeps decaying between (and after)
    // drag events, not only when the value changes — that's what lets the trail
    // ease back on its own once the finger stops.
    TimelineView(.animation) { timeline in
      Canvas(opaque: false, rendersAsynchronously: false) { context, size in
        let now = timeline.date.timeIntervalSinceReferenceDate
        let dt = CGFloat(wave.lastTime.map { now - $0 } ?? 0)
        wave.lastTime = now
        // Fraction of charge retained this frame. dt == 0 (first frame) keeps all.
        let release = dt > 0 ? exp(-dt / waveReleaseSeconds) : 1

        let centerY = size.height / 2
        let cur = currentLog
        let tickList = ticks
        // The tick nearest center is the focused one, drawn in the accent color.
        let focused = tickList.min { abs($0.log - cur) < abs($1.log - cur) }?.log ?? cur
        let accent = Self.darkAccent

        for tick in tickList {
          let y = centerY - (tick.log - cur) * pointsPerLogUnit
          let n = min(abs(y - centerY) / (size.height / 2), 1)
          // Gaussian "lens" target centered on the focused tick. The charge snaps
          // up to it the instant a tick reaches center (attack) but only eases
          // back down by `release` per frame — so a tick swayed past center holds
          // a magnified, brighter trail that decays toward rest. At rest the
          // charge settles to the target, so the static look is the plain lens.
          let target = exp(-pow(n / 0.32, 2))
          let charge = max(target, (wave.charge[tick.log] ?? target) * release)
          wave.charge[tick.log] = charge
          // Length snaps to full only for the tick actually at center — no gradual
          // growth on approach — then releases on the same decay as it moves off.
          let lengthTarget: CGFloat = abs(tick.log - focused) < 0.0001 ? 1 : 0
          let lengthCharge = max(lengthTarget, (wave.lengthCharge[tick.log] ?? lengthTarget) * release)
          wave.lengthCharge[tick.log] = lengthCharge
          // Cull drawing only — charges above are still updated so off-screen ticks
          // decay instead of freezing and popping when they scroll back in.
          guard y >= -16, y <= size.height + 16 else { continue }

          // Thickness still magnifies at center; length does not — it is driven
          // purely by the charge sweep below.
          let thicknessScale = 1 + 1 * charge - 0.30 * pow(n, 1.4)
          let baseLength: CGFloat
          let restOpacity: CGFloat
          switch tick.tier {
          case .major:  baseLength = 24; restOpacity = 0.3
          case .medium: baseLength = 12; restOpacity = 0.3
          case .minor:  baseLength = 6;  restOpacity = 0.3
          }
          // A tick snaps to the longest height the instant it reaches center
          // (regardless of tier), then eases back to its own length as the length
          // charge releases — so the full-length tick trails the drag.
          let longestLength: CGFloat = 24
          let length = baseLength + (longestLength - baseLength) * lengthCharge
          let thickness = 1.8 * max(thicknessScale, 0.4)
          let originX: CGFloat = edge == .trailing ? size.width - outerInset - length : outerInset
          let rect = CGRect(x: originX, y: y - thickness / 2, width: length, height: thickness)

          let isFocused = abs(tick.log - focused) < 0.0001
          // Charge lifts opacity toward full, so a passing tick brightens and then
          // fades back to its tier's resting opacity.
          let litOpacity = restOpacity + (1 - restOpacity) * charge
          let base = isFocused ? accent : Color.white
          context.fill(Capsule().path(in: rect), with: .color(base.opacity(litOpacity * distanceFade(n))))
        }
      }
    }
  }

  /// Opacity that eases progressively from full at the focused center to zero
  /// at the ruler ends, so ticks far from the highlight fade out smoothly.
  private func distanceFade(_ n: CGFloat) -> CGFloat {
    max(0, 1 - pow(n, 1.7))
  }

  /// Three tick lengths, mirroring the native Camera ruler: the optical lenses
  /// (`keyFactors`) are longest, whole-number digital-zoom stops are medium, and
  /// the in-between grid lines are shortest.
  private enum TickTier {
    case major   // optical lens factor (0.5/1/2) — longest
    case medium  // whole-number digital-zoom stop (3/4/…) — in between
    case minor   // in-between grid line — shortest
  }

  /// A single ruler tick, identified by its log position (unique on the ruler).
  private struct RulerTick: Identifiable {
    let log: CGFloat
    let tier: TickTier
    var id: CGFloat { log }
  }

  /// Mutable per-frame scratch for the magnification trail, keyed by tick log.
  /// A class (not `@State` value) so the `Canvas`/`TimelineView` redraw can update
  /// it during rendering without tripping SwiftUI's "modifying state" invalidation.
  private final class WaveState {
    var charge: [CGFloat: CGFloat] = [:]
    /// Length trail, kept separate because it snaps on at center (step attack)
    /// rather than easing up on approach like the magnification `charge`.
    var lengthCharge: [CGFloat: CGFloat] = [:]
    var lastTime: TimeInterval?
  }

  /// A single uniform grid of ticks in log space — guaranteeing even spacing.
  /// Each grid line is tiered by what it lands nearest: a `keyFactor` (major), a
  /// whole-number zoom (medium), or neither (minor). Tiering a subset of the grid
  /// (rather than adding extra ticks at the exact key/integer positions) keeps the
  /// minor rhythm even — the 0.5/1/2 octaves land exactly on the grid, and an
  /// off-grid stop like 3 snaps to its nearest line instead of crowding it.
  private var ticks: [RulerTick] {
    let lo = logZoom(range.lowerBound)
    let hi = logZoom(range.upperBound)
    guard hi > lo else { return [] }
    let keyLogs = keyFactors.map { logZoom($0) }
    let integerLogs = stride(from: ceil(range.lowerBound), through: range.upperBound, by: 1)
      .map { logZoom($0) }
    let steps = max(1, Int(((hi - lo) / minorStepLog).rounded()))

    return (0...steps).map { i in
      let value = lo + CGFloat(i) * minorStepLog
      func isNear(_ target: CGFloat) -> Bool { abs(target - value) <= minorStepLog * 0.5 }
      let tier: TickTier =
        keyLogs.contains(where: isNear) ? .major
        : integerLogs.contains(where: isNear) ? .medium
        : .minor
      return RulerTick(log: value, tier: tier)
    }
  }

  // MARK: - Drag

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let anchor = dragAnchorLog ?? logZoom(zoomFactor)
        if dragAnchorLog == nil { dragAnchorLog = anchor }
        // Direct manipulation: the ruler follows the finger. Higher zoom ticks sit
        // above center, so dragging down brings them to center (zoom in) and
        // dragging up brings the lower ones (zoom out).
        let newLog = clampLog(anchor + value.translation.height / pointsPerLogUnit)
        dragLog = newLog
        fireHapticOnTickCrossed(newLog)
        onChange(clampZoom(exp(newLog)))
      }
      .onEnded { _ in
        dragAnchorLog = nil
        dragLog = nil
      }
  }

  /// Grid index of the tick nearest `logValue` (0 at the range minimum).
  private func tickIndex(for logValue: CGFloat) -> Int {
    Int(((logValue - logZoom(range.lowerBound)) / minorStepLog).rounded())
  }

  /// Fires one tick (haptic + click) each time the centered tick changes —
  /// every tick, with a slightly stronger tap and lower tock on the major
  /// (key-factor) lines.
  private func fireHapticOnTickCrossed(_ logValue: CGFloat) {
    let index = tickIndex(for: logValue)
    guard index != lastTickIndex else { return }
    lastTickIndex = index
    let tickLog = logZoom(range.lowerBound) + CGFloat(index) * minorStepLog
    let isMajor = keyFactors.contains { abs(logZoom($0) - tickLog) <= minorStepLog * 0.5 }
    Haptic.playTick(major: isMajor)
  }

  // MARK: - Log-scale mapping

  private func logZoom(_ zoom: CGFloat) -> CGFloat { log(clampZoom(zoom)) }

  private func clampLog(_ value: CGFloat) -> CGFloat {
    min(max(value, log(range.lowerBound)), log(range.upperBound))
  }

  private func clampZoom(_ value: CGFloat) -> CGFloat {
    min(max(value, range.lowerBound), range.upperBound)
  }

  // MARK: - Formatting

  /// "1x", "0.5x", "2x", "1.4x" — drops a trailing .0, else one decimal.
  private static func format(_ zoom: CGFloat) -> String {
    let rounded = (zoom * 10).rounded() / 10
    if rounded == rounded.rounded() {
      return "\(Int(rounded))x"
    }
    return String(format: "%.1fx", rounded)
  }
}

/// The interactive zoom-slider used to demonstrate the handedness setting (in
/// onboarding and Settings > Interactions). Both edge sliders are always present:
/// the active one sits at its edge while the inactive one is parked just off the
/// opposite side. Flipping `edge` (inside `withAnimation`) slides them via offset —
/// the old side off its edge, the new side in from the other — which animates
/// reliably even inside a `List`/`Form` row, where a `.transition` would just fade.
/// Drags are local-only — no camera is involved, it just shows the feel.
struct HandednessSliderPreview: View {
  var edge: HorizontalEdge
  /// Where the slider sits vertically. Defaults to centered (Settings shows it in
  /// a fixed-height row); onboarding passes `.bottom` to match the real camera.
  var verticalAlignment: VerticalAlignment = .center
  /// Distance from the bottom when bottom-anchored — mirrors the camera's 80pt.
  var bottomInset: CGFloat = 0

  @State private var zoom: CGFloat = 1.0

  private var leadingAlignment: Alignment {
    Alignment(horizontal: .leading, vertical: verticalAlignment)
  }

  private var trailingAlignment: Alignment {
    Alignment(horizontal: .trailing, vertical: verticalAlignment)
  }

  var body: some View {
    GeometryReader { geo in
      ZStack {
        slider(side: .leading)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: leadingAlignment)
          .animation(exitFade, value: edge)
          .offset(x: edge == .leading ? 0 : -geo.size.width)
        slider(side: .trailing)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: trailingAlignment)
          .animation(exitFade, value: edge)
          .offset(x: edge == .trailing ? 0 : geo.size.width)
      }
      .padding(.bottom, bottomInset)
    }
    .clipped()
  }

  /// Each slider has only a short visible runway at its own edge before the
  /// `.clipped()` boundary; the rest of the travel is off-screen. Under the slow
  /// position ease the departing slider's visible window is the *start* of its
  /// travel (accelerating into the clip — the abrupt pop) while the arriving one's
  /// is the *end* (decelerating into place — already smooth). A fast opacity fade,
  /// scoped here so it runs quicker than the offset animation, dissolves the
  /// departing slider while it is still visible, yet completes long before the
  /// arriving slider crosses into view — so the exit softens without dimming the
  /// entrance.
  private var exitFade: Animation { .easeOut(duration: 0.4) }

  private func slider(side: HorizontalEdge) -> some View {
    CameraZoomSlider(
      zoomFactor: zoom,
      range: 0.5...10,
      keyFactors: [0.5, 1, 2],
      edge: side,
      onChange: { zoom = $0 }
    )
  }
}

/// A panel that hugs one screen edge: a straight inner edge that sweeps out to the
/// screen edge through a tall ogee (S-curve) at top and bottom, so the panel morphs
/// into the edge over one continuous smooth curve with no corners. The ogee is
/// vertical where it leaves the inner edge and vertical again where it meets the
/// screen edge, so both joins are tangent-smooth.
private struct EdgeMorphTab: Shape {
  var edge: HorizontalEdge
  var flareHeight: CGFloat

  func path(in rect: CGRect) -> Path {
    let w = rect.width
    let h = rect.height
    let ky = min(flareHeight, h / 2 - 1)   // vertical span of each ogee

    // Built for a trailing (right) edge: screen edge at x == w, inner edge at x == 0.
    var path = Path()
    path.move(to: CGPoint(x: 0, y: ky))
    EdgeMorphFlare.ogee(&path, from: CGPoint(x: 0, y: ky), to: CGPoint(x: w, y: 0))    // inner → edge
    path.addLine(to: CGPoint(x: w, y: h))                                              // flush along the edge
    EdgeMorphFlare.ogee(&path, from: CGPoint(x: w, y: h), to: CGPoint(x: 0, y: h - ky)) // edge → inner
    path.addLine(to: CGPoint(x: 0, y: ky))                                             // straight inner edge
    path.closeSubpath()

    if edge == .leading {
      // Mirror horizontally so the edge sits at x == 0.
      return path.applying(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
    }
    return path
  }
}

/// The ogee that morphs the panel into the screen edge. A single cubic Bézier with
/// vertical tangents at both ends — straight where it leaves the inner edge and
/// straight again where it meets the screen edge — so it reads as one flowing
/// S-curve. `handle` is the fraction of the vertical span each tangent runs:
/// larger keeps the ends straighter and sweeps harder through the middle.
private enum EdgeMorphFlare {
  static let handle: CGFloat = 0.62

  /// Connects an inner-edge point to a screen-edge point with vertical tangents at
  /// both ends. `from` must be the current path point.
  static func ogee(_ path: inout Path, from: CGPoint, to: CGPoint) {
    let l = abs(from.y - to.y) * handle
    let dir: CGFloat = to.y < from.y ? -1 : 1
    path.addCurve(
      to: to,
      control1: CGPoint(x: from.x, y: from.y + dir * l),
      control2: CGPoint(x: to.x, y: to.y - dir * l)
    )
  }
}

/// The visible outline of `EdgeMorphTab`: the same contour but left open so the
/// flush segment running along the screen edge is omitted — only the inner edge
/// and the two ogees get stroked, not the line against the edge.
private struct EdgeMorphTabOutline: Shape {
  var edge: HorizontalEdge
  var flareHeight: CGFloat

  func path(in rect: CGRect) -> Path {
    let w = rect.width
    let h = rect.height
    let ky = min(flareHeight, h / 2 - 1)

    // Traced from the bottom edge point around the inner contour to the top edge
    // point, so the (w, h) → (w, 0) edge segment is never drawn.
    var path = Path()
    path.move(to: CGPoint(x: w, y: h))
    EdgeMorphFlare.ogee(&path, from: CGPoint(x: w, y: h), to: CGPoint(x: 0, y: h - ky)) // edge → inner
    path.addLine(to: CGPoint(x: 0, y: ky))                                             // straight inner edge
    EdgeMorphFlare.ogee(&path, from: CGPoint(x: 0, y: ky), to: CGPoint(x: w, y: 0))    // inner → edge

    if edge == .leading {
      return path.applying(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
    }
    return path
  }
}

#Preview {
  struct PreviewHost: View {
    @State private var zoom: CGFloat = 1.0
    var body: some View {
      ZStack {
        LinearGradient(
          colors: [.gray, .black],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        HStack {
          CameraZoomSlider(
            zoomFactor: zoom,
            range: 0.5...10,
            keyFactors: [0.5, 1, 2],
            edge: .leading,
            onChange: { zoom = $0 }
          )
          Spacer()
          CameraZoomSlider(
            zoomFactor: zoom,
            range: 0.5...10,
            keyFactors: [0.5, 1, 2],
            edge: .trailing,
            onChange: { zoom = $0 }
          )
        }
      }
      .ignoresSafeArea()
    }
  }
  return PreviewHost()
}
