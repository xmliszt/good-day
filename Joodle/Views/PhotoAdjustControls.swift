//
//  PhotoAdjustControls.swift
//  Joodle
//
//  Controls for positioning the captured tracing-reference photo:
//
//  • `PhotoTranslationPad` — a native-Camera-style 2-axis scrub pad. A grid of
//    dots magnifies and glows radially around the touch point while the finger
//    is held down (the effect eases in on touch and fades back out on release),
//    so dragging reads as directly nudging the photo left/right/up/down. The
//    glow bleeds all the way to the container's continuous rounded corners.
//
//  • `PhotoRotationDial` — a polaroid-camera-style dial wheel seated in a slot
//    cut into the canvas's bottom edge. Only the lower arc of the wheel is
//    exposed (the rest hides behind the canvas, which draws above it); accent
//    creases sweep past a fixed notch as the wheel is scrubbed, ticking
//    (haptic) per crease. `DialSlotCanvasShape` is the matching canvas
//    mask/border shape with the slot opening dented into its bottom edge.
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

  private let padSide: CGFloat = 208
  private let containerPadding: CGFloat = 14
  private let containerCornerRadius: CGFloat = 30
  /// Spacing of the dot lattice.
  private let dotSpacing: CGFloat = 20
  private let baseDotRadius: CGFloat = 1.5
  /// Extra radius a dot gains right under the cursor at full glow.
  private let magnifyRadius: CGFloat = 4.5
  /// Reach of the soft white glow halo around the cursor.
  private let glowRadius: CGFloat = 52
  /// Gaussian falloff (points) of the per-dot magnify/brighten influence.
  private let influenceSigma: CGFloat = 34
  /// Dead-band around each center line where the cursor snaps to 0.
  private let centerSnap: CGFloat = 6
  /// Duration of the glow's ease-in on touch-down / ease-out on release.
  private let glowFadeDuration: TimeInterval = 0.3

  /// True while a finger is down — the glow's target state.
  @State private var isTouching = false
  /// Axis sign (-1/0/1) so a light tick fires once as the cursor snaps onto a
  /// center line rather than every frame.
  @State private var lastAxisSign = (x: 0, y: 0)
  /// Timestamp of the last touch-down/up, anchoring the glow fade.
  @State private var glowChangedAt = Date.distantPast
  /// Glow strength captured at the last touch state change, so a release
  /// mid-fade reverses from the current strength without a jump.
  @State private var glowAtChange: CGFloat = 0
  /// Mounts the display-linked timeline only while the glow is actually
  /// fading; the pad renders as a static Canvas once settled.
  @State private var glowAnimating = false
  /// Invalidates a pending settle when a newer touch change supersedes it.
  @State private var glowSettleGeneration = 0

  private static var darkAccent: Color {
    Color(UIColor(.appAccent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
  }

  private var containerSide: CGFloat { padSide + containerPadding * 2 }

  /// Maximum cursor travel from center along either axis.
  private var padTravel: CGFloat { padSide / 2 - 10 }

  /// Cursor position in container coordinates (the pad is centered inside).
  private var cursor: CGPoint {
    let half = containerSide / 2
    let nx = min(max(offset.width / max(translationRange, 0.0001), -1), 1)
    let ny = min(max(offset.height / max(translationRange, 0.0001), -1), 1)
    return CGPoint(x: half + nx * padTravel, y: half + ny * padTravel)
  }

  /// Eased glow strength at `date`: rises toward 1 while touching, falls back
  /// to 0 after release, restarting from wherever the last fade left off.
  private func glowStrength(at date: Date) -> CGFloat {
    let target: CGFloat = isTouching ? 1 : 0
    let progress = min(max(date.timeIntervalSince(glowChangedAt) / glowFadeDuration, 0), 1)
    let eased = CGFloat(progress * progress * (3 - 2 * progress))
    return glowAtChange + (target - glowAtChange) * eased
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
    .simultaneousGesture(TapGesture(count: 2).onEnded {
      Haptic.play(with: .light)
      lastAxisSign = (0, 0)
      onOffsetChange(.zero)
    })
  }

  /// Draw the halo + dot lattice at the given glow strength. At `glow == 0`
  /// the lattice is uniform and calm — no halo, no magnification, and no
  /// extra circle at the touch point.
  private func drawPad(_ context: GraphicsContext, size: CGSize, glow: CGFloat) {
    let c = cursor

    // Soft radial glow halo around the cursor, fading to clear at its edge.
    if glow > 0.01 {
      let glowRect = CGRect(
        x: c.x - glowRadius, y: c.y - glowRadius,
        width: glowRadius * 2, height: glowRadius * 2
      )
      context.fill(
        Circle().path(in: glowRect),
        with: .radialGradient(
          Gradient(colors: [Color.white.opacity(0.5 * glow), .clear]),
          center: c,
          startRadius: 0,
          endRadius: glowRadius
        )
      )
    }

    // Dot lattice — each dot magnifies and brightens toward the cursor,
    // scaled by the glow strength.
    let cols = max(1, Int(size.width / dotSpacing))
    let rows = max(1, Int(size.height / dotSpacing))
    let startX = (size.width - CGFloat(cols - 1) * dotSpacing) / 2
    let startY = (size.height - CGFloat(rows - 1) * dotSpacing) / 2
    for i in 0..<cols {
      for j in 0..<rows {
        let p = CGPoint(x: startX + CGFloat(i) * dotSpacing, y: startY + CGFloat(j) * dotSpacing)
        let d = hypot(p.x - c.x, p.y - c.y)
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
        if !isTouching {
          setTouching(true)
          Haptic.play(with: .medium)
        }
        var dx = min(max(value.location.x - containerSide / 2, -padTravel), padTravel)
        var dy = min(max(value.location.y - containerSide / 2, -padTravel), padTravel)
        if abs(dx) < centerSnap { dx = 0 }
        if abs(dy) < centerSnap { dy = 0 }

        let sx = dx == 0 ? 0 : (dx > 0 ? 1 : -1)
        let sy = dy == 0 ? 0 : (dy > 0 ? 1 : -1)
        if sx != lastAxisSign.x || sy != lastAxisSign.y {
          if sx == 0 || sy == 0 { Haptic.play(with: .light) }
          lastAxisSign = (sx, sy)
        }

        onOffsetChange(CGSize(
          width: dx / padTravel * translationRange,
          height: dy / padTravel * translationRange
        ))
      }
      .onEnded { _ in setTouching(false) }
  }
}

// MARK: - Rotation dial

/// Shared geometry between the dial wheel and the slot dented into the canvas
/// mask, so the two always stay physically consistent.
fileprivate enum PhotoDialMetrics {
  /// Radius of the dial wheel.
  static let radius: CGFloat = 60
  /// How far the wheel's center sits above the canvas's bottom edge, so the
  /// exposed part is a less-than-half arc rather than a full half circle.
  static let centerLift: CGFloat = 18
  /// Clearance between the wheel and the slot opening cut into the canvas.
  static let slotGap: CGFloat = 3
  /// Depth of the slot opening dented up into the canvas's bottom edge.
  static let dentDepth: CGFloat = 12
  /// Padding around the disc inside its drawing canvas so the crease glow
  /// isn't clipped at the drawing bounds.
  static let glowPadding: CGFloat = 10
  /// Height of the wheel arc that pokes out below the canvas's bottom edge.
  static var exposedHeight: CGFloat { radius - centerLift }
  /// Square side of the dial's drawing canvas (full disc + glow padding).
  static var canvasSide: CGFloat { (radius + glowPadding) * 2 }
  /// Layout height the dial occupies below the canvas (exposed arc + glow room).
  static var slotHeight: CGFloat { exposedHeight + glowPadding }
}

/// The drawing canvas's mask/border shape: a continuous rounded rectangle
/// with a shallow slot opening dented into its bottom-center edge — the
/// opening `PhotoRotationDial` is seated in. `dentProgress` 0 is a plain
/// rounded rectangle (used everywhere the dial isn't showing) and animates
/// the slot open/closed alongside the photo-adjust controls.
struct DialSlotCanvasShape: InsettableShape {
  var cornerRadius: CGFloat
  var dentProgress: CGFloat = 0
  var insetAmount: CGFloat = 0

  var animatableData: CGFloat {
    get { dentProgress }
    set { dentProgress = newValue }
  }

  func inset(by amount: CGFloat) -> DialSlotCanvasShape {
    var shape = self
    shape.insetAmount += amount
    return shape
  }

  func path(in rect: CGRect) -> Path {
    let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
    let base = Path(
      roundedRect: r,
      cornerRadius: max(cornerRadius - insetAmount, 0),
      style: .continuous
    )
    let depth = PhotoDialMetrics.dentDepth * min(max(dentProgress, 0), 1)
    guard depth > 0.05 else { return base }
    // The slot: the wheel's circle (grown by the slot gap) intersected with a
    // shallow strip along the bottom edge, subtracted from the rounded rect.
    let slotRadius = PhotoDialMetrics.radius + PhotoDialMetrics.slotGap
    let dialCenter = CGPoint(x: r.midX, y: r.maxY - PhotoDialMetrics.centerLift)
    let circle = Path(ellipseIn: CGRect(
      x: dialCenter.x - slotRadius,
      y: dialCenter.y - slotRadius,
      width: slotRadius * 2,
      height: slotRadius * 2
    ))
    let strip = Path(CGRect(
      x: dialCenter.x - slotRadius,
      y: r.maxY - depth,
      width: slotRadius * 2,
      height: depth + 1
    ))
    return base.subtracting(circle.intersection(strip))
  }
}

/// Polaroid-camera-style rotation dial. Draws the full wheel; the layout slot
/// it occupies is only the exposed lower arc, and the parent places it with a
/// z-index beneath the canvas so the rest of the wheel hides behind it. The
/// accent creases rotate with the value past a fixed accent notch at the
/// bottom apex, glowing against the dark chrome.
struct PhotoRotationDial: View {
  /// Current photo rotation (unbounded — scrubbing continues indefinitely).
  var rotation: Angle
  var onRotationChange: (Angle) -> Void

  /// Crease every this many degrees of rotation.
  private let tickStepDegrees: Double = 6
  /// Longer, brighter crease every this many degrees.
  private let majorStepDegrees: Double = 30

  /// Rotation (deg) captured at drag start, so movement is relative.
  @State private var dragAnchorDegrees: Double?
  /// Last crease index crossed, so a tick fires once per crease.
  @State private var lastTickIndex: Int = .min

  private static var darkAccent: Color {
    Color(UIColor(.appAccent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
  }

  var body: some View {
    Canvas(opaque: false) { context, size in
      drawDial(context, size: size)
    }
    .frame(width: PhotoDialMetrics.canvasSide, height: PhotoDialMetrics.canvasSide)
    // The layout slot is only the exposed arc below the canvas edge; the rest
    // of the (unclipped) wheel overflows upward, underneath the canvas.
    .frame(
      width: PhotoDialMetrics.canvasSide,
      height: PhotoDialMetrics.slotHeight,
      alignment: .bottom
    )
    .contentShape(Rectangle())
    .gesture(dialDrag)
    .simultaneousGesture(TapGesture(count: 2).onEnded {
      Haptic.playTick(major: true)
      lastTickIndex = 0
      onRotationChange(.zero)
    })
  }

  private func drawDial(_ context: GraphicsContext, size: CGSize) {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let radius = PhotoDialMetrics.radius
    let accent = Self.darkAccent
    let discRect = CGRect(
      x: center.x - radius, y: center.y - radius,
      width: radius * 2, height: radius * 2
    )
    let disc = Circle().path(in: discRect)

    // Wheel body — dished shading with the highlight pulled above center so
    // the exposed lower arc reads as a curved barrel.
    context.fill(
      disc,
      with: .radialGradient(
        Gradient(stops: [
          .init(color: Color(white: 0.16), location: 0),
          .init(color: Color(white: 0.08), location: 0.7),
          .init(color: Color(white: 0.03), location: 1),
        ]),
        center: CGPoint(x: center.x, y: center.y - radius * 0.25),
        startRadius: radius * 0.1,
        endRadius: radius * 1.15
      )
    )
    // Rim hairline.
    context.stroke(
      Circle().path(in: discRect.insetBy(dx: 0.5, dy: 0.5)),
      with: .color(.white.opacity(0.18)),
      lineWidth: 1
    )

    // Creases — accent value-marks that rotate with the wheel. Only the sweep
    // that can appear below the canvas edge is drawn, fading toward the ends
    // of the exposed arc. The whole pass renders in one layer with a shadow
    // filter so the creases glow against the dark chrome.
    let rot = rotation.degrees
    let maxOffDegrees = 90 - asin(Double(PhotoDialMetrics.centerLift / radius)) * 180 / .pi
    let firstTick = Int(((rot - maxOffDegrees) / tickStepDegrees).rounded(.down))
    let lastTick = Int(((rot + maxOffDegrees) / tickStepDegrees).rounded(.up))
    let majorEvery = Int((majorStepDegrees / tickStepDegrees).rounded())
    if lastTick >= firstTick {
      context.drawLayer { layer in
        layer.addFilter(.shadow(color: accent.opacity(0.9), radius: 3))
        for t in firstTick...lastTick {
          let value = Double(t) * tickStepDegrees
          let fade = max(0, 1 - pow(abs(value - rot) / maxOffDegrees, 1.6))
          if fade <= 0.02 { continue }
          let isMajor = t % majorEvery == 0
          // Bottom apex is +90° in y-down coordinates; a crease sits at the
          // apex when the rotation equals its value, and the wheel spins
          // clockwise (creases sweep left along the bottom) as rot increases.
          let angle = CGFloat((90 + rot - value) * .pi / 180)
          let dir = CGVector(dx: cos(angle), dy: sin(angle))
          let outerRadius = radius - 3
          let innerRadius = radius - (isMajor ? 20 : 12)
          var crease = Path()
          crease.move(to: CGPoint(
            x: center.x + dir.dx * innerRadius, y: center.y + dir.dy * innerRadius))
          crease.addLine(to: CGPoint(
            x: center.x + dir.dx * outerRadius, y: center.y + dir.dy * outerRadius))
          layer.stroke(
            crease,
            with: .color(accent.opacity((isMajor ? 0.85 : 0.45) * fade)),
            style: StrokeStyle(lineWidth: isMajor ? 2 : 1.3, lineCap: .round)
          )
        }
      }
    }

    // Ambient occlusion where the wheel disappears into the slot — a soft
    // shadow band just below the canvas's bottom edge, clipped to the disc.
    let edgeY = center.y + PhotoDialMetrics.centerLift
    var occlusion = context
    occlusion.clip(to: disc)
    occlusion.fill(
      Path(CGRect(
        x: center.x - radius,
        y: edgeY - PhotoDialMetrics.dentDepth,
        width: radius * 2,
        height: PhotoDialMetrics.dentDepth + 12
      )),
      with: .linearGradient(
        Gradient(colors: [Color.black.opacity(0.55), .clear]),
        startPoint: CGPoint(x: center.x, y: edgeY - 2),
        endPoint: CGPoint(x: center.x, y: edgeY + 12)
      )
    )

    // Fixed notch at the bottom apex — the reading line the current rotation
    // sits under. Drawn inside the wheel, glowing brighter than the creases.
    context.drawLayer { layer in
      layer.addFilter(.shadow(color: accent.opacity(0.9), radius: 5))
      var notch = Path()
      notch.move(to: CGPoint(x: center.x, y: center.y + radius - 4))
      notch.addLine(to: CGPoint(x: center.x, y: center.y + radius - 18))
      layer.stroke(
        notch,
        with: .color(accent),
        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
      )
    }
  }

  private var dialDrag: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let anchor = dragAnchorDegrees ?? rotation.degrees
        if dragAnchorDegrees == nil { dragAnchorDegrees = anchor }
        // Wheel follows the finger like a physical dial: the rim moves one
        // arc-length point per point of drag, so dragging the exposed bottom
        // arc rightward spins the wheel (and the photo) counterclockwise.
        let degreesPerPoint = 180 / (Double.pi * Double(PhotoDialMetrics.radius))
        let newDegrees = anchor - Double(value.translation.width) * degreesPerPoint

        let index = Int((newDegrees / tickStepDegrees).rounded())
        if index != lastTickIndex {
          lastTickIndex = index
          let major = index % Int((majorStepDegrees / tickStepDegrees).rounded()) == 0
          Haptic.playTick(major: major)
        }

        onRotationChange(.degrees(newDegrees))
      }
      .onEnded { _ in dragAnchorDegrees = nil }
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
    var body: some View {
      ZStack {
        Color.black
        VStack(spacing: 0) {
          DialSlotCanvasShape(cornerRadius: 36, dentProgress: 1)
            .fill(Color.gray.opacity(0.4))
            .frame(width: 342, height: 200)
          PhotoRotationDial(
            rotation: rotation,
            onRotationChange: { rotation = $0 }
          )
          .zIndex(-1)
        }
      }
      .ignoresSafeArea()
    }
  }
  return Host()
}
