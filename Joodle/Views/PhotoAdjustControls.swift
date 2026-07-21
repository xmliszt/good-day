//
//  PhotoAdjustControls.swift
//  Joodle
//
//  Controls for positioning the captured tracing-reference photo:
//
//  • `PhotoTranslationPad` — a native-Camera-style 2-axis scrub pad. On touch a
//    focal point glides from the pad's center out to the finger while a glow
//    blooms in; grid dots magnify and brighten around it as the finger scrubs
//    (translating the photo when it has room to move), and on release the focal
//    point glides back to center while the glow fades out. The glow bleeds all
//    the way to the container's continuous rounded corners.
//
//  • `PhotoRotationBar` — a compact horizontal ruler pill tucked right below
//    the photo-zoom slider at the same handedness edge (Instagram/Apple-Photos
//    straighten-ruler style): black capsule, hairline outline, glowing accent
//    tick marks that scroll with the value. Scrubbing right rotates the photo
//    clockwise, left counterclockwise; the drag keeps tracking past the pill's
//    bounds, and each tick crossing fires the shared haptic + click.
//
//  Both are purely presentational — they render the current value and report
//  new ones through callbacks. Double-tapping resets (recenter / level).
//

import SwiftUI

// MARK: - Translation pad

struct PhotoTranslationPad: View {
  /// Current translation of the photo, in canvas points.
  var offset: CGSize
  /// Canvas-point translation that corresponds to full deflection to the pad
  /// edge. Larger = the same drag nudges the photo further. Zero disables all
  /// travel (the photo exactly covers the canvas).
  var translationRange: CGFloat
  var onOffsetChange: (CGSize) -> Void

  private static let padSide: CGFloat = 208
  private static let containerPadding: CGFloat = 14
  /// Full square footprint of the pad including its container padding — shared
  /// with `PhotoRotationBar` so it can size itself into the pocket between the
  /// pad's edge and the screen edge.
  static var containerSide: CGFloat { padSide + containerPadding * 2 }

  private let containerCornerRadius: CGFloat = 30
  /// Spacing of the dot lattice.
  private let dotSpacing: CGFloat = 20
  private let baseDotRadius: CGFloat = 1.5
  /// Extra radius a dot gains right under the focal point at full glow.
  private let magnifyRadius: CGFloat = 4.5
  /// Reach of the soft white glow halo around the focal point.
  private let glowRadius: CGFloat = 52
  /// Gaussian falloff (points) of the per-dot magnify/brighten influence.
  private let influenceSigma: CGFloat = 34
  /// Dead-band around each center line where the reported offset snaps to 0.
  private let centerSnap: CGFloat = 6
  /// Duration of the glow fade + focal glide on touch-down / release.
  private let glowFadeDuration: TimeInterval = 0.3

  /// True while a finger is down — the glow's target state.
  @State private var isTouching = false
  /// Latest finger position, clamped to the pad's travel box. The focal point
  /// glides from center to here on touch-down, tracks it during the drag, and
  /// glides back to center from it after release.
  @State private var touchPoint: CGPoint = CGPoint(
    x: PhotoTranslationPad.containerSide / 2, y: PhotoTranslationPad.containerSide / 2)
  /// Axis sign (-1/0/1) so a light tick fires once as the offset snaps onto a
  /// center line rather than every frame.
  @State private var lastAxisSign = (x: 0, y: 0)
  /// Timestamp of the last touch-down/up, anchoring the glow fade.
  @State private var glowChangedAt = Date.distantPast
  /// Glow strength captured at the last touch state change, so a release
  /// mid-fade reverses from the current strength without a jump.
  @State private var glowAtChange: CGFloat = 0
  /// Mounts the display-linked timeline only while the glow is actually
  /// fading; the pad renders on a paused schedule once settled.
  @State private var glowAnimating = false
  /// Invalidates a pending settle when a newer touch change supersedes it.
  @State private var glowSettleGeneration = 0
  /// End time of the last tap-like touch (barely any movement), so a second
  /// one in quick succession recenters. Detected manually in the drag's
  /// `onEnded` — a simultaneous `TapGesture(count: 2)` races the
  /// zero-distance drag's trailing events and can lose the reset.
  @State private var lastTapEndedAt: Date?

  private var containerSide: CGFloat { Self.containerSide }

  /// Maximum focal travel from center along either axis.
  private var padTravel: CGFloat { Self.padSide / 2 - 10 }

