//
//  DrawingDisplayView.swift
//  Joodle
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftUI

// MARK: - Environment

extension EnvironmentValues {
  /// Whether the experimental wigglypaint boil may *animate* in this context.
  ///
  /// Defaults to `true` so doodles boil everywhere they do today. The share
  /// sheet sets it `false` for static (non-animated) export styles: a still
  /// image can't wiggle, so animating the preview misrepresents the export.
  @Entry var allowsWiggleAnimation: Bool = true

  /// Whether to boil the strokes regardless of the experimental `enableWigglyStrokes`
  /// preference. Set by the dedicated wiggly share-card styles so their preview boils
  /// even when the user hasn't turned the experimental feature on.
  @Entry var forcesWiggleAnimation: Bool = false
}

struct DrawingDisplayView: View {
  let entry: DayEntry?
  /// When set, renders this specific doodle instead of the entry's primary
  /// drawing. `entry` is still used for month-based tinting. Nil = primary.
  let doodle: Doodle?
  let displaySize: CGFloat
  let dotStyle: DotStyle
  let accent: Bool
  let highlighted: Bool
  let scale: CGFloat
  let useThumbnail: Bool  // Use pre-rendered thumbnail for performance
  let animateDrawing: Bool  // Animate path drawing replay
  let looping: Bool  // Loop animation infinitely
  let strokeMultiplier: CGFloat  // Multiplier for stroke width (useful for small cells)
  let immediateAppear: Bool  // Skip appear animation (for off-screen rendering)

  // Animation timing constants
  private static let maxAnimationDuration: Double = 3.0  // Maximum total animation duration
  private static let durationPerPixel: Double = 0.2 / 50.0  // 0.2 seconds per 20 pixels
  private static let minStrokeDuration: Double = 0.05  // Minimum duration for very short strokes/dots

  @Environment(\.userPreferences) private var userPreferences
  @Environment(\.allowsWiggleAnimation) private var allowsWiggleAnimation
  @Environment(\.forcesWiggleAnimation) private var forcesWiggleAnimation

  @State private var pathsWithMetadata: [PathWithMetadata] = []
  /// Per-stroke polyline points used to drive the experimental wiggle effect.
  /// Precomputed alongside `pathsWithMetadata` so the boil doesn't re-extract
  /// points every frame.
  @State private var wiggleSources: [(points: [CGPoint], isDot: Bool)] = []
  @State private var isVisible = false
  @State private var thumbnailImage: UIImage?
  /// Stable anchor for the wiggle's periodic clock.
  @State private var wiggleEpoch = Date()

  // Animation state for drawing replay
  @State private var drawingProgress: CGFloat = 0.0
  @State private var hasAnimatedDrawing: Bool = false
  @State private var isAnimatingDrawing: Bool = false
  @State private var animationStartTime: Date?
  @State private var lastCalculatedProgress: CGFloat = 0.0

  // Use shared cache for drawing paths
  private let pathCache = DrawingPathCache.shared

  /// Calculate per-stroke durations based on stroke lengths
  /// Returns array of durations and total animation duration
  private var strokeTimingInfo: (durations: [Double], totalDuration: Double, cumulativeEndTimes: [Double]) {
    guard !pathsWithMetadata.isEmpty else {
      return ([], 0, [])
    }

    // Calculate raw duration for each stroke based on length
    var rawDurations: [Double] = pathsWithMetadata.map { pathWithMetadata in
      if pathWithMetadata.metadata.isDot {
        return Self.minStrokeDuration
      } else {
        let lengthBasedDuration = Double(pathWithMetadata.metadata.length) * Self.durationPerPixel
        return max(Self.minStrokeDuration, lengthBasedDuration)
      }
    }

    let rawTotal = rawDurations.reduce(0, +)

    // If total exceeds max, scale down all durations proportionally
    if rawTotal > Self.maxAnimationDuration {
      let scaleFactor = Self.maxAnimationDuration / rawTotal
      rawDurations = rawDurations.map { $0 * scaleFactor }
    }

    let totalDuration = min(rawTotal, Self.maxAnimationDuration)

    // Calculate cumulative end times for each stroke
    var cumulativeEndTimes: [Double] = []
    var cumulative: Double = 0
    for duration in rawDurations {
      cumulative += duration
      cumulativeEndTimes.append(cumulative)
    }

    return (rawDurations, totalDuration, cumulativeEndTimes)
  }

