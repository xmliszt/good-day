//
//  SharedCanvasView.swift
//  Joodle
//
//  Created by Li Yuxuan on 10/8/25.
//

import AVFoundation
import SwiftUI

/// Configuration for the canvas action buttons
struct CanvasButtonsConfig {
  let onClear: () -> Void
  let onUndo: (() -> Void)?
  let onRedo: (() -> Void)?
  let canClear: Bool
  let canUndo: Bool
  let canRedo: Bool
  /// True while an existing doodle's undo history is still being prepared
  /// (it's built after the open animation settles). Shows the undo/redo
  /// buttons optimistically — disabled — so they don't pop in half a second
  /// after the canvas opens.
  let isUndoHistoryLoading: Bool
  let showClearConfirmation: Binding<Bool>?
  /// Optional view shown in the center slot when undo/redo buttons are hidden
  let centerContent: AnyView?
  /// Optional view shown overlapping the clear-button slot (top-left).
  /// Used for the camera/reference button which only appears when canClear is false.
  let leadingExtra: AnyView?
  /// Optional view shown in the trailing slot when stroke buttons are hidden
  /// (e.g. camera live mode). Replaces the normal trailing save button.
  let trailingExtra: AnyView?
  /// When true, hide clear/undo/redo entirely (camera mode)
  let hideStrokeButtons: Bool

  init(
    onClear: @escaping () -> Void,
    onUndo: (() -> Void)? = nil,
    onRedo: (() -> Void)? = nil,
    canClear: Bool = true,
    canUndo: Bool = false,
    canRedo: Bool = false,
    isUndoHistoryLoading: Bool = false,
    showClearConfirmation: Binding<Bool>? = nil,
    centerContent: AnyView? = nil,
    leadingExtra: AnyView? = nil,
    trailingExtra: AnyView? = nil,
    hideStrokeButtons: Bool = false
  ) {
    self.onClear = onClear
    self.onUndo = onUndo
    self.onRedo = onRedo
    self.canClear = canClear
    self.canUndo = canUndo
    self.canRedo = canRedo
    self.isUndoHistoryLoading = isUndoHistoryLoading
    self.showClearConfirmation = showClearConfirmation
    self.centerContent = centerContent
    self.leadingExtra = leadingExtra
    self.trailingExtra = trailingExtra
    self.hideStrokeButtons = hideStrokeButtons
  }
}

/// Duration of the drawing's fade-in reveal — matched to the button entry
/// spring (which uses this same value for its `response`) so the strokes and
/// buttons land together. File-scoped because a generic type
/// (`SharedCanvasView<TrailingHeader>`) can't hold a `static` stored property.
private let strokeTraceDuration: TimeInterval = 0.5

/// A reusable canvas view that handles drawing logic, rendering, and gestures.
/// It is designed to be stateless regarding the data persistence, delegating that to the parent view.
struct SharedCanvasView<TrailingHeader: View>: View {
  @Binding var paths: [Path]
  @Binding var pathMetadata: [PathMetadata]
  @Binding var currentPath: Path
  @Binding var currentPathIsDot: Bool
  @Binding var isDrawing: Bool

  @Environment(\.userPreferences) private var userPreferences

  var placeholderData: Data? = nil
  var buttonsConfig: CanvasButtonsConfig? = nil
  var canvasCornerRadius: CGFloat = 32

  /// Color for the strokes being drawn. Defaults to the global accent; the
  /// editor passes the date's month color so a doodle drawn under the rainbow
  /// theme is painted in that month's color as the finger moves.
  var strokeColor: Color = .appAccent

  /// Optional tracing-reference image rendered as a 30% backdrop inside the canvas.
  var backdropImage: UIImage? = nil
  /// Zoom / translation / rotation applied to `backdropImage` so the user can
  /// position the reference for tracing. Identity values (1, .zero, .zero) render
  /// the photo centered and filling the square, unchanged from before.
  var backdropZoom: CGFloat = 1.0
  var backdropOffset: CGSize = .zero
  var backdropRotation: Angle = .zero
  /// When set and `isCameraLive` is true, shows a live camera preview filling the canvas.
  var liveCameraSession: AVCaptureSession? = nil
  /// Active capture device — drives the preview's rotation coordinator so
  /// orientation tracks correctly across camera flips.
  var liveCameraDevice: AVCaptureDevice? = nil
  var isCameraLive: Bool = false
  var liveCameraMirrored: Bool = false
  /// Drives the shutter overlay and the gating of the live preview mount.
  /// `nil` in tutorial/mock mode where the camera feature is disabled.
  var shutterController: CameraShutterController? = nil
  /// Mirror of `shutterController?.isFullyClosed`, sourced from
  /// `CameraReferenceContext` so changes actually drive a re-render here.
  var isShutterFullyClosed: Bool = false
  /// True for the entire close → open shutter sequence. Drives the inner
  /// shadow so it appears the instant the shutter starts closing (well before
  /// `isCameraLive` flips, which only happens after the shutter reopens).
  var isShutterCycling: Bool = false
  /// When true, forcibly unmount the live preview even if camera mode is
  /// still active — used during a flip cycle to avoid a stale frame from the
  /// previous device showing through.
  var suppressLivePreview: Bool = false
  /// Bumped on every photo capture to trigger the black flash overlay.
  var captureFlashID: UUID? = nil
  /// True while waiting for the camera to finish processing the captured photo.
  var isCapturing: Bool = false

  /// While true, the canvas is persisting on dismiss: the top-row action
  /// buttons dim + disable and the drawing surface dims, communicating a
  /// deliberate "saving" state during the brief synchronous save.
  var isSaving: Bool = false

