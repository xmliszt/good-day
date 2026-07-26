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
//  • `PhotoRotationDial` — a rotary dial bezel that wraps the translation pad
//    like the rotation ring on an old polaroid camera. It sits z-behind the pad;
//    only the band around the (shrunk) pad is exposed. Accent-lit creases run
//    around the band and scroll as the dial turns. Grab the ring and turn it —
//    the finger's angle around the center drives the photo's rotation (finger
//    clockwise → photo clockwise), unbounded across full turns; each crease
//    crossing fires the shared haptic + click, and double-tapping levels to 0°.
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

  // Shrunk from its solo size so the rotation dial's band has room to wrap the
  // pad's perimeter without growing the overall footprint much.
  private static let padSide: CGFloat = 160
  private static let containerPadding: CGFloat = 14
  /// Full square footprint of the pad including its container padding — shared
  /// with `PhotoRotationDial` so its band can wrap concentrically around the pad.
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

  /// Maps a (center-snapped) touch offset from the pad center to the photo's
  /// screen-space translation. The pad reads as the image itself, so the photo
  /// shifts *opposite* the touch: touching the top-left (negative dx/dy) slides
  /// the photo down-right (positive width/height) so the image's top-left comes
  /// into view. `padTravel` is the full-deflection distance; `range` the
  /// matching canvas-point travel at full deflection.
  static func translationOffset(
    touchDx dx: CGFloat, touchDy dy: CGFloat, padTravel: CGFloat, range: CGFloat
  ) -> CGSize {
    guard padTravel > 0 else { return .zero }
    return CGSize(width: -dx / padTravel * range, height: -dy / padTravel * range)
  }

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

        // The pad reads as the image itself: touching a point brings THAT part
        // of the photo into view (see `translationOffset` — the photo shifts
        // opposite the touch). `.offset` renders in screen space (applied after
        // the rotation), so a plain per-axis negation is all that's needed.
        let newOffset = Self.translationOffset(
          touchDx: dx, touchDy: dy, padTravel: padTravel, range: translationRange
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

// MARK: - Rotation dial

/// A rotary dial bezel that wraps the translation pad like the rotation ring on
/// an old polaroid camera. It renders a black plate sized to sit *behind* the
/// pad (`innerSide`) with a `bandWidth`-wide ring exposed all the way around;
/// uniform accent creases follow the rounded-rect band and scroll as the dial
/// turns, and an accent-filled indicator dot painted at the band's top center
/// rides the rotating surface — it travels along the band (right as the photo
/// turns clockwise) to show how far the dial has turned. Turning is angular: the
/// finger's angle around the center drives the rotation (finger clockwise →
/// photo clockwise), unbounded across full turns. Each crease crossing fires the
/// shared haptic + click; double-tapping the band levels the photo back to 0°.
struct PhotoRotationDial: View {
  /// Current photo rotation (unbounded — the dial can be spun any number of turns).
  var rotation: Angle
  var onRotationChange: (Angle) -> Void
  /// Side of the (square) translation-pad container this dial wraps.
  var innerSide: CGFloat
  /// Width of the exposed ring around the pad.
  var bandWidth: CGFloat = 30

  /// Corner radius of the pad container — the band's inner contour matches it so
  /// the ring reads as concentric with the pad.
  private let innerCornerRadius: CGFloat = 30
  /// Target spacing between creases along the band's mid contour (points).
  private let creaseSpacing: CGFloat = 13

  /// Finger angle (radians, atan2 in the view's y-down space) at the previous
  /// drag frame, so per-frame angular deltas accumulate into unbounded rotation.
  @State private var lastAngle: CGFloat?
  /// Rotation (deg) captured at drag start; the accumulated finger sweep adds to it.
  @State private var anchorDegrees: Double = 0
  /// Signed finger sweep (deg) since drag start.
  @State private var sweptDegrees: Double = 0
  /// Last crease index crossed, so a tick fires once per crossing.
  @State private var lastTickIndex: Int = .min
  /// End time of the last tap-like touch, for the manual double-tap-to-level
  /// detection (same rationale as the pad: a simultaneous `TapGesture` races the
  /// zero-distance drag's trailing events and can lose the reset).
  @State private var lastTapEndedAt: Date?

  private var outerSide: CGFloat { innerSide + bandWidth * 2 }
  private var outerCornerRadius: CGFloat { innerCornerRadius + bandWidth }

  private static var darkAccent: Color {
    Color(UIColor(.appAccent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
  }

  /// Number of creases around the band. Chosen so they tile the closed loop
  /// evenly and scroll exactly once per full turn — which also fixes the haptic
  /// cadence at `360 / creaseCount` degrees per crease.
  private var creaseCount: Int {
    let midSide = innerSide + bandWidth
    let midRadius = innerCornerRadius + bandWidth / 2
    let perimeter = RoundedRectOutline.perimeter(side: midSide, cornerRadius: midRadius)
    return max(4, Int((perimeter / creaseSpacing).rounded()))
  }

  var body: some View {
    Canvas(opaque: false) { context, size in
      drawDial(context, size: size)
    }
    .frame(width: outerSide, height: outerSide)
    .background(
      RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
        .fill(Color.black)
    )
    .clipShape(RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous))
    .gesture(dialDrag)
  }

  private func drawDial(_ context: GraphicsContext, size: CGSize) {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let midSide = innerSide + bandWidth
    let midRadius = innerCornerRadius + bandWidth / 2
    let outline = RoundedRectOutline(side: midSide, cornerRadius: midRadius, center: center)
    let perimeter = outline.perimeter
    let count = creaseCount
    let accent = Self.darkAccent

    // Faint groove where the band meets the pad, so the ring reads as a bezel
    // sunk behind the panel.
    let innerRect = CGRect(
      x: center.x - innerSide / 2, y: center.y - innerSide / 2,
      width: innerSide, height: innerSide
    )
    context.stroke(
      RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous).path(in: innerRect),
      with: .color(.white.opacity(0.06)),
      lineWidth: 1
    )

    // Creases: uniform short ticks sampled at even arc-length steps around the
    // band's mid contour, scrolling by the current rotation so the dial visibly
    // turns. Each is a segment across the band along the local outward normal.
    let scroll = CGFloat(rotation.degrees / 360) * perimeter
    context.drawLayer { layer in
      layer.addFilter(.shadow(color: accent.opacity(0.9), radius: 3))
      let reach = bandWidth * 0.24
      for k in 0..<count {
        let d = CGFloat(k) / CGFloat(count) * perimeter + scroll
        let sample = outline.sample(at: d)
        let p0 = CGPoint(
          x: sample.point.x - sample.normal.dx * reach,
          y: sample.point.y - sample.normal.dy * reach)
        let p1 = CGPoint(
          x: sample.point.x + sample.normal.dx * reach,
          y: sample.point.y + sample.normal.dy * reach)
        var crease = Path()
        crease.move(to: p0)
        crease.addLine(to: p1)
        layer.stroke(
          crease,
          with: .color(accent.opacity(0.6)),
          style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      }
    }

    // Rotation indicator — an accent-filled dot painted on the band at the top
    // center. It rides the rotating surface (same `scroll` as the creases), so
    // it travels along the band — right as the photo turns clockwise — and marks
    // how far the dial has turned. Top-center sits at arc-length `straightHalf`
    // from the outline's start (the top edge's left end).
    let topCenterDistance = midSide / 2 - midRadius
    let indicator = outline.sample(at: topCenterDistance + scroll)
    let dotRadius = bandWidth * 0.3
    let dotRect = CGRect(
      x: indicator.point.x - dotRadius, y: indicator.point.y - dotRadius,
      width: dotRadius * 2, height: dotRadius * 2)
    context.drawLayer { layer in
      layer.addFilter(.shadow(color: accent.opacity(0.9), radius: 5))
      layer.fill(Circle().path(in: dotRect), with: .color(accent))
    }
  }

  private var dialDrag: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let center = outerSide / 2
        let angle = atan2(value.location.y - center, value.location.x - center)
        if lastAngle == nil {
          lastAngle = angle
          anchorDegrees = rotation.degrees
          sweptDegrees = 0
        } else if let last = lastAngle {
          var delta = angle - last
          // Shortest-arc wrap so crossing the ±π seam doesn't jump a full turn.
          if delta > .pi { delta -= 2 * .pi }
          if delta < -.pi { delta += 2 * .pi }
          sweptDegrees += Double(delta) * 180 / .pi
          lastAngle = angle
        }
        let newDegrees = anchorDegrees + sweptDegrees

        // One click per crease crossing — creases scroll once per full turn, so
        // a crease passes the reference every 360/creaseCount degrees.
        let step = 360.0 / Double(creaseCount)
        let index = Int((newDegrees / step).rounded())
        if index != lastTickIndex {
          lastTickIndex = index
          Haptic.playTick(major: false)
        }

        onRotationChange(.degrees(newDegrees))
      }
      .onEnded { value in
        lastAngle = nil
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

// MARK: - Rounded-rect outline

/// Analytic arc-length parametrization of a centered *square* rounded-rect
/// outline, used to place the rotation dial's creases evenly around the band and
/// give each a correct outward unit normal. Walks clockwise from the top edge's
/// left end: top edge → TR corner → right edge → BR corner → bottom edge → BL
/// corner → left edge → TL corner.
private struct RoundedRectOutline {
  let center: CGPoint
  /// Half-length of each straight run (side/2 − cornerRadius).
  let straightHalf: CGFloat
  let cornerRadius: CGFloat
  /// Half the side length.
  let half: CGFloat

  init(side: CGFloat, cornerRadius: CGFloat, center: CGPoint) {
    self.center = center
    self.cornerRadius = cornerRadius
    self.half = side / 2
    self.straightHalf = side / 2 - cornerRadius
  }

  private var edgeLen: CGFloat { straightHalf * 2 }
  private var cornerLen: CGFloat { cornerRadius * .pi / 2 }
  var perimeter: CGFloat { edgeLen * 4 + cornerLen * 4 }

  static func perimeter(side: CGFloat, cornerRadius: CGFloat) -> CGFloat {
    let straightHalf = side / 2 - cornerRadius
    return straightHalf * 2 * 4 + cornerRadius * .pi / 2 * 4
  }

  struct Sample {
    let point: CGPoint
    let normal: CGVector
  }

  /// Point + outward unit normal at arc-length `rawD`, wrapped into the outline.
  func sample(at rawD: CGFloat) -> Sample {
    let p = perimeter
    var d = rawD.truncatingRemainder(dividingBy: p)
    if d < 0 { d += p }
    let e = edgeLen
    let c = cornerLen

    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: center.x + x, y: center.y + y)
    }

    // 1. Top edge
    if d < e {
      return Sample(point: pt(-straightHalf + d, -half), normal: CGVector(dx: 0, dy: -1))
    }
    d -= e
    // 2. Top-right corner (−90°→0°)
    if d < c {
      let phi = -CGFloat.pi / 2 + d / cornerRadius
      let n = CGVector(dx: cos(phi), dy: sin(phi))
      return Sample(
        point: pt(straightHalf + cornerRadius * n.dx, -straightHalf + cornerRadius * n.dy),
        normal: n)
    }
    d -= c
    // 3. Right edge
    if d < e {
      return Sample(point: pt(half, -straightHalf + d), normal: CGVector(dx: 1, dy: 0))
    }
    d -= e
    // 4. Bottom-right corner (0°→90°)
    if d < c {
      let phi = d / cornerRadius
      let n = CGVector(dx: cos(phi), dy: sin(phi))
      return Sample(
        point: pt(straightHalf + cornerRadius * n.dx, straightHalf + cornerRadius * n.dy),
        normal: n)
    }
    d -= c
    // 5. Bottom edge
    if d < e {
      return Sample(point: pt(straightHalf - d, half), normal: CGVector(dx: 0, dy: 1))
    }
    d -= e
    // 6. Bottom-left corner (90°→180°)
    if d < c {
      let phi = CGFloat.pi / 2 + d / cornerRadius
      let n = CGVector(dx: cos(phi), dy: sin(phi))
      return Sample(
        point: pt(-straightHalf + cornerRadius * n.dx, straightHalf + cornerRadius * n.dy),
        normal: n)
    }
    d -= c
    // 7. Left edge
    if d < e {
      return Sample(point: pt(-half, straightHalf - d), normal: CGVector(dx: -1, dy: 0))
    }
    d -= e
    // 8. Top-left corner (180°→270°)
    let phi = CGFloat.pi + d / cornerRadius
    let n = CGVector(dx: cos(phi), dy: sin(phi))
    return Sample(
      point: pt(-straightHalf + cornerRadius * n.dx, -straightHalf + cornerRadius * n.dy),
      normal: n)
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

#Preview("Rotation dial") {
  struct Host: View {
    @State private var rotation: Angle = .zero
    @State private var offset: CGSize = .zero
    var body: some View {
      ZStack {
        LinearGradient(colors: [.gray, .black], startPoint: .top, endPoint: .bottom)
        ZStack {
          PhotoRotationDial(
            rotation: rotation,
            onRotationChange: { rotation = $0 },
            innerSide: PhotoTranslationPad.containerSide
          )
          PhotoTranslationPad(
            offset: offset, translationRange: 160, onOffsetChange: { offset = $0 })
        }
      }
      .ignoresSafeArea()
    }
  }
  return Host()
}