  /// Calculated total animation duration based on stroke lengths
  private var calculatedAnimationDuration: Double {
    return strokeTimingInfo.totalDuration
  }

  init(
    entry: DayEntry?,
    doodle: Doodle? = nil,
    displaySize: CGFloat,
    dotStyle: DotStyle = .present,
    accent: Bool = true,
    highlighted: Bool = false,
    scale: CGFloat = 1.0,
    useThumbnail: Bool = false,
    animateDrawing: Bool = false,
    looping: Bool = false,
    strokeMultiplier: CGFloat = 1.0,
    immediateAppear: Bool = false
  ) {
    self.entry = entry
    self.doodle = doodle
    self.displaySize = displaySize
    self.dotStyle = dotStyle
    self.accent = accent
    self.highlighted = highlighted
    self.scale = scale
    self.useThumbnail = useThumbnail
    self.animateDrawing = animateDrawing
    self.looping = looping
    self.strokeMultiplier = strokeMultiplier
    self.immediateAppear = immediateAppear
    _isVisible = State(initialValue: immediateAppear)

    // Pre-load drawing paths eagerly for off-screen rendering so the Canvas
    // has data on the very first render pass (no need to wait for .onAppear)
    let eagerData = doodle?.drawingData ?? entry?.drawingData
    if immediateAppear, let drawingData = eagerData, !drawingData.isEmpty {
      _pathsWithMetadata = State(initialValue: DrawingPathCache.shared.getPathsWithMetadata(for: drawingData))
    }
  }

  /// The drawing bytes to render — the injected doodle's, else the entry's primary.
  private var resolvedDrawingData: Data? { doodle?.drawingData ?? entry?.drawingData }
  private var resolvedThumbnail20: Data? { doodle != nil ? doodle?.thumbnail20 : entry?.drawingThumbnail20 }
  private var resolvedThumbnail200: Data? { doodle != nil ? doodle?.thumbnail200 : entry?.drawingThumbnail200 }

  /// Whether the experimental wigglypaint boil should drive this drawing.
  /// Off for thumbnail cells (the boil is imperceptible at that size and not
  /// worth the cost) and when there are no vector strokes to jitter. The draw-in
  /// replay takes precedence via the `isAnimatingDrawing` branch in `body`, so
  /// it is intentionally not gated here. Also off when the surrounding context
  /// opts out via `allowsWiggleAnimation` (e.g. a static share-card preview/export,
  /// where a wiggling preview would misrepresent the still that gets shared).
  private var wiggleEnabled: Bool {
    // The user-preference wiggle is a Joodle Pro feature; `forcesWiggleAnimation`
    // (the dedicated wiggly share cards) stays independent so their previews
    // still boil even for free users browsing the paywalled card.
    let userWiggle = userPreferences.enableWigglyStrokes && SubscriptionManager.shared.hasPremiumAccess
    return allowsWiggleAnimation && (forcesWiggleAnimation || userWiggle) && !useThumbnail && !wiggleSources.isEmpty
  }

  private var foregroundColor: Color {
    if highlighted { return .appSecondary }

    // Under the rainbow theme this resolves to the entry's month color; for
    // solid themes it's just `.appAccent`. Keyed off the entry, so moving a
    // doodle across months recolors it with zero data changes.
    let accentColor = Color.appDrawingColor(forMonth: entry?.month)
    if accent { return accentColor }

    // Override base color if it is a present dot.
    if dotStyle == .present { return accentColor }
    // Future doodles keep their faded opacity, but the rainbow theme tints them
    // by month like every other day so the future reads apart too.
    if dotStyle == .future {
      return (userPreferences.accentColor.isRainbow ? accentColor : .textColor).opacity(0.15)
    }

    // Resting (non-selected) doodles are monochrome under solid themes, but the
    // rainbow theme colors them by month. Selection recolors the cell via the
    // `highlighted` branch above, so this only affects the unselected state.
    if userPreferences.accentColor.isRainbow { return accentColor }
    return .textColor
  }