  /// Current display zoom of the live camera (1.0 = baseline). The pinch
  /// gesture's starting point. The on-screen zoom slider lives at the screen
  /// edge in `ContentView`, not here.
  var cameraZoomFactor: CGFloat = 1.0
  /// Display-zoom range the pinch can reach. A degenerate `1...1` (the default)
  /// disables pinch zoom.
  var cameraZoomRange: ClosedRange<CGFloat> = 1...1
  /// Called with a new display zoom from the pinch gesture.
  var onSetCameraZoom: (CGFloat) -> Void = { _ in }

  /// Gates the top action-buttons row. The parent holds this false until the
  /// floating container has finished expanding, then flips it true so the row
  /// fades in *after* the open animation settles. Keeping the live-glass
  /// buttons out of the tree during the expansion both avoids the mid-open
  /// state flicker and keeps them out of the container's offscreen warp pass
  /// (where rasterizing Liquid Glass per frame was a major source of lag).
  /// Defaults to `true` so non-animated callers (previews, tutorial) are
  /// unaffected.
  var topButtonsVisible: Bool = true

  /// Set by the parent (to "now") once the container has finished expanding to
  /// play a one-shot stroke-trace replay: every committed path is drawn
  /// progressively from start to tip over `strokeTraceDuration`, all sharing
  /// one 0→1 progress so they start and finish together. `nil` (the default for
  /// non-animated callers like previews/tutorial, and after the replay ends)
  /// draws the strokes statically at full.
  var strokeRevealDate: Date? = nil

  /// Track the maximum distance from start point during a gesture to detect dots vs strokes
  @State private var maxDistanceFromStart: CGFloat = 0
  @State private var gestureStartPoint: CGPoint = .zero

  /// Callback when a stroke is finished (finger lifted or moved out of bounds)
  var onCommitStroke: () -> Void

  /// Optional trailing content for the header row (e.g. Save button)
  var TrailingHeaderView: () -> TrailingHeader

  @State private var placeholderPaths: [(path: Path, isDot: Bool)] = []
  @State private var placeholderID = UUID()
  /// Per-stroke points for committed `paths`, precomputed so the experimental
  /// wiggle boil doesn't re-extract them every frame. Index-aligned with `paths`.
  @State private var wiggleSources: [[CGPoint]] = []
  /// Stable anchor for the wiggle's periodic clock.
  @State private var wiggleEpoch = Date()
  /// Mounted only while the shutter is fully closed over the canvas, so the
  /// live feed never appears during a transition. Latches across the open
  /// phase so the preview stays visible once the shutter has retracted.
  @State private var cameraPreviewMounted: Bool = false
  /// Opacity of the black capture-flash overlay. Pulsed 0 → 1 → 0 on each
  /// `captureFlashID` change to fake a shutter snap.
  @State private var captureFlashOpacity: Double = 0
  /// Display zoom captured on the first frame of a pinch, so each
  /// `MagnifyGesture` update scales relative to where the zoom was when the
  /// gesture began. `nil` between gestures; set on the first frame and cleared
  /// on `.onEnded` so the next pinch re-anchors to the then-current zoom.
  @State private var pinchStartZoom: CGFloat?

  init(
    paths: Binding<[Path]>,
    pathMetadata: Binding<[PathMetadata]>,
    currentPath: Binding<Path>,
    currentPathIsDot: Binding<Bool>,
    isDrawing: Binding<Bool>,
    placeholderData: Data? = nil,
    buttonsConfig: CanvasButtonsConfig? = nil,
    canvasCornerRadius: CGFloat = 32,
    strokeColor: Color = .appAccent,
    backdropImage: UIImage? = nil,
    backdropZoom: CGFloat = 1.0,
    backdropOffset: CGSize = .zero,
    backdropRotation: Angle = .zero,
    liveCameraSession: AVCaptureSession? = nil,
    liveCameraDevice: AVCaptureDevice? = nil,
    isCameraLive: Bool = false,
    liveCameraMirrored: Bool = false,
    shutterController: CameraShutterController? = nil,
    isShutterFullyClosed: Bool = false,
    isShutterCycling: Bool = false,
    suppressLivePreview: Bool = false,
    captureFlashID: UUID? = nil,
    isCapturing: Bool = false,
    isSaving: Bool = false,
    cameraZoomFactor: CGFloat = 1.0,
    cameraZoomRange: ClosedRange<CGFloat> = 1...1,
    onSetCameraZoom: @escaping (CGFloat) -> Void = { _ in },
    topButtonsVisible: Bool = true,
    strokeRevealDate: Date? = nil,
    onCommitStroke: @escaping () -> Void,
    @ViewBuilder trailingHeader: @escaping () -> TrailingHeader
  ) {
    self._paths = paths
    self._pathMetadata = pathMetadata
    self._currentPath = currentPath
    self._currentPathIsDot = currentPathIsDot
    self._isDrawing = isDrawing
    self.placeholderData = placeholderData
    self.buttonsConfig = buttonsConfig
    self.canvasCornerRadius = canvasCornerRadius
    self.strokeColor = strokeColor
    self.backdropImage = backdropImage
    self.backdropZoom = backdropZoom
    self.backdropOffset = backdropOffset
    self.backdropRotation = backdropRotation
    self.liveCameraSession = liveCameraSession
    self.liveCameraDevice = liveCameraDevice
    self.isCameraLive = isCameraLive
    self.liveCameraMirrored = liveCameraMirrored
    self.shutterController = shutterController
    self.isShutterFullyClosed = isShutterFullyClosed
    self.isShutterCycling = isShutterCycling
    self.suppressLivePreview = suppressLivePreview
    self.captureFlashID = captureFlashID
    self.isCapturing = isCapturing
    self.isSaving = isSaving
    self.cameraZoomFactor = cameraZoomFactor
    self.cameraZoomRange = cameraZoomRange
    self.onSetCameraZoom = onSetCameraZoom
    self.topButtonsVisible = topButtonsVisible
    self.strokeRevealDate = strokeRevealDate
    self.onCommitStroke = onCommitStroke
    self.TrailingHeaderView = trailingHeader
  }

