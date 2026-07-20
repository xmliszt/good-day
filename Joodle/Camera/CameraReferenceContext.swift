//
//  CameraReferenceContext.swift
//  Joodle
//
//  Shared camera state owned by ContentView and consumed by both DrawingCanvasView
//  (for the in-canvas live preview, top-row controls, in-sheet shutter on non-DI)
//  and ContentView itself (for the fullscreen blurred backdrop and the DI shutter
//  overlay rendered outside the drawing container).
//

@preconcurrency import AVFoundation
import Combine
import SwiftUI
import UIKit

enum CameraReferenceMode: Equatable {
  case idle
  case live
}

/// Pure geometry for positioning the tracing-reference photo. The photo is a
/// square drawn `scaledToFill` into the `CANVAS_SIZE` square, then
/// `scaleEffect` → `rotationEffect` → `offset` (offset applies in screen
/// space). A caseless enum of free functions — not actor-isolated like
/// `CameraReferenceContext` — so the math is directly unit-testable.
enum PhotoBackdropGeometry {
  /// Minimum scale at which a square photo rotated by `rotation` still fully
  /// covers the square canvas: `|cos θ| + |sin θ|` (1 at 0°/90°, √2 at 45°).
  static func coverZoom(rotation: Angle) -> CGFloat {
    let theta = rotation.radians
    return CGFloat(abs(cos(theta)) + abs(sin(theta)))
  }

  /// Scale actually rendered: the user's zoom, boosted just enough that a
  /// rotated photo never reveals the white base at the canvas corners.
  /// Render-time only — the user's zoom is never mutated, so rotating back
  /// relaxes the boost.
  static func effectiveZoom(zoom: CGFloat, rotation: Angle) -> CGFloat {
    max(zoom, coverZoom(rotation: rotation))
  }

  /// Largest symmetric per-axis translation (canvas points) that keeps the
  /// scaled + rotated photo covering the whole canvas square, i.e. up to the
  /// photo's own edges. Zero whenever the photo only just covers (1× zoom at
  /// any rotation); `(canvasSize/2)·(zoom − 1)` when unrotated.
  static func translationRange(
    zoom: CGFloat, rotation: Angle, canvasSize: CGFloat = CANVAS_SIZE
  ) -> CGFloat {
    let cover = coverZoom(rotation: rotation)
    let effective = effectiveZoom(zoom: zoom, rotation: rotation)
    return canvasSize / 2 * max(0, effective / cover - 1)
  }
}

@MainActor
final class CameraReferenceContext: ObservableObject {
  @Published var mode: CameraReferenceMode = .idle
  @Published var backdropImage: UIImage? = nil
  /// Zoom applied to the captured tracing-reference photo (`backdropImage`) — the
  /// 1.0-based scale the photo-zoom slider drives once a reference is placed.
  /// Independent of `displayZoomFactor` (the live-camera optical zoom).
  @Published var backdropZoom: CGFloat = 1.0
  /// Translation applied to the reference photo, in canvas points. Driven by the
  /// 2-axis scrub pad so the user can nudge the reference left/right/up/down.
  @Published var backdropOffset: CGSize = .zero
  /// Rotation applied to the reference photo. Driven by the rotation arc.
  @Published var backdropRotation: Angle = .zero
  @Published var showPermissionDeniedAlert: Bool = false
  /// Set when a capture couldn't be saved to the album because Photos add-only
  /// access was denied. Views observing the context surface a one-shot message
  /// pointing the user to the in-app toggle to re-enable saving.
  @Published var showSaveToAlbumDeniedMessage: Bool = false
  /// Mirrors the controller's session-running state so views observing this
  /// context can show a "Turning on camera..." placeholder while the session
  /// is still spinning up.
  @Published var isSessionRunning: Bool = false
  /// Mirror of `controller.currentDevice` so views observing the context
  /// re-render whenever the active capture device changes (e.g. flip).
  @Published var currentDevice: AVCaptureDevice?
  /// Mirror of `controller.zoomCapabilities` — drives the zoom slider's range,
  /// key ticks, and whether it's shown at all.
  @Published var zoomCapabilities: CameraZoomCapabilities = .disabled
  /// Mirror of `controller.displayZoomFactor` — the 0.5/1/2/3 shown to the user.
  @Published var displayZoomFactor: CGFloat = 1.0
  /// Mirror of `controller.systemControlsActive` — true while the iPhone 16
  /// Camera Control system overlay is up, so the app hides its own zoom slider.
  @Published var systemControlsActive: Bool = false
  /// Mirror of `shutter.isFullyClosed`. Republished here so views observing
  /// the context (rather than the nested controller directly) re-render when
  /// the shutter reaches the fully-closed state.
  @Published private(set) var isShutterFullyClosed: Bool = false
  /// Mirror of `shutter.isCycling`. Republished for the same reason — used to
  /// disable camera-affecting buttons for the entire close → open sequence.
  @Published private(set) var isShutterCycling: Bool = false
  /// When true, parents should unmount the live preview entirely. Used during
  /// a flip cycle to prevent the old device's last frame from lingering on
  /// the shared preview layer while the session swaps inputs, and during
  /// `.inactive` scene-phase transitions so the iOS snapshot doesn't capture
  /// a live AVCaptureVideoPreviewLayer (which then takes a long time to
  /// reconcile on return to foreground).
  @Published var suppressPreview: Bool = false
  /// Bumped on every photo capture. Consumers observe this to trigger a brief
  /// black-flash overlay — fakes a "shutter snap" so the capture feels
  /// instantaneous, without the latency cost of an actual shutter animation.
  @Published var captureFlashID: UUID? = nil
  /// True from the moment the shutter is tapped until the backdrop image is
  /// ready. Views show a spinner during this window.
  @Published var isCapturing: Bool = false