  var body: some View {
    Group {
      if useThumbnail, let thumbnailImage = thumbnailImage {
        // Use pre-rendered thumbnail for performance
        Image(uiImage: thumbnailImage)
          .resizable()
          .renderingMode(.template)
          .foregroundStyle(foregroundColor)
          .frame(width: displaySize * scale, height: displaySize * scale)
          .scaleEffect(isVisible ? 1.0 : 0.9)
          .blur(radius: isVisible ? 0 : 5)
      } else {
        // Use TimelineView to drive animation when animating, otherwise static Canvas
        if isAnimatingDrawing {
          TimelineView(.animation) { timeline in
            Canvas { context, size in
              renderAnimatedFrame(context: &context, size: size, timelineDate: timeline.date)
            }
          }
          .frame(width: displaySize * scale, height: displaySize * scale)
          .scaleEffect(isVisible ? 1.0 : 0.9)
          .blur(radius: isVisible ? 0 : 5)
          .onReceive(Timer.publish(every: 0.016, on: .main, in: .common).autoconnect()) { _ in
            // Check for animation completion/looping every frame (~60fps)
            if isAnimatingDrawing, let startTime = animationStartTime {
              let elapsed = Date().timeIntervalSince(startTime)
              let progress = min(1.0, CGFloat(elapsed / calculatedAnimationDuration))
              
              if progress >= 1.0 && lastCalculatedProgress < 1.0 {
                if looping {
                  animationStartTime = Date()
                  lastCalculatedProgress = 0.0
                } else {
                  isAnimatingDrawing = false
                  drawingProgress = 1.0
                }
              }
              lastCalculatedProgress = progress
            }
          }
        } else if wiggleEnabled {
          // Experimental wigglypaint boil — redraw the completed strokes with a
          // per-vertex jitter so the doodle never sits still. Driven by a
          // periodic clock at the boil rate (~7fps) rather than the 60fps display
          // refresh, since the effect only changes state that often.
          TimelineView(.periodic(from: wiggleEpoch, by: WigglyStroke.boilInterval)) { timeline in
            Canvas { context, size in
              renderWiggleFrame(context: &context, size: size, timelineDate: timeline.date)
            }
          }
          .frame(width: displaySize * scale, height: displaySize * scale)
          .scaleEffect(isVisible ? 1.0 : 0.9)
          .blur(radius: isVisible ? 0 : 5)
        } else {
          // Static canvas when not animating - no TimelineView updates
          Canvas { context, size in
            renderStaticDrawing(context: &context, size: size)
          }
          .frame(width: displaySize * scale, height: displaySize * scale)
          .scaleEffect(isVisible ? 1.0 : 0.9)
          .blur(radius: isVisible ? 0 : 5)
        }
      }
    }
    .animation(.springFkingSatifying, value: isVisible)
    .animation(.springFkingSatifying, value: scale)
    .onAppear {
      // Load data immediately and animate
      loadDrawingData()
      if !isVisible {
        withAnimation(.springFkingSatifying) {
          isVisible = true
        }
      }
      // Start drawing animation if enabled and not yet animated
      startDrawingAnimationIfNeeded()
    }
    .onChange(of: resolvedDrawingData) { oldValue, newValue in
      // Load new data and animate immediately
      loadDrawingData()
      withAnimation(.springFkingSatifying) {
        isVisible = true
      }
      // Reset and restart drawing animation for new data
      if animateDrawing && newValue != oldValue {
        hasAnimatedDrawing = false
        drawingProgress = 0.0
        startDrawingAnimationIfNeeded()
      }
    }
    .onChange(of: resolvedThumbnail20) { _, _ in
      // Reload thumbnail when it's updated
      if useThumbnail {
        loadDrawingData()
      }
    }
    .onChange(of: resolvedThumbnail200) { _, _ in
      // Reload thumbnail when it's updated
      if useThumbnail {
        loadDrawingData()
      }
    }
    .onChange(of: animateDrawing) { _, newValue in
      // When animateDrawing changes to true, reset and restart animation
      if newValue {
        hasAnimatedDrawing = false
        drawingProgress = 0.0
        startDrawingAnimationIfNeeded()
      } else {
        // When animateDrawing changes to false, stop the animation
        isAnimatingDrawing = false
      }
    }
  }