  /// Whether committed strokes should boil with the experimental wiggle.
  /// Suppressed in camera-live mode (the drawing surface is hidden) and while a
  /// placeholder is showing (no real strokes yet).
  private var wiggleEnabled: Bool {
    // Wiggly strokes are a Joodle Pro feature.
    userPreferences.enableWigglyStrokes && SubscriptionManager.shared.hasPremiumAccess && !isCameraLive && !paths.isEmpty
  }

  /// Pinch-to-zoom over the live preview. Active only in camera mode (the
  /// drawing surface is already disabled there, so it never competes with the
  /// stroke `DragGesture`). Each update scales the zoom captured at gesture
  /// start, clamped to the available range.
  private var cameraZoomMagnifyGesture: some Gesture {
    MagnifyGesture(minimumScaleDelta: 0)
      .onChanged { value in
        // Anchor to the live zoom on the gesture's first frame so subsequent
        // frames scale relative to where the zoom actually was, not 1x.
        let start = pinchStartZoom ?? cameraZoomFactor
        if pinchStartZoom == nil { pinchStartZoom = start }
        let target = start * value.magnification
        let clamped = min(max(target, cameraZoomRange.lowerBound), cameraZoomRange.upperBound)
        onSetCameraZoom(clamped)
      }
      .onEnded { _ in pinchStartZoom = nil }
  }