  #if DEBUG
  /// Debug-only override: when true, the camera behaves as if the user denied
  /// permission — `enterLive()` surfaces the permission-denied alert and
  /// `isCameraAccessBlocked` reports true. Lets us exercise the denial / skip
  /// paths even on the simulator (where the camera is otherwise faked) or on a
  /// device without re-denying in system Settings. In-memory only (resets on
  /// launch), mirroring `AppEnvironment.simulateProductionEnvironment`.
  /// Toggled from Settings → Developer Options.
  static var debugSimulateCameraDenied = false
  #endif

  let controller: CameraReferenceController
  /// Drives the shutter overlay; every camera-mode transition is bracketed by
  /// a shutter cycle so the swap happens behind closed blades.
  let shutter = CameraShutterController()
  private var cancellables: Set<AnyCancellable> = []

  init() {
    let controller = CameraReferenceController()
    self.controller = controller
    controller.$isRunning
      .receive(on: DispatchQueue.main)
      .assign(to: &$isSessionRunning)
    controller.$currentDevice
      .receive(on: DispatchQueue.main)
      .assign(to: &$currentDevice)
    controller.$zoomCapabilities
      .receive(on: DispatchQueue.main)
      .assign(to: &$zoomCapabilities)
    controller.$displayZoomFactor
      .receive(on: DispatchQueue.main)
      .assign(to: &$displayZoomFactor)
    controller.$systemControlsActive
      .receive(on: DispatchQueue.main)
      .assign(to: &$systemControlsActive)
    shutter.$isFullyClosed
      .receive(on: DispatchQueue.main)
      .assign(to: &$isShutterFullyClosed)
    shutter.$isCycling
      .receive(on: DispatchQueue.main)
      .assign(to: &$isShutterCycling)
  }

  var session: AVCaptureSession { controller.session }
  var isFrontFacing: Bool { controller.position == .front }