  /// Eased glow strength at `date`: rises toward 1 while touching, falls back
  /// to 0 after release, restarting from wherever the last fade left off.
  private func glowStrength(at date: Date) -> CGFloat {
    let target: CGFloat = isTouching ? 1 : 0
    let progress = min(max(date.timeIntervalSince(glowChangedAt) / glowFadeDuration, 0), 1)
    let eased = CGFloat(progress * progress * (3 - 2 * progress))
    return glowAtChange + (target - glowAtChange) * eased
  }

  /// Focal point at the given glow strength: the glow doubles as the glide
  /// parameter, so the focal point leaves center exactly as the glow blooms in
  /// and returns to center exactly as it fades out.
  private func focalPoint(glow: CGFloat) -> CGPoint {
    let center = containerSide / 2
    return CGPoint(
      x: center + (touchPoint.x - center) * glow,
      y: center + (touchPoint.y - center) * glow
    )
  }

  var body: some View {
    // One stable TimelineView whose schedule pauses at rest, rather than an
    // if/else swap between a timeline and a static Canvas: restructuring the
    // hierarchy on touch-down would cancel the in-flight drag gesture (the
    // release would never arrive and the glow would stick on). While paused,
    // the settled strength is used directly so the (stale) timeline date
    // never matters.
    TimelineView(.animation(minimumInterval: nil, paused: !glowAnimating)) { timeline in
      Canvas(opaque: false) { context, size in
        let glow = glowAnimating ? glowStrength(at: timeline.date) : (isTouching ? 1 : 0)
        drawPad(context, size: size, glow: glow)
      }
    }
    .frame(width: containerSide, height: containerSide)
    .background(
      RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
        .fill(Color.black)
    )
    // The glow halo bleeds past the dot lattice and is trimmed only by the
    // container's smooth continuous corners — never a sharp canvas edge.
    .clipShape(RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
        .stroke(Color.white.opacity(0.2), lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous))
    .gesture(padDrag)
  }

  /// Draw the halo + dot lattice at the given glow strength. At `glow == 0`
  /// the lattice is uniform and calm — no halo, no magnification, and no
  /// extra circle at the touch point.
  private func drawPad(_ context: GraphicsContext, size: CGSize, glow: CGFloat) {
    let focal = focalPoint(glow: glow)

    // Soft radial glow halo around the focal point, fading to clear at its edge.
    if glow > 0.01 {
      let glowRect = CGRect(
        x: focal.x - glowRadius, y: focal.y - glowRadius,
        width: glowRadius * 2, height: glowRadius * 2
      )
      context.fill(
        Circle().path(in: glowRect),
        with: .radialGradient(
          Gradient(colors: [Color.white.opacity(0.5 * glow), .clear]),
          center: focal,
          startRadius: 0,
          endRadius: glowRadius
        )
      )
    }

    // Dot lattice — each dot magnifies and brightens toward the focal point,
    // scaled by the glow strength.
    let cols = max(1, Int(size.width / dotSpacing))
    let rows = max(1, Int(size.height / dotSpacing))
    let startX = (size.width - CGFloat(cols - 1) * dotSpacing) / 2
    let startY = (size.height - CGFloat(rows - 1) * dotSpacing) / 2
    for i in 0..<cols {
      for j in 0..<rows {
        let p = CGPoint(x: startX + CGFloat(i) * dotSpacing, y: startY + CGFloat(j) * dotSpacing)
        let d = hypot(p.x - focal.x, p.y - focal.y)
        let influence = exp(-pow(d / influenceSigma, 2)) * glow
        let r = baseDotRadius + magnifyRadius * influence
        let op = 0.22 + 0.78 * influence
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        context.fill(Circle().path(in: rect), with: .color(.white.opacity(op)))
      }
    }
  }