  /// Top action-buttons row. On iOS 26+ the row gets its own
  /// `GlassEffectContainer` so the buttons' Liquid Glass composites locally as
  /// one group (same pattern as `HeaderButtonsView`). Without a container the
  /// glass layers are hoisted out of the row and end up rendered beneath the
  /// floating container's black gradient — invisible but still hit-testable.
  @ViewBuilder
  private func actionButtonsRow(_ config: CanvasButtonsConfig) -> some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: 8) {
        actionButtonsRowContent(config)
      }
    } else {
      actionButtonsRowContent(config)
    }
  }

  private func actionButtonsRowContent(_ config: CanvasButtonsConfig) -> some View {
    HStack {
      // Clear button — mounted only when there's something to delete. Hidden
      // entirely in camera mode (hideStrokeButtons). Mount/unmount rather than
      // opacity: inside a `GlassEffectContainer` an opacity-0 child's Liquid
      // Glass capsule still composites and stays visible, so the trash button
      // would never hide on an empty canvas. A clear frame reserves the slot so
      // the row layout never shifts. `leadingExtra` (e.g. camera button)
      // overlays the same slot when the clear button isn't shown.
      ZStack {
        Color.clear
          .frame(width: 44, height: 44)
        if !config.hideStrokeButtons, config.canClear {
          Button(action: {
            if let showConfirmation = config.showClearConfirmation {
              showConfirmation.wrappedValue = true
            } else {
              config.onClear()
            }
          }) {
            Image(systemName: "trash")
          }
          .circularGlassButton(tintColor: .red)
          .transition(.opacity)
        }
        if !config.canClear || config.hideStrokeButtons, let leading = config.leadingExtra {
          leading
            .transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: 0.2), value: config.canClear)
      // Dim + disable while saving (the trailing Save button stays active
      // as the spinner indicator).
      .opacity(isSaving ? 0.35 : 1.0)
      .disabled(isSaving)

      Spacer()

      // Trailing content: in camera mode, prefer a `trailingExtra` override
      // (e.g. album picker button); otherwise show the normal trailing
      // (e.g. Save button).
      if config.hideStrokeButtons {
        if let trailing = config.trailingExtra {
          trailing
        }
      } else if !(TrailingHeaderView() is EmptyView) {
        TrailingHeaderView()
      }

    }
    .overlay {
      // Center content absolutely centered, ignoring left/right widths.
      // Dimmed + disabled while saving, matching the leading slot (the
      // trailing Save button stays active as the spinner indicator).
      Group {
        if !config.hideStrokeButtons,
          config.canUndo || config.canRedo || config.isUndoHistoryLoading
        {
          HStack(spacing: 8) {
            // Undo button
            if let onUndo = config.onUndo {
              Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
              }
              .circularGlassButton(tintColor: .appTextSecondary)
              .disabled(!config.canUndo)
            }

            // Redo button
            if let onRedo = config.onRedo {
              Button(action: onRedo) {
                Image(systemName: "arrow.uturn.forward")
              }
              .circularGlassButton(tintColor: .appTextSecondary)
              .disabled(!config.canRedo)
            }
          }
          .transition(.opacity)
        } else if let centerContent = config.centerContent {
          centerContent
            .transition(.opacity)
        }
      }
      .opacity(isSaving ? 0.35 : 1.0)
      .disabled(isSaving)
    }
  }

  var body: some View {
    VStack(spacing: 16) {
      // Action Buttons Row
      if let config = buttonsConfig {
        // Mounted only once `topButtonsVisible` flips true (after the floating
        // container finishes expanding). The reserved-height frame lives on the
        // wrapper so the layout is stable whether or not the row is mounted —
        // the buttons bounce into the already-reserved slot.
        ZStack {
          if topButtonsVisible {
            actionButtonsRow(config)
              // Plain fade-in for the whole row as the canvas content surfaces.
              .transition(.opacity)
          }
        }
        // Reserve enough height for a circular glass button (40pt + 2pt padding on
        // iOS 26+) so the row keeps the same height whether the leading/trailing
        // glass buttons are visible or only the center content (e.g. camera flip)
        // is shown. Avoids a layout shift on entering/leaving camera mode.
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 12)
        // Springy, lightly-damped curve so the buttons overshoot and settle —
        // a bounce-in as the canvas content surfaces post-expansion. Response is
        // tied to `strokeTraceDuration` (the drawing's fade-in) so the slots and
        // the drawing share one duration and read as a single coherent reveal.
        .animation(.spring(response: strokeTraceDuration, dampingFraction: 0.55), value: topButtonsVisible)
        // Drive the leading/center/trailing transitions with a springy curve.
        // Kept as an implicit `.animation(value:)` rather than baked into the
        // transitions themselves so a `disablesAnimations=true` transaction
        // (e.g. `CameraReferenceContext.reset()` during backgrounding) can
        // override it — baked-in transition animations otherwise leave the
        // glass buttons stranded mid-transition when the app snapshots.
        .animation(.springFkingSatifying, value: isCameraLive)
        // Elevate buttons row above the canvas in z-order so overlays
        // (e.g. TorchlightGlowView on the bulb button) render on top of the canvas.
        .zIndex(1)
      }

      ZStack {
        // Inner content — backdrop, drawing surface, live preview, shutter and
        // inner shadow all share a single rounded-rect clip applied at this
        // container level. Individual layers can overscan their own frames
        // (e.g. the shutter blades) and the container clip handles trimming —
        // no per-layer clipShape/mask needed, and no hairline aliasing along
        // the canvas rim.
        ZStack {
          // Canvas background — switches to black in camera mode so the white
          // drawing surface doesn't bleed through while the live preview fades in.
          Rectangle()
            .fill(isCameraLive ? Color.black : Color.backgroundColor)

          // Tracing-reference backdrop: photo at 30% opacity over a fixed white
          // base so its appearance is identical in light/dark themes (opacity
          // would otherwise blend with the theme-dependent canvas background).
          if !isCameraLive, let backdrop = backdropImage {
            ZStack {
              Color.white
              // Zoom / rotate / translate the reference so the user can position
              // it for tracing. scaleEffect + rotationEffect + offset are pure
              // geometry effects (no layout change), and the container's mask
              // (applied below) clips whatever spills past the square. The
              // rendered scale is the *effective* zoom — the user's zoom plus
              // the auto-cover boost that keeps a rotated photo covering the
              // canvas corners instead of revealing the white base.
              Image(uiImage: backdrop)
                .resizable()
                .scaledToFill()
                .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
                .scaleEffect(
                  PhotoBackdropGeometry.effectiveZoom(zoom: backdropZoom, rotation: backdropRotation)
                )
                .rotationEffect(backdropRotation)
                .offset(backdropOffset)
                .opacity(0.3)
            }
            .allowsHitTesting(false)
          }

        // Drawing area. While `strokeRevealDate` is set (just after the
        // expansion settles) a display-linked TimelineView fades the whole
        // drawing in: opacity 0→1 over `strokeTraceDuration`, every committed
        // path drawn full from the first frame. Once it elapses — or when the
        // wiggle is on / for static callers — it falls back to the normal full
        // render. The stroke-input gesture is attached to the container below so
        // it works identically throughout.
        Group {
          if let strokeRevealDate {
            TimelineView(.animation) { timeline in
              let elapsed = timeline.date.timeIntervalSince(strokeRevealDate)
              let progress = min(max(elapsed / strokeTraceDuration, 0), 1)
              Canvas { context, _ in
                renderCanvasContents(context: &context, wiggleFrame: nil)
              }
              .opacity(progress)
            }
          } else if wiggleEnabled {
            // Periodic clock at the boil rate (~7fps) — the effect only changes
            // state that often, so there's no need to redraw at 60fps.
            TimelineView(.periodic(from: wiggleEpoch, by: WigglyStroke.boilInterval)) { timeline in
              Canvas { context, _ in
                renderCanvasContents(
                  context: &context,
                  wiggleFrame: WigglyStroke.frameIndex(at: timeline.date.timeIntervalSinceReferenceDate)
                )
              }
            }
          } else {
            Canvas { context, _ in
              renderCanvasContents(context: &context, wiggleFrame: nil)
            }
          }
        }
        .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
        .id(placeholderID)
        // Hidden in camera mode.
        .opacity(isCameraLive ? 0 : 1)
        .allowsHitTesting(!isCameraLive)
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              let point = value.location
              let isInBounds =
              point.x >= 0 && point.x <= CANVAS_SIZE && point.y >= 0 && point.y <= CANVAS_SIZE

              if isInBounds {
                // Point is within bounds
                if !isDrawing {
                  // Starting a new stroke
                  isDrawing = true
                  currentPathIsDot = false
                  currentPath.move(to: point)
                  // Track start point and reset max distance
                  gestureStartPoint = point
                  maxDistanceFromStart = 0
                } else {
                  // Continue current stroke
                  currentPath.addLine(to: point)
                  // Update max distance from start point
                  let dx = point.x - gestureStartPoint.x
                  let dy = point.y - gestureStartPoint.y
                  let distance = sqrt(dx * dx + dy * dy)
                  maxDistanceFromStart = max(maxDistanceFromStart, distance)
                }
              } else {
                // Point is out of bounds
                if isDrawing && !currentPath.isEmpty {
                  // Commit the current stroke when going out of bounds
                  onCommitStroke()
                }
              }
            }
            .onEnded { value in
              // Use max distance traveled to determine if this was a tap (dot) or stroke
              // This correctly handles cases where user draws a path returning to start
              let tapThreshold: CGFloat = 3.0
              let isTap = maxDistanceFromStart < tapThreshold

              // Check if this was a single tap (minimal movement throughout gesture)
              if isTap {
                // Create a small circle for the dot
                let point = value.location
                currentPath = Path()
                currentPathIsDot = true
                let dotRadius = DRAWING_LINE_WIDTH / 2
                currentPath.addEllipse(
                  in: CGRect(
                    x: point.x - dotRadius,
                    y: point.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                  ))
              }

              // Commit the stroke
              if isDrawing && !currentPath.isEmpty {
                onCommitStroke()
              }

              // Reset drawing state
              isDrawing = false
              currentPathIsDot = false
              maxDistanceFromStart = 0
            }
        )

        // Live camera preview — only mounted while the shutter is fully closed
        // over the canvas, then latched across the open phase so the feed stays
        // visible once the blades retract.
        #if targetEnvironment(simulator)
        // The simulator has no camera hardware, so the real feed would render
        // black. Show a placeholder while live so the camera-reference flow and
        // onboarding tutorial stay testable.
        if isCameraLive {
          SimulatorCameraPlaceholder(zoomFactor: cameraZoomFactor)
            .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
            .allowsHitTesting(false)
        }
        #else
        if cameraPreviewMounted, !suppressLivePreview, let session = liveCameraSession {
          CameraPreviewView(session: session, device: liveCameraDevice, mirrored: liveCameraMirrored)
            .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
            .allowsHitTesting(false)
        }
        #endif

        // Pinch-to-zoom catcher over the live preview. Only hit-testable while
        // live, so it never interferes with the drawing surface (itself
        // disabled in camera mode). The on-screen zoom slider lives at the
        // screen edge in `ContentView`.
        if isCameraLive {
          Color.clear
            .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
            .contentShape(Rectangle())
            .gesture(cameraZoomMagnifyGesture)
        }

        // Camera shutter — overlays the canvas area regardless of mode so it can
        // close over either the live preview (entry) or the drawing canvas (exit).
        // Overscans past the canvas; the container clip below trims it.
        if let shutterController {
          let shutterOverscan: CGFloat = 2
          CameraShutterView(controller: shutterController)
            .frame(width: CANVAS_SIZE + shutterOverscan * 2, height: CANVAS_SIZE + shutterOverscan * 2)
            .allowsHitTesting(false)
        }

        // Black capture-flash overlay — pulsed 0 → 1 → 0 on each capture so
        // the snap feels instantaneous without any actual shutter animation.
        Color.black
          .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
          .opacity(captureFlashOpacity)
          .allowsHitTesting(false)

        if isCapturing {
          ProgressView()
            .tint(.white)
            .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
            .allowsHitTesting(false)
        }

        // Block input while the dismiss save runs so no stray stroke lands
        // after the save has been kicked off (kept invisible — no dim).
        Color.clear
          .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
          .contentShape(Rectangle())
          .allowsHitTesting(isSaving)

        // Inner shadow hugging the canvas cutout — drawn last so it overlays
        // the shutter blades, giving the rounded-rect rim depth even while
        // the shutter is fully closed. Stroke is drawn at 2× the desired
        // shadow depth so its centerline (peak intensity) lands on the rect
        // edge; the container clip below removes the outer half, leaving a
        // one-directional gradient that fades purely inward.
        RoundedRectangle(cornerRadius: canvasCornerRadius, style: .continuous)
          .stroke(Color.black.opacity(0.7), lineWidth: 8)
          .blur(radius: 4)
          .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
          .opacity((isCameraLive || isShutterCycling) ? 1 : 0)
          .animation(.easeInOut(duration: 0.15), value: isCameraLive || isShutterCycling)
          .allowsHitTesting(false)
        }
        .compositingGroup()
        .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
        .mask(
          RoundedRectangle(cornerRadius: canvasCornerRadius, style: .continuous)
            .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
        )

        // Border drawn on top of the clipped container so it remains visible
        // above the shutter / preview / inner shadow.
        RoundedRectangle(cornerRadius: canvasCornerRadius, style: .continuous)
          .strokeBorder(.borderColor, lineWidth: 1.0)
          .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
          .allowsHitTesting(false)
      }
    }
    .onAppear {
      decodePlaceholder()
      rebuildWiggleSources()
      cameraPreviewMounted = isCameraLive
    }
    .onChange(of: placeholderData) { _, _ in
      decodePlaceholder()
    }
    .onChange(of: paths.count) { _, _ in
      // Keep the wiggle point cache in lockstep with the committed strokes.
      // Strokes are only ever added/removed wholesale (commit/undo/redo/clear/
      // load), so the count is a sufficient — and far cheaper to diff — trigger
      // than deep-comparing the whole `[Path]` array every render.
      rebuildWiggleSources()
    }
    .onChange(of: captureFlashID) { _, newID in
      guard newID != nil else { return }
      withAnimation(.linear(duration: 0.04)) {
        captureFlashOpacity = 1
      }
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 50_000_000)
        withAnimation(.easeOut(duration: 0.22)) {
          captureFlashOpacity = 0
        }
      }
    }
    .onChange(of: isShutterFullyClosed) { _, closed in
      // Latch the preview to the live-mode state on each edge of the shutter
      // being fully closed — that's exactly when the swap behind the blades
      // happens, so mounting/unmounting is invisible.
      if closed {
        cameraPreviewMounted = isCameraLive
      }
    }
    .onChange(of: isCameraLive) { _, live in
      if !live {
        // Always tear the preview down the moment we leave live mode — covers
        // both the in-cycle exit (shutter is closed over it) and out-of-band
        // teardowns like `reset()` triggered by a sheet dismiss.
        cameraPreviewMounted = false
      } else if isShutterFullyClosed {
        cameraPreviewMounted = true
      }
    }
  }

  /// Draw the canvas contents into `context`. When `wiggleFrame` is non-nil the
  /// committed strokes are jittered for that boil frame. The whole-drawing
  /// fade-in reveal is handled by the caller (a TimelineView animating the
  /// `Canvas`'s opacity), so every stroke here is always drawn full.
  private func renderCanvasContents(
    context: inout GraphicsContext,
    wiggleFrame: Int?
  ) {
    // Draw placeholder if empty
    if paths.isEmpty && currentPath.isEmpty && !placeholderPaths.isEmpty {
      for (path, isDot) in placeholderPaths {
        if isDot {
          context.fill(path, with: .color(.gray.opacity(0.2)))
        } else {
          context.stroke(
            path,
            with: .color(.gray.opacity(0.2)),
            style: StrokeStyle(lineWidth: DRAWING_LINE_WIDTH, lineCap: .round, lineJoin: .round)
          )
        }
      }
    }

    // Draw all completed paths. Use the precomputed wiggle points only when the
    // boil is active AND the cache is in sync with `paths` (a freshly committed
    // stroke draws straight for the one frame before `wiggleSources` catches up).
    let boilFrame = wiggleSources.count == paths.count ? wiggleFrame : nil
    for (index, path) in paths.enumerated() {
      let isDot = index < pathMetadata.count ? pathMetadata[index].isDot : false
      let basePath: Path = boilFrame.map {
        WigglyStroke.path(points: wiggleSources[index], isDot: isDot, frame: $0)
      } ?? path

      if isDot {
        context.fill(basePath, with: .color(strokeColor))
      } else {
        context.stroke(
          basePath,
          with: .color(strokeColor),
          style: StrokeStyle(lineWidth: DRAWING_LINE_WIDTH, lineCap: .round, lineJoin: .round)
        )
      }
    }

    // Draw current path being drawn — never wiggled so it tracks the finger.
    if !currentPath.isEmpty {
      if currentPathIsDot {
        context.fill(currentPath, with: .color(strokeColor))
      } else {
        context.stroke(
          currentPath,
          with: .color(strokeColor),
          style: StrokeStyle(lineWidth: DRAWING_LINE_WIDTH, lineCap: .round, lineJoin: .round)
        )
      }
    }
  }

  /// Recompute the wiggle point cache from the committed `paths`. Only runs when
  /// the wiggle is actually enabled — otherwise walking every stroke's points
  /// (`extractPoints`) on the main thread is pure waste, and it used to fire on
  /// every doodle load even with the experimental feature off.
  private func rebuildWiggleSources() {
    guard userPreferences.enableWigglyStrokes else {
      if !wiggleSources.isEmpty { wiggleSources = [] }
      return
    }
    wiggleSources = paths.map { $0.extractPoints() }
  }

  private func decodePlaceholder() {
    guard let data = placeholderData else {
      placeholderPaths = []
      placeholderID = UUID()
      return
    }

    do {
      let decodedPaths = try JSONDecoder().decode([PathData].self, from: data)
      placeholderPaths = decodedPaths.map { pathData in
        var path = Path()
        if pathData.isDot && pathData.points.count >= 1 {
          // Recreate dot as ellipse
          let center = pathData.points[0]
          let dotRadius = DRAWING_LINE_WIDTH / 2
          path.addEllipse(
            in: CGRect(
              x: center.x - dotRadius,
              y: center.y - dotRadius,
              width: dotRadius * 2,
              height: dotRadius * 2
            ))
        } else {
          // Recreate line path
          for (index, point) in pathData.points.enumerated() {
            if index == 0 {
              path.move(to: point)
            } else {
              path.addLine(to: point)
            }
          }
        }
        return (path, pathData.isDot)
      }
      placeholderID = UUID()
    } catch {
      print("Failed to decode placeholder data: \(error)")
      placeholderPaths = []
      placeholderID = UUID()
    }
  }
}