  /// True when camera access has been explicitly denied or restricted, so
  /// entering live mode is impossible. Callers (e.g. the tutorial) use this to
  /// avoid re-invoking `enterLive()` — which would just re-trigger the
  /// permission-denied alert — and route around the camera flow instead.
  var isCameraAccessBlocked: Bool {
    #if DEBUG
    if Self.debugSimulateCameraDenied { return true }
    #endif
    // Real authorization status — valid on the simulator too, which tracks
    // camera permission even though it has no hardware.
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .denied, .restricted:
      return true
    default:
      return false
    }
  }

  func enterLive() async {
    #if DEBUG
    // Debug switch to exercise the permission-denied path on demand. Checked
    // before the real flow so it works in either build.
    if Self.debugSimulateCameraDenied {
      showPermissionDeniedAlert = true
      return
    }
    #endif

    // Real camera permission request. This runs on the simulator too — it
    // tracks camera authorization (and shows the system prompt) even without
    // hardware — so the grant/deny flow is testable everywhere. Only the
    // session *start* below has to be faked on the simulator.
    let granted: Bool = await {
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized:
        return true
      case .notDetermined:
        let ok = await AVCaptureDevice.requestAccess(for: .video)
        controller.permissionState = ok ? .granted : .denied
        return ok
      case .denied, .restricted:
        return false
      @unknown default:
        return false
      }
    }()
    guard granted else {
      showPermissionDeniedAlert = true
      return
    }

    #if targetEnvironment(simulator)
    // The simulator has no camera hardware: starting a real session would never
    // produce frames and `waitUntilSessionRunning()` would hang forever. Fake a
    // live session so the camera-reference UI and onboarding tutorial stay
    // testable; SharedCanvasView shows a placeholder in place of the live feed.
    shutter.cycle {
      try? await Task.sleep(nanoseconds: 120_000_000)
      if Task.isCancelled { return }
      // No camera hardware means no real zoom capabilities, so the zoom slider
      // would stay hidden. Publish a representative range and reset the factor
      // so the slider is reachable and draggable for UI debugging.
      self.zoomCapabilities = Self.simulatorZoomCapabilities
      self.displayZoomFactor = 1.0
      withAnimation(.easeInOut(duration: 0.2)) { self.mode = .live }
    }
    #else
    shutter.cycle {
      // Give SwiftUI a beat to finish the close animation before we kick off
      // the heavy mode-flip + session-start work — otherwise that work
      // crashes into the tail of the close and the last few blade frames
      // stutter.
      try? await Task.sleep(nanoseconds: 120_000_000)
      // `reset()` (e.g. canvas dismissed mid-cycle) cancels the cycle's Task.
      // `try?` swallows the cancellation, so without this guard we'd fall
      // through and flip `mode` back to `.live` after `reset()` set it to
      // `.idle`, wedging the next canvas-open in camera UI.
      if Task.isCancelled { return }
      withAnimation(.easeInOut(duration: 0.2)) { self.mode = .live }
      await self.controller.start()
      if Task.isCancelled { return }
      // Block the open until the session has actually started producing frames,
      // otherwise the shutter would reveal a black preview surface.
      if !self.isSessionRunning {
        await self.waitUntilSessionRunning()
      }
    }
    #endif
  }

  func cancelLive() {
    shutter.cycle {
      self.controller.stop()
      withAnimation(.easeInOut(duration: 0.2)) { self.mode = .idle }
      try? await Task.sleep(nanoseconds: 300_000_000)
    }
  }

  func flip() {
    #if targetEnvironment(simulator)
    // No camera hardware to reconfigure: `controller.flip()` would fail to bind a
    // new input and publish `.disabled` capabilities, hiding the zoom slider. Just
    // run the shutter animation and re-assert the fake range so the slider stays.
    shutter.cycle {
      try? await Task.sleep(nanoseconds: 96_000_000)
      if Task.isCancelled { return }
      self.zoomCapabilities = Self.simulatorZoomCapabilities
      self.displayZoomFactor = 1.0
    }
    #else
    shutter.cycle {
      // Tear the preview down before reconfiguring so the previous device's
      // last frame isn't held on the layer while the session swaps inputs.
      self.suppressPreview = true
      try? await Task.sleep(nanoseconds: 16_000_000)
      if Task.isCancelled { return }
      // Arm the notification observer BEFORE asking the controller to flip,
      // so we don't miss the post on fast reconfigures.
      let configChanged = self.awaitNextSessionConfigurationChange()
      self.controller.flip()
      // Wait for the controller's commitConfiguration to post
      // cameraSessionConfigurationDidChange — exact signal that the new device
      // is bound to the session — rather than a fixed sleep that's too short
      // on cold front-camera spin-up and wastefully long otherwise. The helper
      // caps the wait at 600ms so a missed notification can't hang the cycle.
      await configChanged.value
      if Task.isCancelled { return }
      self.suppressPreview = false
      // Tiny dwell so the remounted preview layer has actually drawn a new
      // frame before the shutter starts opening.
      try? await Task.sleep(nanoseconds: 80_000_000)
    }
    #endif
  }

  /// Display-zoom range the reference-photo zoom slider spans (magnify only — the
  /// photo already fills the square at 1.0, so zooming below would reveal the
  /// white base).
  static let photoZoomRange: ClosedRange<CGFloat> = 1...4
  /// Key detents the photo-zoom slider marks as major ticks.
  static let photoZoomKeyFactors: [CGFloat] = [1, 2, 3]

  /// Render-time zoom for the reference photo — the user's zoom plus the
  /// auto-cover boost that keeps a rotated photo covering the canvas corners.
  var backdropEffectiveZoom: CGFloat {
    PhotoBackdropGeometry.effectiveZoom(zoom: backdropZoom, rotation: backdropRotation)
  }

  /// Per-axis translation bound for the current zoom/rotation — how far the
  /// photo can be nudged before its edge would cross into the canvas.
  var backdropTranslationRange: CGFloat {
    PhotoBackdropGeometry.translationRange(zoom: backdropZoom, rotation: backdropRotation)
  }

  /// Clamps and stores the reference-photo zoom (the slider's `onChange` target).
  func setBackdropZoom(_ zoom: CGFloat) {
    backdropZoom = min(max(zoom, Self.photoZoomRange.lowerBound), Self.photoZoomRange.upperBound)
    clampBackdropOffset()
  }

  /// Stores the reference-photo rotation (the dial's `onChange` target).
  func setBackdropRotation(_ rotation: Angle) {
    backdropRotation = rotation
    clampBackdropOffset()
  }

  /// Re-clamps the offset into the current translation bound. Zooming out or
  /// rotating shrinks the bound, so an offset set earlier could otherwise
  /// leave the photo revealing the white base past its edge.
  private func clampBackdropOffset() {
    let range = backdropTranslationRange
    let clamped = CGSize(
      width: min(max(backdropOffset.width, -range), range),
      height: min(max(backdropOffset.height, -range), range)
    )
    if clamped != backdropOffset {
      backdropOffset = clamped
    }
  }

  /// Recenters the reference photo — 1.0 zoom, no offset, no rotation. Called
  /// whenever a fresh reference is installed so each capture/import starts clean.
  func resetBackdropTransform() {
    backdropZoom = 1.0
    backdropOffset = .zero
    backdropRotation = .zero
  }

  func setZoom(_ display: CGFloat) {
    #if targetEnvironment(simulator)
    // No device to drive, so reflect the slider's value directly.
    displayZoomFactor = min(max(display, zoomCapabilities.minDisplayZoom), zoomCapabilities.maxDisplayZoom)
    #else
    controller.setDisplayZoom(display)
    #endif
  }

  func capture() async {
    guard mode == .live else { return }
    captureFlashID = UUID()
    #if targetEnvironment(simulator)
    // No camera to capture from — synthesize a placeholder reference photo so
    // the "trace over your reference" step is reachable on the simulator.
    isCapturing = true
    resetBackdropTransform()
    self.backdropImage = Self.makeSimulatorPlaceholderImage(zoom: displayZoomFactor)
    isCapturing = false
    withAnimation(.easeInOut(duration: 0.2)) { self.mode = .idle }
    #else
    // Render the latest live frame ONCE — off the main thread — into a square
    // image used for both the tracing backdrop and (optionally) the saved
    // polaroid, so a full-resolution back-camera frame is never run through
    // Core Image twice. When save-to-album is on we render at the polaroid's
    // 2048px (the backdrop happily uses the same image); otherwise the 1024px
    // the backdrop needs on its own is enough. The frame buffer is grabbed
    // synchronously inside latestSquareFrame() (so it survives the stop()
    // below); awaiting the render keeps the shutter tap from blocking the UI —
    // this stall used to be on-main and was badly visible on the back camera.
    // `isCapturing` drives a spinner over the capture flash so a slow render
    // still shows visual feedback rather than a frozen-looking UI.
    let shouldSave = UserPreferences.shared.saveCapturedPhotoToAlbum
    isCapturing = true
    let rendered = await controller.latestSquareFrame(maxPixelDimension: shouldSave ? 2048 : 1024)
    if let rendered {
      resetBackdropTransform()
      self.backdropImage = rendered.backdrop
    }
    isCapturing = false
    // Saving a filtered polaroid is a pure background job that must never gate
    // the backdrop appearing — it reuses the square already rendered above. The
    // toggle is the single source of truth: ON means "ensure access" — so the
    // save path requests add-only permission, prompting the first time (even
    // when no frame was captured, `square` is nil but the request still fires).
    // If access is denied, the save is impossible, so flip the toggle OFF to
    // record the user's deliberate choice (no future prompts) and surface a
    // one-shot message.
    if shouldSave {
      controller.savePolaroid(from: rendered?.square) { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          UserPreferences.shared.saveCapturedPhotoToAlbum = false
          self.showSaveToAlbumDeniedMessage = true
        }
      }
    }
    self.controller.stop()
    withAnimation(.easeInOut(duration: 0.2)) { self.mode = .idle }
    #endif
  }

  #if targetEnvironment(simulator)
  /// Stand-in zoom range for the simulator, modelled on an ultra-wide-equipped
  /// back camera (0.5x–10x with 0.5/1/2 lens stops), so the zoom slider can be
  /// exercised without camera hardware.
  static let simulatorZoomCapabilities = CameraZoomCapabilities(
    minDisplayZoom: 0.5,
    maxDisplayZoom: 10,
    baselineFactor: 1,
    keyZoomFactors: [0.5, 1, 2]
  )

  /// Crops the simulator reference photo to the centered square the live
  /// preview is currently showing at `zoom`, so a simulator capture yields the
  /// same framing the user sees. Mirrors `SimulatorCameraPlaceholder`: the
  /// square shrinks (magnifying the center) as zoom climbs above the minimum.
  static func makeSimulatorPlaceholderImage(zoom: CGFloat) -> UIImage {
    guard let source = UIImage(named: "SimulatorCameraReference"),
          let cgImage = source.cgImage else {
      return UIImage()
    }
    let width = CGFloat(cgImage.width)
    let height = CGFloat(cgImage.height)
    let shortSide = min(width, height)
    let minZoom = simulatorZoomCapabilities.minDisplayZoom
    let cropSide = min(shortSide, shortSide * minZoom / max(zoom, minZoom))
    let cropRect = CGRect(
      x: (width - cropSide) / 2,
      y: (height - cropSide) / 2,
      width: cropSide,
      height: cropSide
    )
    guard let cropped = cgImage.cropping(to: cropRect) else { return source }
    return UIImage(cgImage: cropped, scale: source.scale, orientation: source.imageOrientation)
  }
  #endif

  /// Returns a Task that completes the next time the camera controller posts
  /// `cameraSessionConfigurationDidChange`, or after a 600ms safety cap if
  /// the notification is missed.
  private func awaitNextSessionConfigurationChange() -> Task<Void, Never> {
    Task {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          // Filter by name only — AVCaptureSession isn't Sendable, so passing
          // it as the `object` filter into a detached Task is a concurrency
          // warning. The camera controller is the sole poster of this
          // notification, so a name-only filter is unambiguous.
          let stream = NotificationCenter.default.notifications(
            named: .cameraSessionConfigurationDidChange
          )
          for await _ in stream { return }
        }
        group.addTask {
          try? await Task.sleep(nanoseconds: 600_000_000)
        }
        _ = await group.next()
        group.cancelAll()
      }
    }
  }

  /// Fully reset — called when drawing canvas dismisses or the app backgrounds.
  /// Wraps state mutations in a no-animation transaction so the implicit
  /// `.animation(value: isCameraLive)` in DrawingCanvasView doesn't kick off
  /// an interpolation that gets stranded mid-frame (e.g. when the app is
  /// suspended and resumed, buttons can end up rendered at an intermediate
  /// transition state).
  func reset() {
    controller.stop()
    var tx = Transaction()
    tx.disablesAnimations = true
    withTransaction(tx) {
      mode = .idle
      backdropImage = nil
      backdropZoom = 1.0
      backdropOffset = .zero
      backdropRotation = .zero
      suppressPreview = false
      isCapturing = false
    }
    shutter.forceReset()
  }

  private func waitUntilSessionRunning() async {
    for await running in $isSessionRunning.values where running {
      return
    }
  }
}