  /// Flips the glow's target state and re-anchors the fade so it eases from
  /// the current strength, then schedules the timeline to unmount once the
  /// fade completes.
  private func setTouching(_ touching: Bool) {
    guard touching != isTouching else { return }
    let now = Date()
    glowAtChange = glowStrength(at: now)
    glowChangedAt = now
    isTouching = touching
    glowAnimating = true
    glowSettleGeneration += 1
    let generation = glowSettleGeneration
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64((glowFadeDuration + 0.05) * 1_000_000_000))
      guard generation == glowSettleGeneration else { return }
      glowAnimating = false
    }
  }

  private var padDrag: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let center = containerSide / 2
        let clampedDx = min(max(value.location.x - center, -padTravel), padTravel)
        let clampedDy = min(max(value.location.y - center, -padTravel), padTravel)
        touchPoint = CGPoint(x: center + clampedDx, y: center + clampedDy)

        let firstTouch = !isTouching
        if firstTouch {
          setTouching(true)
          Haptic.play(with: .medium)
        }

        var dx = clampedDx
        var dy = clampedDy
        if abs(dx) < centerSnap { dx = 0 }
        if abs(dy) < centerSnap { dy = 0 }

        let sx = dx == 0 ? 0 : (dx > 0 ? 1 : -1)
        let sy = dy == 0 ? 0 : (dy > 0 ? 1 : -1)
        if sx != lastAxisSign.x || sy != lastAxisSign.y {
          if sx == 0 || sy == 0 { Haptic.play(with: .light) }
          lastAxisSign = (sx, sy)
        }

        let newOffset = CGSize(
          width: dx / padTravel * translationRange,
          height: dy / padTravel * translationRange
        )
        if firstTouch {
          // The photo glides to the tapped position in step with the focal
          // point's center → touch glide, instead of jumping there.
          withAnimation(.easeOut(duration: glowFadeDuration)) {
            onOffsetChange(newOffset)
          }
        } else {
          onOffsetChange(newOffset)
        }
      }
      .onEnded { value in
        setTouching(false)
        // Manual double-tap detection: two barely-moved touches in quick
        // succession recenter the photo.
        let isTap = hypot(value.translation.width, value.translation.height) < 10
        if isTap, let last = lastTapEndedAt, Date().timeIntervalSince(last) < 0.35 {
          lastTapEndedAt = nil
          Haptic.play(with: .light)
          lastAxisSign = (0, 0)
          withAnimation(.easeOut(duration: glowFadeDuration)) {
            onOffsetChange(.zero)
          }
        } else {
          lastTapEndedAt = isTap ? Date() : nil
        }
      }
  }
}

// MARK: - Rotation bar

/// A compact horizontal straighten-ruler pill (Instagram / Apple Photos
/// style): a black capsule with a hairline outline and glowing theme-accent
/// tick marks that scroll with the rotation. Scrubbing right rotates the
/// photo clockwise, left counterclockwise; the ruler follows the finger and
/// the drag keeps tracking once it leaves the pill, so the compact window
/// still scrubs an unbounded range. Each tick crossing fires the shared
/// haptic + click; double-tapping levels back to 0°.
struct PhotoRotationBar: View {
  /// Current photo rotation (unbounded — scrubbing continues indefinitely).
  var rotation: Angle
  var onRotationChange: (Angle) -> Void

  private let barHeight: CGFloat = 40
  /// Horizontal points per degree of rotation — sets tick spacing.
  private let pointsPerDegree: CGFloat = 4
  /// Tick every this many degrees.
  private let tickStepDegrees: Double = 2
  /// Longer, brighter tick every this many degrees.
  private let majorStepDegrees: Double = 10
  private let minorTickLength: CGFloat = 10
  private let majorTickLength: CGFloat = 16

  /// Rotation (deg) captured at drag start, so movement is relative.
  @State private var dragAnchorDegrees: Double?
  /// Last tick index crossed, so a tick fires once per crossing.
  @State private var lastTickIndex: Int = .min
  /// End time of the last tap-like touch, for the manual double-tap-to-level
  /// detection (same rationale as the pad: a simultaneous `TapGesture` races
  /// the zero-distance drag's trailing events and can lose the reset).
  @State private var lastTapEndedAt: Date?