// Extension to support initialization without trailing header
extension SharedCanvasView where TrailingHeader == EmptyView {
  init(
    paths: Binding<[Path]>,
    pathMetadata: Binding<[PathMetadata]>,
    currentPath: Binding<Path>,
    currentPathIsDot: Binding<Bool>,
    isDrawing: Binding<Bool>,
    placeholderData: Data? = nil,
    buttonsConfig: CanvasButtonsConfig? = nil,
    canvasCornerRadius: CGFloat = 32,
    onCommitStroke: @escaping () -> Void
  ) {
    self.init(
      paths: paths,
      pathMetadata: pathMetadata,
      currentPath: currentPath,
      currentPathIsDot: currentPathIsDot,
      isDrawing: isDrawing,
      placeholderData: placeholderData,
      buttonsConfig: buttonsConfig,
      canvasCornerRadius: canvasCornerRadius,
      onCommitStroke: onCommitStroke,
      trailingHeader: { EmptyView() }
    )
  }
}

// MARK: - Previews

#Preview("Empty Canvas - No Buttons") {
  StatefulPreviewWrapperForSharedCanvas(
    paths: [Path](),
    pathMetadata: [PathMetadata](),
    currentPath: Path(),
    currentPathIsDot: false,
    isDrawing: false
  ) { paths, pathMetadata, currentPath, currentPathIsDot, isDrawing in
    SharedCanvasView(
      paths: paths,
      pathMetadata: pathMetadata,
      currentPath: currentPath,
      currentPathIsDot: currentPathIsDot,
      isDrawing: isDrawing,
      onCommitStroke: {}
    )
    .padding()
    .background(Color(uiColor: .systemBackground))
  }
}