  /// Start the drawing animation if enabled and not yet played
  private func startDrawingAnimationIfNeeded() {
    guard animateDrawing, !hasAnimatedDrawing, !pathsWithMetadata.isEmpty else { return }

    hasAnimatedDrawing = true
    drawingProgress = 0.0
    animationStartTime = Date()
    isAnimatingDrawing = true
  }

  /// Render animated frame with progress calculation
  private func renderAnimatedFrame(context: inout GraphicsContext, size: CGSize, timelineDate: Date) {
    // Calculate progress based on elapsed time during animation
    let currentProgress: CGFloat = {
      if isAnimatingDrawing, let startTime = animationStartTime {
        let elapsed = timelineDate.timeIntervalSince(startTime)
        let progress = min(1.0, CGFloat(elapsed / calculatedAnimationDuration))
        // Apply easeOut curve: 1 - (1 - t)^2
        let eased = 1.0 - pow(1.0 - progress, 2)
        return eased
      }
      return drawingProgress
    }()

    // Calculate scale from canvas size (300x300) to display size
    let canvasScale = (displaySize * scale) / CANVAS_SIZE

    // Scale the context to render at display size
    context.scaleBy(x: canvasScale, y: canvasScale)

    // Get timing info for length-based animation
    let timingInfo = strokeTimingInfo
    let totalDuration = timingInfo.totalDuration
    let cumulativeEndTimes = timingInfo.cumulativeEndTimes
    let durations = timingInfo.durations

    // Calculate current elapsed time based on progress
    let effectiveProgress = animateDrawing ? currentProgress : 1.0
    let currentElapsedTime = effectiveProgress * CGFloat(totalDuration)

    // Apply the experimental wiggle to the animating strokes too, so the draw-in
    // replay boils as it draws rather than animating a perfectly straight line.
    let boilFrame: Int? = (wiggleEnabled && wiggleSources.count == pathsWithMetadata.count)
      ? WigglyStroke.frameIndex(at: timelineDate.timeIntervalSinceReferenceDate)
      : nil

    for (index, pathWithMetadata) in pathsWithMetadata.enumerated() {
      // Determine start time for this stroke
      let strokeStartTime: CGFloat = index == 0 ? 0 : CGFloat(cumulativeEndTimes[index - 1])
      let strokeEndTime = CGFloat(cumulativeEndTimes[index])

      // Skip paths that haven't started yet
      guard currentElapsedTime > strokeStartTime || !animateDrawing else { continue }

      // Jitter the stroke for this boil frame when wiggling; the trim below then
      // reveals the wiggled path as it "draws".
      let path: Path = boilFrame.map {
        WigglyStroke.path(points: wiggleSources[index].points, isDot: wiggleSources[index].isDot, frame: $0)
      } ?? pathWithMetadata.path

      // Calculate trim for the current path being drawn
      let pathProgress: CGFloat
      if animateDrawing && currentElapsedTime < strokeEndTime {
        // This stroke is currently being drawn
        let strokeDuration = CGFloat(durations[index])
        let timeIntoStroke = currentElapsedTime - strokeStartTime
        pathProgress = min(1.0, max(0.0, timeIntoStroke / strokeDuration))
      } else if animateDrawing && currentElapsedTime < strokeStartTime {
        // This stroke hasn't started yet
        pathProgress = 0.0
      } else {
        // Stroke is complete
        pathProgress = 1.0
      }

      // Render based on original intent stored in metadata
      if pathWithMetadata.metadata.isDot {
        // For dots, fade in based on progress
        if pathProgress > 0.5 {
          context.fill(path, with: .color(foregroundColor))
        }
      } else {
        // For strokes, use trim effect
        let trimmedPath = path.trimmedPath(from: 0, to: pathProgress)
        context.stroke(
          trimmedPath,
          with: .color(foregroundColor),
          style: StrokeStyle(
            lineWidth: DRAWING_LINE_WIDTH * strokeMultiplier,
            lineCap: .round,
            lineJoin: .round
          )
        )
      }
    }
  }