  private static var darkAccent: Color {
    Color(UIColor(.appAccent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
  }

  /// Pill width — sized into the pocket between the translation pad's edge and
  /// the screen edge so the two never collide, with a usable floor (the drag
  /// keeps tracking past the pill anyway).
  private var barWidth: CGFloat {
    let pocket = (UIScreen.main.bounds.width - PhotoTranslationPad.containerSide) / 2 - 14
    return max(56, min(84, pocket))
  }

  var body: some View {
    Canvas(opaque: false) { context, size in
      drawRuler(context, size: size)
    }
    .frame(width: barWidth, height: barHeight)
    .background(Capsule(style: .continuous).fill(Color.black))
    .clipShape(Capsule(style: .continuous))
    .overlay(
      Capsule(style: .continuous)
        .stroke(Color.white.opacity(0.2), lineWidth: 1)
    )
    .contentShape(Capsule(style: .continuous))
    .gesture(barDrag)
  }

  private func drawRuler(_ context: GraphicsContext, size: CGSize) {
    let mid = size.width / 2
    let midY = size.height / 2
    let accent = Self.darkAccent
    let rot = rotation.degrees

    // Values visible in the pill window. Ruler follows the finger: the tick
    // for value v sits at mid + (rot − v)·ppd, so dragging right (rot rising,
    // clockwise) sweeps the ticks rightward with the finger.
    let halfSpanDegrees = Double(mid / pointsPerDegree)
    let firstTick = Int(((rot - halfSpanDegrees) / tickStepDegrees).rounded(.down))
    let lastTick = Int(((rot + halfSpanDegrees) / tickStepDegrees).rounded(.up))
    let majorEvery = Int((majorStepDegrees / tickStepDegrees).rounded())
    guard lastTick >= firstTick else { return }

    // One layer with a shadow filter so every tick glows in the accent color.
    context.drawLayer { layer in
      layer.addFilter(.shadow(color: accent.opacity(0.9), radius: 3))
      for t in firstTick...lastTick {
        let value = Double(t) * tickStepDegrees
        let x = mid + CGFloat(rot - value) * pointsPerDegree
        // Fade ticks toward the pill's ends for the soft-edge ruler feel.
        let fade = max(0, 1 - pow(abs(x - mid) / mid, 1.7))
        if fade <= 0.02 { continue }
        let isMajor = t % majorEvery == 0
        let length = isMajor ? majorTickLength : minorTickLength
        var tick = Path()
        tick.move(to: CGPoint(x: x, y: midY - length / 2))
        tick.addLine(to: CGPoint(x: x, y: midY + length / 2))
        layer.stroke(
          tick,
          with: .color(accent.opacity((isMajor ? 0.9 : 0.5) * fade)),
          style: StrokeStyle(lineWidth: isMajor ? 2 : 1.3, lineCap: .round)
        )
      }
    }
  }

  private var barDrag: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let anchor = dragAnchorDegrees ?? rotation.degrees
        if dragAnchorDegrees == nil { dragAnchorDegrees = anchor }
        // Swipe right → clockwise (positive degrees), swipe left →
        // counterclockwise; the ruler ticks sweep along with the finger.
        let newDegrees = anchor + Double(value.translation.width) / Double(pointsPerDegree)

        let index = Int((newDegrees / tickStepDegrees).rounded())
        if index != lastTickIndex {
          lastTickIndex = index
          let major = index % Int((majorStepDegrees / tickStepDegrees).rounded()) == 0
          Haptic.playTick(major: major)
        }

        onRotationChange(.degrees(newDegrees))
      }
      .onEnded { value in
        dragAnchorDegrees = nil
        // Manual double-tap detection: two barely-moved touches in quick
        // succession level the photo back to 0°.
        let isTap = hypot(value.translation.width, value.translation.height) < 10
        if isTap, let last = lastTapEndedAt, Date().timeIntervalSince(last) < 0.35 {
          lastTapEndedAt = nil
          Haptic.playTick(major: true)
          lastTickIndex = 0
          withAnimation(.easeOut(duration: 0.3)) {
            onRotationChange(.zero)
          }
        } else {
          lastTapEndedAt = isTap ? Date() : nil
        }
      }
  }
}

// MARK: - Previews

#Preview("Translation pad") {
  struct Host: View {
    @State private var offset: CGSize = .zero
    var body: some View {
      ZStack {
        LinearGradient(colors: [.gray, .black], startPoint: .top, endPoint: .bottom)
        PhotoTranslationPad(offset: offset, translationRange: 205, onOffsetChange: { offset = $0 })
      }
      .ignoresSafeArea()
    }
  }
  return Host()
}

#Preview("Rotation bar") {
  struct Host: View {
    @State private var rotation: Angle = .zero
    var body: some View {
      ZStack {
        Color.black
        VStack(spacing: 24) {
          Text(String(format: "%.0f°", rotation.degrees))
            .foregroundStyle(.white)
          PhotoRotationBar(
            rotation: rotation,
            onRotationChange: { rotation = $0 }
          )
        }
      }
      .ignoresSafeArea()
    }
  }
  return Host()
}