#Preview("With Content - Clear Button Only") {
  let samplePaths = createSamplePaths()

  StatefulPreviewWrapperForSharedCanvas(
    paths: samplePaths.0,
    pathMetadata: samplePaths.1,
    currentPath: Path(),
    currentPathIsDot: false,
    isDrawing: false
  ) { paths, pathMetadata, currentPath, currentPathIsDot, isDrawing in
    SharedCanvasView(
      paths: paths,
      pathMetadata: pathMetadata,
      currentPath: currentPath,
      currentPathIsDot: currentPathIsDot,
      isDrawing: isDrawing,
      buttonsConfig: CanvasButtonsConfig(
        onClear: {
          paths.wrappedValue.removeAll()
          pathMetadata.wrappedValue.removeAll()
        },
        canClear: !paths.wrappedValue.isEmpty
      ),
      onCommitStroke: {}
    )
    .padding()
    .background(Color(uiColor: .systemBackground))
  }
}

#Preview("With Undo/Redo Buttons") {
  let samplePaths = createSamplePaths()

  StatefulPreviewWrapperWithUndo(
    paths: samplePaths.0,
    pathMetadata: samplePaths.1
  ) { paths, pathMetadata, currentPath, currentPathIsDot, isDrawing, undoStack, redoStack in
    SharedCanvasView(
      paths: paths,
      pathMetadata: pathMetadata,
      currentPath: currentPath,
      currentPathIsDot: currentPathIsDot,
      isDrawing: isDrawing,
      buttonsConfig: CanvasButtonsConfig(
        onClear: {
          paths.wrappedValue.removeAll()
          pathMetadata.wrappedValue.removeAll()
        },
        onUndo: {
          guard !undoStack.wrappedValue.isEmpty else { return }
          redoStack.wrappedValue.append((paths.wrappedValue, pathMetadata.wrappedValue))
          let (previousPaths, previousMetadata) = undoStack.wrappedValue.removeLast()
          paths.wrappedValue = previousPaths
          pathMetadata.wrappedValue = previousMetadata
        },
        onRedo: {
          guard !redoStack.wrappedValue.isEmpty else { return }
          undoStack.wrappedValue.append((paths.wrappedValue, pathMetadata.wrappedValue))
          let (redoPaths, redoMetadata) = redoStack.wrappedValue.removeLast()
          paths.wrappedValue = redoPaths
          pathMetadata.wrappedValue = redoMetadata
        },
        canClear: !paths.wrappedValue.isEmpty,
        canUndo: !undoStack.wrappedValue.isEmpty,
        canRedo: !redoStack.wrappedValue.isEmpty
      ),
      onCommitStroke: {}
    )
    .padding()
    .background(Color(uiColor: .systemBackground))
  }
}