  /// Update animation progress and handle looping
  private func updateAnimationProgress(timelineDate: Date) {
    guard isAnimatingDrawing, let startTime = animationStartTime else { return }

    let elapsed = timelineDate.timeIntervalSince(startTime)
    let progress = min(1.0, CGFloat(elapsed / calculatedAnimationDuration))

    if progress >= 1.0 {
      if looping {
        // Reset for next loop iteration
        animationStartTime = Date()
      } else {
        isAnimatingDrawing = false
        drawingProgress = 1.0
      }
    }
  }

  /// Render animated drawing with TimelineView
  @ViewBuilder
  private func renderDrawingCanvas(timelineDate: Date) -> some View {
    // Calculate progress based on elapsed time during animation
    let currentProgress: CGFloat = {
      if isAnimatingDrawing, let startTime = animationStartTime {
        let elapsed = timelineDate.timeIntervalSince(startTime)
        let progress = min(1.0, CGFloat(elapsed / calculatedAnimationDuration))
        // Apply easeOut curve: 1 - (1 - t)^2
        let eased = 1.0 - pow(1.0 - progress, 2)
        return eased
      }
      return drawingProgress
    }()

    Canvas { context, size in
      // Calculate scale from canvas size (300x300) to display size
      let canvasScale = (displaySize * scale) / CANVAS_SIZE

      // Scale the context to render at display size
      context.scaleBy(x: canvasScale, y: canvasScale)

      // Get timing info for length-based animation
      let timingInfo = strokeTimingInfo
      let totalDuration = timingInfo.totalDuration
      let cumulativeEndTimes = timingInfo.cumulativeEndTimes
      let durations = timingInfo.durations

      // Calculate current elapsed time based on progress
      let effectiveProgress = animateDrawing ? currentProgress : 1.0
      let currentElapsedTime = effectiveProgress * CGFloat(totalDuration)

      for (index, pathWithMetadata) in pathsWithMetadata.enumerated() {
        // Determine start time for this stroke
        let strokeStartTime: CGFloat = index == 0 ? 0 : CGFloat(cumulativeEndTimes[index - 1])
        let strokeEndTime = CGFloat(cumulativeEndTimes[index])

        // Skip paths that haven't started yet
        guard currentElapsedTime > strokeStartTime || !animateDrawing else { continue }

        let path = pathWithMetadata.path

        // Calculate trim for the current path being drawn
        let pathProgress: CGFloat
        if animateDrawing && currentElapsedTime < strokeEndTime {
          // This stroke is currently being drawn
          let strokeDuration = CGFloat(durations[index])
          let timeIntoStroke = currentElapsedTime - strokeStartTime
          pathProgress = min(1.0, max(0.0, timeIntoStroke / strokeDuration))
        } else if animateDrawing && currentElapsedTime < strokeStartTime {
          // This stroke hasn't started yet
          pathProgress = 0.0
        } else {
          // Stroke is complete
          pathProgress = 1.0
        }

        // Render based on original intent stored in metadata
        if pathWithMetadata.metadata.isDot {
          // For dots, fade in based on progress
          if pathProgress > 0.5 {
            context.fill(path, with: .color(foregroundColor))
          }
        } else {
          // For strokes, use trim effect
          let trimmedPath = path.trimmedPath(from: 0, to: pathProgress)
          context.stroke(
            trimmedPath,
            with: .color(foregroundColor),
            style: StrokeStyle(
              lineWidth: DRAWING_LINE_WIDTH * strokeMultiplier,
              lineCap: .round,
              lineJoin: .round
            )
          )
        }
      }
    }
    .onChange(of: currentProgress) { _, newProgress in
      // Stop animation when complete, or restart if looping
      if newProgress >= 1.0 && isAnimatingDrawing {
        if looping {
          // Reset for next loop iteration
          animationStartTime = Date()
        } else {
          isAnimatingDrawing = false
          drawingProgress = 1.0
        }
      }
    }
  }