#Preview("With Undo/Redo Buttons and Save Button") {
  let samplePaths = createSamplePaths()

  StatefulPreviewWrapperWithUndo(
    paths: samplePaths.0,
    pathMetadata: samplePaths.1
  ) { paths, pathMetadata, currentPath, currentPathIsDot, isDrawing, undoStack, redoStack in
    SharedCanvasView(
      paths: paths,
      pathMetadata: pathMetadata,
      currentPath: currentPath,
      currentPathIsDot: currentPathIsDot,
      isDrawing: isDrawing,
      buttonsConfig: CanvasButtonsConfig(
        onClear: {
          paths.wrappedValue.removeAll()
          pathMetadata.wrappedValue.removeAll()
        },
        onUndo: {
          guard !undoStack.wrappedValue.isEmpty else { return }
          redoStack.wrappedValue.append((paths.wrappedValue, pathMetadata.wrappedValue))
          let (previousPaths, previousMetadata) = undoStack.wrappedValue.removeLast()
          paths.wrappedValue = previousPaths
          pathMetadata.wrappedValue = previousMetadata
        },
        onRedo: {
          guard !redoStack.wrappedValue.isEmpty else { return }
          undoStack.wrappedValue.append((paths.wrappedValue, pathMetadata.wrappedValue))
          let (redoPaths, redoMetadata) = redoStack.wrappedValue.removeLast()
          paths.wrappedValue = redoPaths
          pathMetadata.wrappedValue = redoMetadata
        },
        canClear: !paths.wrappedValue.isEmpty,
        canUndo: !undoStack.wrappedValue.isEmpty,
        canRedo: !redoStack.wrappedValue.isEmpty
      ),
      onCommitStroke: {}
    ) {
      // Save button
      Button(action: {}) {
        Image(systemName: "checkmark")
      }
      .circularGlassButton()
    }
    .padding()
    .background(Color(uiColor: .systemBackground))
  }
}

#Preview("With Placeholder") {
  let placeholder = createPlaceholderData()

  StatefulPreviewWrapperForSharedCanvas(
    paths: [Path](),
    pathMetadata: [PathMetadata](),
    currentPath: Path(),
    currentPathIsDot: false,
    isDrawing: false
  ) { paths, pathMetadata, currentPath, currentPathIsDot, isDrawing in
    SharedCanvasView(
      paths: paths,
      pathMetadata: pathMetadata,
      currentPath: currentPath,
      currentPathIsDot: currentPathIsDot,
      isDrawing: isDrawing,
      placeholderData: placeholder,
      buttonsConfig: CanvasButtonsConfig(
        onClear: {
          paths.wrappedValue.removeAll()
          pathMetadata.wrappedValue.removeAll()
        },
        canClear: !paths.wrappedValue.isEmpty
      ),
      onCommitStroke: {}
    )
    .padding()
    .background(Color(uiColor: .systemBackground))
  }
}

// MARK: - Preview Helpers

private func createSamplePaths() -> ([Path], [PathMetadata]) {
  var paths: [Path] = []
  var metadata: [PathMetadata] = []

  // Create a simple line path
  var path1 = Path()
  path1.move(to: CGPoint(x: 50, y: 50))
  path1.addLine(to: CGPoint(x: 150, y: 100))
  path1.addLine(to: CGPoint(x: 100, y: 150))
  paths.append(path1)
  metadata.append(PathMetadata(isDot: false))

  // Create a dot path
  var path2 = Path()
  let dotRadius = DRAWING_LINE_WIDTH / 2
  path2.addEllipse(
    in: CGRect(
      x: 200 - dotRadius,
      y: 80 - dotRadius,
      width: dotRadius * 2,
      height: dotRadius * 2
    ))
  paths.append(path2)
  metadata.append(PathMetadata(isDot: true))

  // Create another line path
  var path3 = Path()
  path3.move(to: CGPoint(x: 180, y: 180))
  path3.addLine(to: CGPoint(x: 220, y: 200))
  paths.append(path3)
  metadata.append(PathMetadata(isDot: false))

  return (paths, metadata)
}

private func createPlaceholderData() -> Data? {
  let samplePaths: [PathData] = [
    PathData(
      points: [
        CGPoint(x: 100, y: 100),
        CGPoint(x: 200, y: 150),
        CGPoint(x: 150, y: 200)
      ],
      isDot: false
    ),
    PathData(
      points: [CGPoint(x: 250, y: 120)],
      isDot: true
    )
  ]
  return try? JSONEncoder().encode(samplePaths)
}

// MARK: - Preview Wrapper Utilities
private struct StatefulPreviewWrapperForSharedCanvas<Content: View>: View {
  @State private var paths: [Path]
  @State private var pathMetadata: [PathMetadata]
  @State private var currentPath: Path
  @State private var currentPathIsDot: Bool
  @State private var isDrawing: Bool

  let content: (
    Binding<[Path]>,
    Binding<[PathMetadata]>,
    Binding<Path>,
    Binding<Bool>,
    Binding<Bool>
  ) -> Content

  init(
    paths: [Path],
    pathMetadata: [PathMetadata],
    currentPath: Path,
    currentPathIsDot: Bool,
    isDrawing: Bool,
    @ViewBuilder content: @escaping (
      Binding<[Path]>,
      Binding<[PathMetadata]>,
      Binding<Path>,
      Binding<Bool>,
      Binding<Bool>
    ) -> Content
  ) {
    _paths = State(wrappedValue: paths)
    _pathMetadata = State(wrappedValue: pathMetadata)
    _currentPath = State(wrappedValue: currentPath)
    _currentPathIsDot = State(wrappedValue: currentPathIsDot)
    _isDrawing = State(wrappedValue: isDrawing)
    self.content = content
  }

  var body: some View {
    content($paths, $pathMetadata, $currentPath, $currentPathIsDot, $isDrawing)
  }
}

private struct StatefulPreviewWrapperWithUndo<Content: View>: View {
  @State private var paths: [Path]
  @State private var pathMetadata: [PathMetadata]
  @State private var currentPath: Path = Path()
  @State private var currentPathIsDot: Bool = false
  @State private var isDrawing: Bool = false
  @State private var undoStack: [([Path], [PathMetadata])] = []
  @State private var redoStack: [([Path], [PathMetadata])] = []

  let content: (
    Binding<[Path]>,
    Binding<[PathMetadata]>,
    Binding<Path>,
    Binding<Bool>,
    Binding<Bool>,
    Binding<[([Path], [PathMetadata])]>,
    Binding<[([Path], [PathMetadata])]>
  ) -> Content

  init(
    paths: [Path],
    pathMetadata: [PathMetadata],
    @ViewBuilder content: @escaping (
      Binding<[Path]>,
      Binding<[PathMetadata]>,
      Binding<Path>,
      Binding<Bool>,
      Binding<Bool>,
      Binding<[([Path], [PathMetadata])]>,
      Binding<[([Path], [PathMetadata])]>
    ) -> Content
  ) {
    _paths = State(wrappedValue: paths)
    _pathMetadata = State(wrappedValue: pathMetadata)
    // Initialize with one item in undo stack for demo
    _undoStack = State(wrappedValue: [(paths, pathMetadata)])
    self.content = content
  }

  var body: some View {
    content($paths, $pathMetadata, $currentPath, $currentPathIsDot, $isDrawing, $undoStack, $redoStack)
  }
}

#if targetEnvironment(simulator)
/// Stand-in for the live camera feed on the simulator, which has no camera
/// hardware. Shows a fixed reference photo scaled by the current zoom so the
/// zoom slider visibly magnifies the "feed", keeping the camera-reference flow
/// and onboarding tutorial testable without rendering a black frame.
private struct SimulatorCameraPlaceholder: View {
  var zoomFactor: CGFloat

  var body: some View {
    // At the minimum zoom the photo fills the square (its center crop); higher
    // zoom magnifies around center, matching what `capture()` crops out.
    let minZoom = CameraReferenceContext.simulatorZoomCapabilities.minDisplayZoom
    Image("SimulatorCameraReference")
      .resizable()
      .scaledToFill()
      .scaleEffect(zoomFactor / minZoom)
      .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
      .clipped()
  }
}
#endif