  /// Render a single boil frame of the experimental wiggle effect. Strokes are
  /// fully drawn (no trim) and jittered per the current time-derived frame.
  private func renderWiggleFrame(context: inout GraphicsContext, size: CGSize, timelineDate: Date) {
    let canvasScale = (displaySize * scale) / CANVAS_SIZE
    context.scaleBy(x: canvasScale, y: canvasScale)

    let frame = WigglyStroke.frameIndex(at: timelineDate.timeIntervalSinceReferenceDate)

    for source in wiggleSources {
      let path = WigglyStroke.path(points: source.points, isDot: source.isDot, frame: frame)
      if source.isDot {
        context.fill(path, with: .color(foregroundColor))
      } else {
        context.stroke(
          path,
          with: .color(foregroundColor),
          style: StrokeStyle(
            lineWidth: DRAWING_LINE_WIDTH * strokeMultiplier,
            lineCap: .round,
            lineJoin: .round
          )
        )
      }
    }
  }

  /// Render static drawing without TimelineView updates
  private func renderStaticDrawing(context: inout GraphicsContext, size: CGSize) {
    // Calculate scale from canvas size (300x300) to display size
    let canvasScale = (displaySize * scale) / CANVAS_SIZE

    // Scale the context to render at display size
    context.scaleBy(x: canvasScale, y: canvasScale)

    // Render all paths at 100% progress
    for pathWithMetadata in pathsWithMetadata {
      let path = pathWithMetadata.path

      if pathWithMetadata.metadata.isDot {
        context.fill(path, with: .color(foregroundColor))
      } else {
        context.stroke(
          path,
          with: .color(foregroundColor),
          style: StrokeStyle(
            lineWidth: DRAWING_LINE_WIDTH * strokeMultiplier,
            lineCap: .round,
            lineJoin: .round
          )
        )
      }
    }
  }

  private func loadDrawingData() {
    guard let drawingData = resolvedDrawingData else {
      pathsWithMetadata = []
      wiggleSources = []
      thumbnailImage = nil
      return
    }

    if useThumbnail {
      // Select appropriate thumbnail based on display size
      let thumbnailData: Data?
      if displaySize <= 20 {
        thumbnailData = resolvedThumbnail20
      } else {
        thumbnailData = resolvedThumbnail200
      }

      if let thumbnailData = thumbnailData {
        thumbnailImage = UIImage(data: thumbnailData)
      } else {
        // Fallback to vector rendering if thumbnail not available
        pathsWithMetadata = pathCache.getPathsWithMetadata(for: drawingData)
      }
    } else {
      // Use cached paths with metadata to avoid repeated JSON decoding
      pathsWithMetadata = pathCache.getPathsWithMetadata(for: drawingData)
    }

    rebuildWiggleSources()
  }

  /// Precompute the per-stroke points the wiggle effect jitters, so the boil
  /// loop doesn't re-extract them every frame.
  private func rebuildWiggleSources() {
    wiggleSources = pathsWithMetadata.map { ($0.path.extractPoints(), $0.metadata.isDot) }
  }
}

#Preview("Vector Mode") {
  DrawingDisplayView(
    entry: DayEntry(body: "", createdAt: Date(), drawingData: createMockDrawingData()),
    displaySize: 200,
    dotStyle: .future,
    accent: false,
    highlighted: false,
    scale: 1.0,
    useThumbnail: false
  )
  .frame(width: 200, height: 200)
  .background(.gray.opacity(0.1))
}

#Preview("Thumbnail Mode") {
  DrawingDisplayView(
    entry: DayEntry(body: "", createdAt: Date(), drawingData: createMockDrawingData()),
    displaySize: 20,
    dotStyle: .present,
    accent: true,
    highlighted: true,
    scale: 1.0,
    useThumbnail: true
  )
  .frame(width: 20, height: 20)
  .background(.gray.opacity(0.1))
}

#Preview("Animated Drawing") {
  DrawingDisplayView(
    entry: DayEntry(body: "", createdAt: Date(), drawingData: createMockDrawingData()),
    displaySize: 200,
    animateDrawing: true,
    looping: true
  )
  .frame(width: 200, height: 200)
  .background(.gray.opacity(0.1))
}
