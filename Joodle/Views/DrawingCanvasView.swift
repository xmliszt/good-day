//
//  DrawingCanvasView.swift
//  Joodle
//
//  Created by Li Yuxuan on 10/8/25.
//

import PhotosUI
import SwiftData
import SwiftUI
import UIKit

// MARK: - Joodle Access State

enum JoodleAccessState {
  case canCreate
  case canEdit
  case limitReached
  case editingLocked(reason: String)
}

// MARK: - Drawing Canvas View with Thumbnail Generation

struct DrawingCanvasView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var subscriptionManager = SubscriptionManager.shared

  let date: Date
  let entry: DayEntry?
  /// Which doodle slot within `entry` this canvas edits. `entry.doodleCount`
  /// (i.e. one past the last existing doodle) means "create a new doodle".
  var doodleIndex: Int = 0
  let onDismiss: () -> Void
  /// We need this external state as DrawingCanvasView is rendered when an entry is selected
  /// But that doesn't make it visible yet as controlled by DynamicIslandExpandedView
  let isShowing: Bool

  /// Set true by the parent (e.g. tap-outside) to request a save + dismiss.
  /// The canvas runs its saving-state flow, persists, then calls `onDismiss`
  /// to drive the collapse. Reset to false by the canvas once the flow starts.
  var saveDismissTrigger: Binding<Bool> = .constant(false)

  /// Optional mock store for tutorial mode - when provided, uses mock data instead of real database
  var mockStore: MockDataStore?

  /// Optional mock entry for tutorial mode - used when mockStore is provided
  var mockEntry: MockDayEntry?

  @State private var currentPath = Path()
  @State private var paths: [Path] = []
  @State private var pathMetadata: [PathMetadata] = []
  @State private var currentPathIsDot = false
  @State private var showClearConfirmation = false
  @State private var isDrawing = false
  @State private var showPaywall = false
  @State private var showTrialClaim = false
  @State private var accessState: JoodleAccessState = .canCreate
  @StateObject private var trialOfferManager = TrialOfferManager.shared

  // Undo/Redo state management
  @State private var undoStack: [([Path], [PathMetadata])] = []
  @State private var redoStack: [([Path], [PathMetadata])] = []

  /// Task for async thumbnail generation on dismiss
  @State private var thumbnailTask: Task<Void, Never>?

  /// Short-lived background task used when persisting drawing data during app backgrounding.
  @State private var backgroundSaveTaskId: UIBackgroundTaskIdentifier = .invalid

  /// Tracks whether the drawing was already persisted during this dismiss cycle.
  /// Prevents `.onDisappear` from double-saving after `onChange(of: isShowing)` or `runSaveFlow()` already saved.
  @State private var didSaveOnDismiss = false

  /// Whether `loadExistingDrawing()` has run for the current session.
  /// Guards save operations so a hidden canvas that was never loaded
  /// (e.g. DI device entry-switch) cannot overwrite another entry's doodle data.
  @State private var drawingStateLoaded = false

  /// Monotonic token invalidating in-flight async drawing loads. Bumped when a
  /// new load starts and when the post-dismiss state clear runs, so a decode
  /// that lands after the canvas moved on is dropped instead of applied.
  @State private var loadGeneration = 0

  /// True from the moment an existing doodle starts loading until its undo
  /// history (built after the open animation settles) is ready. Drives the
  /// optimistic — disabled — undo/redo buttons so they're present from the
  /// first frame instead of popping in half a second later.
  @State private var undoHistoryPending = false

  /// Monotonic token used to defer the post-dismiss in-memory state reset until
  /// after the collapse animation finishes. Bumped on every show/hide transition
  /// so a pending deferred reset is invalidated if the canvas reopens first.
  @State private var dismissResetGeneration = 0

  /// True while the dismiss save flow is running: the checkmark becomes a
  /// spinner, the top-row buttons dim/disable, and the canvas dims — an
  /// intentional "saving" state that makes the brief synchronous CloudKit save
  /// read as deliberate rather than as a janky frozen collapse.
  @State private var isSaving = false

  /// Guards `runSaveFlow()` against re-entry (e.g. a tap-outside arriving while
  /// the Save button's flow is already in flight).
  @State private var isDismissing = false

  /// Controls the top action-buttons row. Held false while the floating
  /// container expands, then flipped true once it has fully settled so the
  /// buttons fade in *after* the open animation rather than rendering (and
  /// glitching through their loading states) mid-expansion.
  @State private var topButtonsVisible = false

  /// Set to "now" once the expansion settles to play the stroke-trace reveal
  /// replay (cleared again once it elapses). Until then `paths` is left empty so
  /// the container expands over a cheap, empty canvas — rendering a dense
  /// doodle's `Canvas` through the container's scale + warp/glow shaders + glass
  /// during the spring was the dominant source of open-lag for entries with
  /// existing drawings.
  @State private var strokeRevealDate: Date?

  /// True once the post-expansion reveal has run. Lets a decode that lands
  /// *after* the reveal (rare — slower than the 0.45s settle) surface its
  /// strokes immediately instead of waiting for a reveal that already passed.
  @State private var canvasContentRevealed = false

  /// Strokes decoded off-main but not yet applied to `paths` — held until the
  /// expansion settles, then surfaced by `revealCanvasContent()`.
  @State private var pendingStrokes: (paths: [Path], metadata: [PathMetadata])?

  /// Monotonic token guarding the deferred reveal so a dismiss/reopen before
  /// the delay elapses cancels a stale reveal.
  @State private var canvasRevealGeneration = 0

  /// Token for the deferred (post-collapse) persistence scheduled by
  /// `runSaveFlow()`. Bumped whenever the canvas reopens so a pending save is
  /// cancelled rather than firing against a fresh session.
  @State private var saveFlowGeneration = 0

  // Inspiration prompt state
  @State private var currentPrompt: String? = nil
  @State private var promptID = UUID()
  @State private var isIlluminated = false

  // Camera reference state — shared with ContentView via environment object.
  // Optional (absent in tutorial/mock mode) so the feature is fully disabled there.
  @EnvironmentObject private var cameraContext: CameraReferenceContext

  /// Album picker selection — selected item is consumed asynchronously to load
  /// the image data, then center-cropped and installed as the camera backdrop.
  @State private var albumPickerItem: PhotosPickerItem?

  /// Whether we're in mock/tutorial mode
  private var isMockMode: Bool {
    mockStore != nil
  }

  /// Whether the camera-reference feature should be active. True for the real
  /// app, and also true in mock mode when the camera-reference interactive
  /// tutorial has opted the feature back in. Lets the camera tutorial reach
  /// the live preview / shutter / capture flow without removing the broader
  /// `isMockMode` sandboxing of saved data.
  private var isCameraFeatureActive: Bool {
    !isMockMode || mockStore?.cameraTutorialEnabled == true
  }

  // MARK: - Concentric Corner Radius

  /// Canvas corner radius computed to be concentric with the floating
  /// `DynamicIslandExpandedView` container border (used on every device).
  /// Container clip = `screenCornerRadius - containerInset`, with an 8pt
  /// inner padding inside the container.
  private var canvasCornerRadius: CGFloat {
    let containerInset: CGFloat = UIDevice.hasDynamicIsland
      ? UIDevice.dynamicIslandFrame.origin.y
      : 10
    let diContainerPadding: CGFloat = 8
    return max(
      UIDevice.screenCornerRadius - containerInset - diContainerPadding,
      0
    )
  }

  /// The left/right gap between the fixed-size canvas square and the floating
  /// container edge. Because the canvas is a fixed `CANVAS_SIZE` square centered
  /// in the container's inner width, the horizontal gap is the leftover
  /// centering slack — `(containerInnerWidth - CANVAS_SIZE) / 2` — and varies
  /// per device. We reuse it as the bottom inset so the canvas sits with equal
  /// left/right/bottom padding inside the container on every device.
  private var canvasSideInset: CGFloat {
    let containerInset: CGFloat = UIDevice.hasDynamicIsland
      ? UIDevice.dynamicIslandFrame.origin.y
      : 10
    let containerInnerWidth = UIScreen.main.bounds.width - containerInset * 2
    return max((containerInnerWidth - CANVAS_SIZE) / 2, 0)
  }

  /// Whether editing is allowed based on subscription status
  private var canEditOrCreate: Bool {
    // Always allow in mock mode
    if isMockMode { return true }

    switch accessState {
    case .canCreate, .canEdit:
      return true
    case .limitReached, .editingLocked:
      return false
    }
  }

  /// Whether the *slot being edited* already has a persisted doodle. Slot-aware
  /// (not day-level): true only when `doodleIndex` points at an existing doodle,
  /// so starting a fresh doodle in a new slot on a day that already has doodles
  /// still offers the camera reference. Known without an async stroke decode, so
  /// the top-row layout settles on its final shape from the first frame instead
  /// of morphing camera→trash once the strokes land.
  private var slotHasDoodle: Bool {
    if isMockMode { return mockEntry?.drawingData != nil }
    guard let entry else { return false }
    return doodleIndex < entry.doodleCount
  }

  /// True while a persisted doodle is still being decoded and applied, so an
  /// empty `paths` does not yet mean an empty canvas. `drawingStateLoaded` only
  /// flips once the decoded strokes actually land (`applyPendingStrokes`), which
  /// is the whole in-flight window.
  private var isLoadingExistingDoodle: Bool {
    slotHasDoodle && !drawingStateLoaded
  }

  /// Whether the camera reference button (top-left) should be visible.
  /// Mirrors the bulb button visibility logic — hidden once any stroke exists
  /// and hidden while the camera live mode is active (the top row is empty
  /// except for the flip-camera button at the center).
  private var canShowCameraButton: Bool {
    // Gate on the load being in flight, NOT on the slot merely having a doodle.
    // `paths` is briefly empty while the async decode runs, which used to flash
    // the camera button before it flipped to the trash — but vetoing on
    // `slotHasDoodle` outright meant clearing an existing doodle left the slot
    // empty: the clear deliberately isn't persisted until dismiss, so the slot
    // still has data while the canvas in front of the user is blank, and the
    // trash unmounts at that same moment.
    guard isCameraFeatureActive, !isLoadingExistingDoodle,
          paths.isEmpty, currentPath.isEmpty, !isCameraLive else {
      return false
    }
    // In the camera tutorial, hide the button once a reference has been
    // captured — step D highlights the whole canvas so taps would otherwise
    // be free to re-enter live mode, which would then strand the user behind
    // a dim overlay with no shutter cutout.
    if isMockMode, cameraContext.backdropImage != nil {
      return false
    }
    return true
  }

  private var isCameraLive: Bool {
    isCameraFeatureActive && cameraContext.mode == .live
  }

  private var cameraBackdropImage: UIImage? { isCameraFeatureActive ? cameraContext.backdropImage : nil }
  private var cameraSession: AVCaptureSession? { isCameraFeatureActive ? cameraContext.session : nil }
  private var cameraDevice: AVCaptureDevice? { isCameraFeatureActive ? cameraContext.currentDevice : nil }
  private var cameraMirrored: Bool { isCameraFeatureActive && cameraContext.isFrontFacing }
  private var cameraShutterController: CameraShutterController? { isCameraFeatureActive ? cameraContext.shutter : nil }
  private var cameraShutterFullyClosed: Bool { isCameraFeatureActive && cameraContext.isShutterFullyClosed }
  private var cameraShutterCycling: Bool { isCameraFeatureActive && cameraContext.isShutterCycling }
  private var cameraSuppressPreview: Bool { isCameraFeatureActive && cameraContext.suppressPreview }
  private var cameraCaptureFlashID: UUID? { isCameraFeatureActive ? cameraContext.captureFlashID : nil }
  private var cameraIsCapturing: Bool { isCameraFeatureActive && cameraContext.isCapturing }

  private var cameraZoomCapabilities: CameraZoomCapabilities {
    isCameraFeatureActive ? cameraContext.zoomCapabilities : .disabled
  }
  private var cameraDisplayZoom: CGFloat { isCameraFeatureActive ? cameraContext.displayZoomFactor : 1.0 }
  /// Slider/pinch range, guarded so a degenerate capabilities set yields a
  /// valid (possibly empty) range rather than an inverted one.
  private var cameraZoomRange: ClosedRange<CGFloat> {
    let caps = cameraZoomCapabilities
    return caps.minDisplayZoom...max(caps.minDisplayZoom, caps.maxDisplayZoom)
  }

  private var canvasButtonsConfig: CanvasButtonsConfig {
    CanvasButtonsConfig(
      onClear: clearDrawing,
      onUndo: undoLastStroke,
      onRedo: redoLastStroke,
      canClear: !paths.isEmpty || !currentPath.isEmpty,
      canUndo: !undoStack.isEmpty,
      canRedo: !redoStack.isEmpty,
      isUndoHistoryLoading: undoHistoryPending,
      showClearConfirmation: $showClearConfirmation,
      centerContent: isCameraLive
        ? AnyView(cameraFlipButton)
        : (isMockMode ? nil : AnyView(inspirationBulbButton)),
      leadingExtra: {
        if isCameraLive { return AnyView(exitCameraButton) }
        if canShowCameraButton { return AnyView(cameraReferenceButton) }
        return nil
      }(),
      trailingExtra: isCameraLive ? AnyView(albumPickerButton) : nil,
      hideStrokeButtons: isCameraLive
    )
  }

  private var canvasStack: some View {
    ZStack(alignment: .top) {
      VStack(spacing: 12) {
        SharedCanvasView(
          paths: $paths,
          pathMetadata: $pathMetadata,
          currentPath: $currentPath,
          currentPathIsDot: $currentPathIsDot,
          isDrawing: $isDrawing,
          buttonsConfig: canvasButtonsConfig,
          canvasCornerRadius: canvasCornerRadius,
          strokeColor: Color.appDrawingColor(for: date),
          backdropImage: cameraBackdropImage,
          backdropZoom: isCameraFeatureActive ? cameraContext.backdropZoom : 1.0,
          backdropOffset: isCameraFeatureActive ? cameraContext.backdropOffset : .zero,
          backdropRotation: isCameraFeatureActive ? cameraContext.backdropRotation : .zero,
          liveCameraSession: cameraSession,
          liveCameraDevice: cameraDevice,
          isCameraLive: isCameraLive,
          liveCameraMirrored: cameraMirrored,
          shutterController: cameraShutterController,
          isShutterFullyClosed: cameraShutterFullyClosed,
          isShutterCycling: cameraShutterCycling,
          suppressLivePreview: cameraSuppressPreview,
          captureFlashID: cameraCaptureFlashID,
          isCapturing: cameraIsCapturing,
          isSaving: isSaving,
          cameraZoomFactor: cameraDisplayZoom,
          cameraZoomRange: cameraZoomRange,
          onSetCameraZoom: { cameraContext.setZoom($0) },
          topButtonsVisible: topButtonsVisible,
          strokeRevealDate: strokeRevealDate,
          // The floating container paints an always-black backdrop behind this
          // row (it has to, so it blends into the Dynamic Island cutout), so the
          // buttons and icons stay on the dark-theme foreground whatever the
          // app's appearance is. The drawing surface below keeps following the
          // theme — it matches the grid cells and thumbnails elsewhere.
          pinsDarkChrome: true,
          onCommitStroke: commitCurrentStroke
        ) {
          // Save button — becomes a rotating spinner while the drawing persists.
          Button(action: runSaveFlow) {
            if isSaving {
              ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.primary)
            } else {
              Image(systemName: "checkmark")
            }
          }
          .circularGlassButton()
          .disabled(isSaving)
          .tutorialHighlightAnchor(.button(id: .canvasSaveButton), cornerRadius: 22)
          // Same gating rationale as the camera button's tip below: the canvas
          // stays tucked in the tree when collapsed, and the bubble must not
          // paint over the paywall lock overlay.
          .featureTip(
            FeatureTipDefinitions.AnchorID.canvasFinish,
            isEnabled: isShowing && canEditOrCreate)
        }
        .disabled(!canEditOrCreate)
        .background(Color.clear)
        .overlay {
          // Show lock overlay when access is denied (not in mock mode)
          if !isMockMode && !canEditOrCreate {
            accessDeniedOverlay
          }
        }
        .fixedSize(horizontal: false, vertical: true)

        // Inspiration prompt text — centered, below the canvas (hidden in tutorial mode)
        if !isMockMode, let prompt = currentPrompt, !isCameraLive {
          InspirationPromptView(prompt: prompt)
            .id(promptID)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }

      }
      .animation(.springFkingSatifying, value: currentPrompt == nil)
      .animation(.springFkingSatifying, value: promptID)
      // Non-overshooting curve for camera-mode transitions to prevent the DI
      // container momentarily exceeding its final height (which would briefly
      // reveal the white surface behind it).
      .animation(.easeInOut(duration: 0.2), value: isCameraLive)
    }
  }

  private var decoratedCanvas: some View {
    canvasStack
      .padding(.horizontal, 8)
      .padding(.top, 24)
      // Match the bottom gap to the canvas's left/right centering slack so the
      // canvas sits with equal L/R/bottom padding inside the floating container.
      .padding(.bottom, canvasSideInset)
    // No opaque backstop here: the floating container behind us paints the
    // black-to-clear glass gradient, and an opaque fill would cover its
    // refractive bottom edge. Any transient reveal during the camera-mode
    // layout transition now shows that same container backdrop (dark at the
    // top, glass at the bottom) rather than a bare white surface.
    .onDisappear {
      // Safety net for cases where SwiftUI tears the view down (e.g. selection
      // cleared while canvas is still showing) without propagating the
      // isShowing binding change, so onChange(of: isShowing) never fires.
      guard !didSaveOnDismiss else { return }
      if isMockMode {
        saveMockDrawing()
      } else {
        saveDrawingToStore()
      }
      // Mirror the teardown that onChange(of: isShowing) would have done,
      // otherwise the camera session / LED can stay alive after the
      // floating container is removed.
      if isCameraFeatureActive {
        cameraContext.reset()
      }
    }
    .onAppear {
      // Only load drawing data when the canvas is already visible on appear.
      // On Dynamic Island devices, DrawingCanvasView lives in the hierarchy
      // whenever a date is selected (hidden via isShowing=false). Eagerly loading
      // paths here would leave stale data in @State that survives entry deletion
      // and gets re-saved on scenePhase→.background, resurrecting deleted entries.
      // The onChange(of: isShowing) handler covers loading when canvas becomes visible.
      guard isShowing else { return }
      didSaveOnDismiss = false
      if !isMockMode {
        checkAccessState()
      }
      loadExistingDrawing()
      // Hold strokes + buttons back until the expansion settles, then surface
      // them together once it has finished growing.
      canvasContentRevealed = false
      topButtonsVisible = false
      scheduleCanvasReveal()
    }
    .onChange(of: isShowing) { oldValue, newValue in
      // Invalidate any pending deferred reset from a previous dismiss.
      dismissResetGeneration += 1

      if newValue {
        // Canvas becoming visible — load data and check access
        didSaveOnDismiss = false
        isSaving = false
        isDismissing = false
        // Invalidate any post-collapse save still pending from a prior dismiss.
        saveFlowGeneration += 1
        if !isMockMode {
          checkAccessState()
        }
        loadExistingDrawing()
        // Strokes + buttons surface only after the container finishes expanding.
        canvasContentRevealed = false
        topButtonsVisible = false
        scheduleCanvasReveal()
      } else {
        // Reset the reveal immediately so strokes/buttons don't linger through
        // the collapse and the next open starts empty + buttonless.
        resetCanvasReveal()

        // Tear down camera state so the LED turns off and the transient
        // tracing photo doesn't leak into the next entry.
        if isCameraFeatureActive {
          cameraContext.reset()
        }

        // The normal dismiss route (`runSaveFlow`) owns persistence: it defers
        // the save + in-memory clear until after the collapse so the main
        // thread stays free for the animation. Skip both here in that case.
        guard !didSaveOnDismiss else { return }

        // Out-of-band dismiss (e.g. selection cleared while showing) that
        // bypassed the save flow — persist now and defer only the in-memory
        // clear past the collapse (so the top-row buttons don't flip mid-
        // dismiss). The scenePhase background save (guarded by isShowing) and
        // the onDisappear save (guarded by didSaveOnDismiss) are inert during
        // this window, so no stale-paths re-save can fire.
        if isMockMode {
          saveMockDrawing()
        } else {
          saveDrawingToStore()
        }
        didSaveOnDismiss = true

        let generation = dismissResetGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
          // Skip if the canvas reopened (or dismissed again) in the meantime.
          guard dismissResetGeneration == generation else { return }
          clearInMemoryDrawingState()
        }
      }
    }
    .onChange(of: saveDismissTrigger.wrappedValue) { _, requested in
      // Parent (e.g. tap-outside) asked us to save and dismiss.
      if requested {
        runSaveFlow()
      }
    }
    .onChange(of: subscriptionManager.hasPremiumAccess) { _, _ in
      // Re-check access when subscription changes (not in mock mode)
      if !isMockMode {
        checkAccessState()
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      // Safety net: persist drawing if the app backgrounds mid-session.
      // Guard by isShowing so a hidden canvas (DI devices) doesn't accidentally
      // re-save stale paths for an entry that was deleted in EntryEditingView.
      if newPhase == .background, !isMockMode, isShowing {
        beginBackgroundSaveTaskIfNeeded()
        saveDrawingToStore(generateThumbnails: false, scheduleWidgetSync: false)
        endBackgroundSaveTaskIfNeeded()
      }
    }
  }

  var body: some View {
    decoratedCanvas
      .confirmationDialog("Clear Drawing", isPresented: $showClearConfirmation) {
      Button("Clear", role: .destructive, action: clearDrawing).circularGlassButton()
      Button("Cancel", role: .cancel, action: {})
    } message: {
      Text("Clear all drawing?")
    }
    .sheet(isPresented: $showPaywall) {
      StandalonePaywallView(source: "entry_limit")
    }
    .sheet(isPresented: $showTrialClaim) {
      TrialClaimPaywallView(source: "entry_limit")
    }
    .alert("Camera Access Needed", isPresented: cameraPermissionAlertBinding) {
      Button("Cancel", role: .cancel) {}
      Button("Open Settings") {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      }
    } message: {
      Text("Joodle needs camera access to capture reference photos for tracing. Enable it in Settings.")
    }
    .alert("Photo Not Saved", isPresented: saveToAlbumDeniedAlertBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Joodle couldn't save this reference photo to your album. To turn saving back on, go to Settings > General > Customization > Save photos to album.")
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard isCameraFeatureActive else { return }
      switch newPhase {
      case .inactive:
        // iOS snapshots the UI during the `.inactive` transition for the app
        // switcher / home-peek. If the AVCaptureVideoPreviewLayer is captured
        // mid-frame, return-to-foreground takes a long time to reconcile and
        // the screen appears frozen. Unmount the preview here so the snapshot
        // captures a plain black canvas instead — cheap to restore.
        if cameraContext.mode == .live {
          cameraContext.suppressPreview = true
        }
      case .active:
        // Returning from peek / app-switcher: re-mount the live preview.
        // Always clear, even if `mode` flipped to `.idle` while we were
        // inactive (e.g. a capture completed behind the album-save permission
        // dialog) — otherwise `suppressPreview` would stay stuck `true` and the
        // next live session would come up black.
        cameraContext.suppressPreview = false
      case .background:
        // Real background transition: tear the camera all the way down.
        if cameraContext.mode == .live {
          cameraContext.reset()
        }
      @unknown default:
        break
      }
    }
    .onChange(of: albumPickerItem) { _, newItem in
      guard let newItem else { return }
      Task {
        await cameraContext.importReference {
          try? await newItem.loadTransferable(type: Data.self)
        }
        albumPickerItem = nil
      }
    }
    .postHogScreenView("Drawing Canvas")
  }

  // MARK: - Access Control UI

  /// Whether the limit gate should merchandise the claimable free trial
  /// instead of the purchase paywall.
  private var canOfferTrialClaim: Bool {
    trialOfferManager.isClaimOfferAvailable
  }

  private var accessDeniedOverlay: some View {
    VStack(spacing: 16) {
      Image(systemName: "lock.fill")
        .font(.appFont(size: 40))
        .foregroundColor(.appTextPrimary)

      switch accessState {
      case .limitReached:
        Text("You've reached your free Joodle limit")
          .font(.appHeadline())
          .foregroundColor(.appTextPrimary)
          .multilineTextAlignment(.center)

        if canOfferTrialClaim {
          Text("Your next 7 days of doodling can be free — Joodle Pro, on us")
            .font(.appSubheadline())
            .foregroundColor(.appTextPrimary.opacity(0.8))
            .multilineTextAlignment(.center)
        } else {
          Text("Upgrade to Joodle Pro for unlimited Joodles")
            .font(.appSubheadline())
            .foregroundColor(.appTextPrimary.opacity(0.8))
            .multilineTextAlignment(.center)
        }

      case .editingLocked(let reason):
        Text("Editing Locked")
          .font(.appHeadline())
          .foregroundColor(.appTextPrimary)

        Text(reason)
          .font(.appSubheadline())
          .foregroundColor(.appTextPrimary.opacity(0.8))
          .multilineTextAlignment(.center)

      default:
        EmptyView()
      }

      if canOfferTrialClaim, case .limitReached = accessState {
        Button {
          showTrialClaim = true
        } label: {
          HStack {
            Image(systemName: "gift.fill")
            Text("Claim 7 free days of Pro")
          }
          .font(.appHeadline())
          .foregroundColor(.appAccentContrast)
          .padding(.horizontal, 24)
          .padding(.vertical, 12)
          .background(.appAccent)
          .cornerRadius(32)
        }
      } else {
        Button {
          showPaywall = true
        } label: {
          HStack {
            Image(systemName: "crown.fill")
            Text("Upgrade")
          }
          .font(.appHeadline())
          .foregroundColor(.appAccentContrast)
          .padding(.horizontal, 24)
          .padding(.vertical, 12)
          .background(.appAccent)
          .cornerRadius(32)
        }
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.ultraThinMaterial.quaternary)
    .clipShape(RoundedRectangle(cornerRadius: canvasCornerRadius, style: .continuous))
  }

  // MARK: - Camera Reference

  private var cameraPermissionAlertBinding: Binding<Bool> {
    Binding(
      get: { isCameraFeatureActive && cameraContext.showPermissionDeniedAlert },
      set: { newValue in
        if isCameraFeatureActive {
          cameraContext.showPermissionDeniedAlert = newValue
        }
      }
    )
  }

  private var saveToAlbumDeniedAlertBinding: Binding<Bool> {
    Binding(
      get: { isCameraFeatureActive && cameraContext.showSaveToAlbumDeniedMessage },
      set: { newValue in
        if isCameraFeatureActive {
          cameraContext.showSaveToAlbumDeniedMessage = newValue
        }
      }
    )
  }

  /// Camera-affecting buttons are locked out for the entire shutter cycle so a
  /// second action can't fire while the first one is still animating.
  private var isShutterCycling: Bool {
    isCameraFeatureActive && cameraContext.isShutterCycling
  }

  private var cameraReferenceButton: some View {
    Button {
      Haptic.play(with: .light)
      Task { await cameraContext.enterLive() }
    } label: {
      Image(systemName: "camera.fill")
    }
    .circularGlassButton()
    .disabled(isShutterCycling)
    .tutorialHighlightAnchor(.button(id: .cameraButton), cornerRadius: 22)
    // Only surface the tooltip when the canvas is actually open; the canvas
    // stays in the tree (tucked) when collapsed, which would otherwise point
    // the tip at a stale off-screen frame. Also suppress it while access is
    // locked — the paywall lock overlay covers the (disabled) canvas, and the
    // app-root tip overlay would otherwise paint the bubble on top of it.
    .featureTip(FeatureTipDefinitions.AnchorID.cameraReference, isEnabled: isShowing && canEditOrCreate)
  }

  /// Top-right button in camera live mode — opens the system photo picker so
  /// the user can import a photo from their album as the tracing backdrop.
  private var albumPickerButton: some View {
    PhotosPicker(selection: $albumPickerItem, matching: .images, photoLibrary: .shared()) {
      Image(systemName: "photo.on.rectangle")
    }
    .circularGlassButton()
    .disabled(isShutterCycling || cameraIsCapturing)
  }

  /// Top-left button in camera live mode — exits the camera back to the
  /// drawing canvas without capturing.
  private var exitCameraButton: some View {
    Button {
      Haptic.play(with: .light)
      cameraContext.cancelLive()
    } label: {
      Image(systemName: "xmark")
    }
    .circularGlassButton()
    .disabled(isShutterCycling)
  }

  private var cameraFlipButton: some View {
    Button {
      Haptic.play(with: .light)
      cameraContext.flip()
    } label: {
      Image(systemName: "arrow.triangle.2.circlepath.camera")
    }
    .circularGlassButton()
    .disabled(isShutterCycling)
  }

  // MARK: - Inspiration Bulb Button

  private var inspirationBulbButton: some View {
    Button(action: rollInspirationPrompt) {
      Image(systemName: "lightbulb.max.fill")
    }
    .circularGlassButton()
    .overlay {
      if isIlluminated {
        TorchlightGlowView()
          .transition(.opacity)
          .allowsHitTesting(false)
      }
    }
    .animation(.easeIn(duration: 0.15), value: isIlluminated)
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          // Fires immediately on first finger contact
          guard !isIlluminated else { return }
          isIlluminated = true
        }
        .onEnded { _ in
          // Fires when finger lifts — hold for a moment then fade out
          DispatchQueue.main.async {
            withAnimation(.easeIn(duration: 0.25)) {
              isIlluminated = false
            }
          }
        }
    )
  }

  // MARK: - Access Check

  private func checkAccessState() {
    // Perform async verification with online check
    Task {
      // Check if this is an existing Joodle (editing) or new Joodle (creating)
      let hasExistingDrawing = entry?.drawingData != nil

      if hasExistingDrawing, let entry = entry {
        // Editing existing - verify access with online check
        let canEdit = await subscriptionManager.canEditJoodleWithVerification(entry: entry, in: modelContext)

        await MainActor.run {
          if canEdit {
            accessState = .canEdit
          } else {
            // Calculate index for error message
            let targetDateString = entry.dateString
            let descriptor = FetchDescriptor<DayEntry>(
              predicate: #Predicate<DayEntry> {
                $0.drawingData != nil && $0.dateString < targetDateString
              }
            )
            let index = (try? modelContext.fetchCount(descriptor)) ?? 0
            accessState = .editingLocked(
              reason:
                String(localized: "Free account can only edit the first \(SubscriptionManager.freeJoodlesAllowed) Joodles. This Joodle is #\(index + 1).")
            )
          }
        }
      } else {
        // Creating new - verify access with online check
        let canCreate = await subscriptionManager.checkAccessWithVerification(in: modelContext)

        await MainActor.run {
          if canCreate {
            accessState = .canCreate
          } else {
            accessState = .limitReached
          }
        }
      }
    }
  }

  // MARK: - Inspiration Prompt

  private func rollInspirationPrompt() {
    let candidates = PromptsManager.shared.allPrompts.filter { $0 != currentPrompt }
    guard let newPrompt = candidates.randomElement() else { return }
    
    // Add a haptic feedback
    Haptic.play(with: .light)

    // Swap prompt directly and force view recreation for fresh animation
    withAnimation(.springFkingSatifying) {
      currentPrompt = newPrompt
      promptID = UUID()
    }
  }

  // MARK: - Canvas Content Reveal

  /// Settle time of the container's expand spring (`springFkingSatifying`,
  /// response 0.3 → settles ≈0.45s). The strokes and the top-row buttons are
  /// both held back until the container has finished growing so they surface
  /// *after* the open, keeping the expansion itself butter-smooth.
  private static let canvasRevealDelay: TimeInterval = 0.45

  /// Duration of the stroke-trace reveal replay. Kept in sync with
  /// `SharedCanvasView`'s own `strokeTraceDuration` (and the button bounce) so
  /// strokes and buttons land together.
  private static let strokeTraceDuration: TimeInterval = 0.5

  /// Schedule the post-expansion reveal of the strokes + buttons. Guarded by a
  /// generation token so a dismiss (or reopen) before the delay elapses cancels
  /// the pending reveal.
  private func scheduleCanvasReveal() {
    canvasRevealGeneration += 1
    let token = canvasRevealGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.canvasRevealDelay) {
      guard token == canvasRevealGeneration, isShowing else { return }
      revealCanvasContent()
    }
  }

  /// Surface the canvas content now that the expansion has settled: apply any
  /// strokes that finished decoding during the animation, bounce the buttons
  /// in, and kick off the stroke-trace replay so they land together.
  private func revealCanvasContent() {
    canvasContentRevealed = true
    applyPendingStrokes()
    // Trace the strokes in (SharedCanvasView animates this one-shot replay).
    startStrokeTrace()
    // Bounce the buttons in (SharedCanvasView animates this with its spring).
    topButtonsVisible = true
  }

  /// Start the stroke-trace replay by stamping `strokeRevealDate`, then clear it
  /// once the replay has elapsed so the canvas drops back to its static (or
  /// boiling) render and the display-linked TimelineView stops redrawing.
  private func startStrokeTrace() {
    let now = Date()
    strokeRevealDate = now
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.strokeTraceDuration + 0.1) {
      // Skip if a newer trace started (or a dismiss cleared it) in the meantime.
      guard strokeRevealDate == now else { return }
      strokeRevealDate = nil
    }
  }

  /// Reset the reveal state immediately and cancel any pending reveal — used on
  /// dismiss so the next open starts from a clean (empty, buttonless) expand.
  private func resetCanvasReveal() {
    canvasRevealGeneration += 1
    canvasContentRevealed = false
    topButtonsVisible = false
    strokeRevealDate = nil
    pendingStrokes = nil
  }

  /// Move strokes decoded during the expansion into `paths`. Prepends ahead of
  /// anything committed in the meantime so nothing the user drew is dropped,
  /// and builds the undo history (deferred slightly so the reveal fade isn't
  /// disrupted by the O(n²) bookkeeping).
  private func applyPendingStrokes() {
    guard let pending = pendingStrokes else { return }
    pendingStrokes = nil

    paths = pending.paths + paths
    pathMetadata = pending.metadata + pathMetadata
    drawingStateLoaded = true

    let generation = loadGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      guard generation == loadGeneration else { return }
      undoStack = (0..<paths.count).map { i in
        (Array(paths.prefix(i)), Array(pathMetadata.prefix(i)))
      }
      undoHistoryPending = false
    }
  }

  // MARK: - Private Methods

  private func commitCurrentStroke() {
    guard !currentPath.isEmpty else { return }

    // Save current state to undo stack before making changes
    saveStateToUndoStack()

    // Add the current path and its metadata to completed paths
    paths.append(currentPath)
    pathMetadata.append(PathMetadata(isDot: currentPathIsDot))
    currentPath = Path()

    // Clear redo stack when new action is performed
    redoStack.removeAll()

    // Drawing data lives in the in-memory `paths` array.
    // We only persist to SwiftData when the canvas is dismissed (runSaveFlow)
    // to avoid any I/O lag during active drawing.

    // Reset drawing state
    isDrawing = false
    currentPathIsDot = false
  }

  private func saveStateToUndoStack() {
    // Save current paths and metadata state to undo stack
    undoStack.append((paths, pathMetadata))
  }

  private func undoLastStroke() {
    guard !undoStack.isEmpty else { return }

    // Save current state to redo stack
    redoStack.append((paths, pathMetadata))

    // Restore previous state from undo stack
    let (previousPaths, previousMetadata) = undoStack.removeLast()
    paths = previousPaths
    pathMetadata = previousMetadata

    // Clear current path if user is in middle of drawing
    currentPath = Path()
    isDrawing = false
    currentPathIsDot = false
  }

  private func redoLastStroke() {
    guard !redoStack.isEmpty else { return }

    // Save current state to undo stack
    saveStateToUndoStack()

    // Restore state from redo stack
    let (redoPaths, redoMetadata) = redoStack.removeLast()
    paths = redoPaths
    pathMetadata = redoMetadata

    // Clear current path if user is in middle of drawing
    currentPath = Path()
    isDrawing = false
    currentPathIsDot = false

  }

  private func loadExistingDrawing() {
    // Reset inspiration prompt for new session
    currentPrompt = nil
    isIlluminated = false

    // Check mock mode first
    if isMockMode {
      loadMockDrawing()
      return
    }

    // Load the drawing for the requested slot. A new slot (index == count) or a
    // missing entry starts blank.
    let slotDoodles = entry?.doodles ?? []
    guard slotDoodles.indices.contains(doodleIndex) else {
      // Initialize with empty state for new drawings. Nothing to decode, so
      // the canvas is authoritative — and saves allowed — immediately.
      drawingStateLoaded = true
      undoStack.removeAll()
      redoStack.removeAll()
      // Clear drawing
      paths.removeAll()
      pathMetadata.removeAll()
      currentPath = Path()
      isDrawing = false
      currentPathIsDot = false
      return
    }

    loadPathsFromData(slotDoodles[doodleIndex].drawingData)
  }

  private func loadMockDrawing() {
    guard let mockEntry = mockEntry, let data = mockEntry.drawingData else {
      // Initialize with empty state for new drawings
      drawingStateLoaded = true
      undoStack.removeAll()
      redoStack.removeAll()
      paths.removeAll()
      pathMetadata.removeAll()
      currentPath = Path()
      isDrawing = false
      currentPathIsDot = false
      return
    }

    loadPathsFromData(data)
  }

  /// Decode and rebuild persisted strokes off the main thread, applying them
  /// in a quick main-queue hop. Doing all of this synchronously — as it used
  /// to — ran in the same main-thread turn that starts the expand spring, so
  /// opening an existing doodle visibly hitched the first frames of the
  /// expansion (JSON-decoding every stroke point plus the O(n²) undo-history
  /// build). The apply usually lands within the first frames of the
  /// animation, masked by the content fade-in.
  ///
  /// The canvas stays non-authoritative (`drawingStateLoaded == false`) until
  /// the strokes are applied, so the existing save guards skip any save
  /// attempt during the in-flight window instead of clobbering the entry with
  /// an empty canvas.
  private func loadPathsFromData(_ data: Data) {
    // Drop any leftover strokes from a previous session synchronously so the
    // decoded result never merges with them (e.g. reopening the same date
    // before its 0.45s-deferred post-dismiss clear has run).
    paths.removeAll()
    pathMetadata.removeAll()
    undoStack.removeAll()
    redoStack.removeAll()

    // Existing data implies an undo history will arrive — show the undo/redo
    // buttons optimistically (disabled) from the first frame.
    undoHistoryPending = true

    loadGeneration += 1
    let generation = loadGeneration

    DispatchQueue.global(qos: .userInitiated).async {
      let decodedPaths: [PathData]
      do {
        decodedPaths = try JSONDecoder().decode([PathData].self, from: data)
      } catch {
        print("Failed to load drawing data: \(error)")
        DispatchQueue.main.async {
          guard generation == loadGeneration else { return }
          undoHistoryPending = false
        }
        return
      }

      // Rebuild the stroke geometry off-main too — Path is a value type with
      // no main-thread affinity, and this walk is the other big chunk of work.
      let loadedPaths = decodedPaths.map { pathData in
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
        return path
      }
      let loadedMetadata = decodedPaths.map { PathMetadata(isDot: $0.isDot) }

      DispatchQueue.main.async {
        guard generation == loadGeneration else { return }

        // Hold the decoded strokes until the expansion settles instead of
        // applying them mid-animation — rendering a dense doodle's Canvas
        // through the container's scale + warp/glow shaders + glass during the
        // spring is what hitched the open. `revealCanvasContent()` applies and
        // fades them in once the container has finished growing.
        pendingStrokes = (loadedPaths, loadedMetadata)

        // If the decode somehow outran the expansion (slower devices, tiny
        // doodles), the reveal has already passed — trace them in immediately.
        if canvasContentRevealed {
          applyPendingStrokes()
          startStrokeTrace()
        }
      }
    }
  }

  /// Drive the dismiss so persistence never stutters the collapse animation:
  ///   1. show the saving state (spinner + dim),
  ///   2. persist the drawing data — the brief synchronous write is masked by
  ///      the saving state, and the note prompt can read the saved data,
  ///   3. start the collapse with the main thread otherwise free; the heavier
  ///      thumbnail write is held until after the animation, and the in-memory
  ///      clear is deferred past it too.
  /// Used by both the Save button and the tap-outside trigger.
  private func runSaveFlow() {
    guard !isDismissing else { return }
    isDismissing = true

    // Surface the saving state only when there's a drawing whose save actually
    // costs something — the synchronous CloudKit write in the real app. An
    // empty / cleared canvas, or the in-memory mock store (tutorial), dismisses
    // with no spinner flash.
    let showSavingState = !paths.isEmpty && !isMockMode
    if showSavingState {
      withAnimation(.easeInOut(duration: 0.2)) {
        isSaving = true
      }
    }

    // Reset the parent trigger immediately so a future dismiss can re-fire it.
    saveDismissTrigger.wrappedValue = false

    // We own persistence — keep the onChange(isShowing)/onDisappear safety-net
    // saves from also firing (which would run synchronously during collapse).
    didSaveOnDismiss = true

    // Token for the deferred in-memory clear; invalidated if the canvas reopens.
    saveFlowGeneration += 1
    let token = saveFlowGeneration

    // Let the saving-state frame render before the (brief) blocking save.
    let saveDelay = showSavingState ? 0.08 : 0.0
    DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay) {
      if isMockMode {
        saveMockDrawing()
      } else {
        // Persist drawing data now (masked by the saving state); hold the
        // thumbnail write until after the collapse so it can't stutter it.
        saveDrawingToStore(thumbnailSaveDelay: 0.5)
      }

      // Collapse now — the note prompt sees the freshly-saved drawing data,
      // and the main thread is free for the animation.
      onDismiss()

      // Clear in-memory state once the collapse has settled.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        guard saveFlowGeneration == token else { return }
        clearInMemoryDrawingState()
      }
    }
  }

  /// Reset the in-memory drawing state after a dismiss has been persisted.
  /// Deferred until the collapse finishes so the top-row buttons don't flip
  /// (undo/redo/trash → camera/inspiration) and the saving dim/spinner persist
  /// smoothly through the animation.
  private func clearInMemoryDrawingState() {
    // Invalidate any in-flight async load so a slow decode can't resurrect
    // strokes (and re-arm the save guards) after this teardown.
    loadGeneration += 1
    undoHistoryPending = false
    paths.removeAll()
    pathMetadata.removeAll()
    currentPath = Path()
    isDrawing = false
    currentPathIsDot = false
    undoStack.removeAll()
    redoStack.removeAll()
    drawingStateLoaded = false
    isSaving = false
    isDismissing = false
  }

  private func saveMockDrawing() {
    guard drawingStateLoaded else { return }
    guard let mockStore = mockStore else { return }

    // Convert paths to data
    if paths.isEmpty {
      // Clear drawing from mock entry
      if let selectedDate = mockStore.selectedDateItem?.date {
        if var existingEntry = mockStore.getEntry(for: selectedDate) {
          existingEntry.drawingData = nil
          mockStore.updateEntry(existingEntry)
        }
      }
      return
    }

    let pathsData = paths.enumerated().map { (index, path) in
      let isDot = index < pathMetadata.count ? pathMetadata[index].isDot : false
      return PathData(points: path.extractPoints(), isDot: isDot)
    }

    do {
      let data = try JSONEncoder().encode(pathsData)

      if let selectedDate = mockStore.selectedDateItem?.date {
        if var existingEntry = mockStore.getEntry(for: selectedDate) {
          existingEntry.drawingData = data
          mockStore.updateEntry(existingEntry)
        } else {
          let newEntry = MockDayEntry(date: selectedDate, body: "", drawingData: data)
          mockStore.addEntry(newEntry)
        }
      }
    } catch {
      print("Failed to save mock drawing: \(error)")
    }
  }

  /// - Parameter thumbnailSaveDelay: seconds to hold the thumbnail's
  ///   main-thread write after generation. Used on dismiss to push that save
  ///   past the collapse animation so it doesn't stutter the transition; the
  ///   drawing-data save itself stays synchronous so the note prompt sees it.
  private func saveDrawingToStore(
    generateThumbnails: Bool = true,
    scheduleWidgetSync: Bool = true,
    thumbnailSaveDelay: TimeInterval = 0
  ) {
    // If the canvas was never loaded (e.g. hidden DI canvas torn down on
    // entry switch), skip saving to avoid overwriting another entry's doodle
    // with empty paths.
    guard drawingStateLoaded else { return }

    // Defense-in-depth: if the entry was deleted (e.g. via EntryEditingView)
    // but this view still holds a stale reference, bail out to avoid
    // re-inserting it through findOrCreate.
    if let entry, entry.isDeleted {
      return
    }

    // If no paths and no existing entry, don't create an empty entry
    if paths.isEmpty && entry == nil {
      return
    }

    // If we have an existing entry but paths is empty, remove the doodle at this
    // slot. A brand-new slot (index == count) with no strokes creates nothing.
    // If the day becomes fully empty (no doodles, no text), delete it entirely.
    if paths.isEmpty {
      if let existingEntry = entry, existingEntry.doodles.indices.contains(doodleIndex) {
        existingEntry.removeDoodle(at: doodleIndex)

        // If entry is now empty (no doodles and no text), delete it
        if existingEntry.doodleCount == 0 && existingEntry.body.isEmpty {
          existingEntry.deleteAllForSameDate(in: modelContext)
        } else {
          try? modelContext.save()
        }

        if scheduleWidgetSync {
          WidgetHelper.shared.scheduleWidgetDataUpdate(in: modelContext)
        }
      }
      return
    }

    // We have paths to save - use findOrCreate to get the single entry for this date
    let entryToSave: DayEntry = entry ?? DayEntry.findOrCreate(for: date, in: modelContext)

    // Convert paths to serializable data
    let pathsData = paths.enumerated().map { (index, path) in
      let isDot = index < pathMetadata.count ? pathMetadata[index].isDot : false
      return PathData(points: path.extractPoints(), isDot: isDot)
    }

    do {
      let data = try JSONEncoder().encode(pathsData)
      entryToSave.updateDoodle(at: doodleIndex, drawingData: data, thumbnail20: nil, thumbnail200: nil)

      // Save drawing data synchronously so it persists immediately.
      try? modelContext.save()

      if generateThumbnails {
        // Generate thumbnails asynchronously. Rendering is off-main (safe even
        // during a collapse), but the final SwiftData write is held for
        // `thumbnailSaveDelay` so it lands after the dismiss animation rather
        // than competing with it on the main thread.
        thumbnailTask?.cancel()
        thumbnailTask = Task {
          let thumbnails = await DrawingThumbnailGenerator.shared.generateThumbnails(from: data)
          guard !Task.isCancelled else { return }

          if thumbnailSaveDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(thumbnailSaveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
          }

          await MainActor.run {
            // Re-apply the same drawing bytes so the slot keeps its content
            // while the freshly rendered thumbnails fill in.
            entryToSave.updateDoodle(at: doodleIndex, drawingData: data, thumbnail20: thumbnails.0, thumbnail200: thumbnails.1)
            try? modelContext.save()
          }
        }
      } else {
        // Avoid extra writes when app is transitioning to background.
        thumbnailTask?.cancel()
      }
    } catch {
      print("Failed to save drawing data: \(error)")
    }

    if scheduleWidgetSync {
      // Schedule a debounced widget update so rapid strokes don't overload WidgetCenter
      WidgetHelper.shared.scheduleWidgetDataUpdate(in: modelContext)
    }
  }

  private func beginBackgroundSaveTaskIfNeeded() {
    guard backgroundSaveTaskId == .invalid else { return }

    backgroundSaveTaskId = UIApplication.shared.beginBackgroundTask(withName: "PersistDrawingOnBackground") {
      Task { @MainActor in
        endBackgroundSaveTaskIfNeeded()
      }
    }
  }

  private func endBackgroundSaveTaskIfNeeded() {
    guard backgroundSaveTaskId != .invalid else { return }

    UIApplication.shared.endBackgroundTask(backgroundSaveTaskId)
    backgroundSaveTaskId = .invalid
  }


  private func clearDrawing() {
    // Save current state to undo stack before clearing
    if !paths.isEmpty {
      saveStateToUndoStack()
    }

    paths.removeAll()
    pathMetadata.removeAll()
    currentPath = Path()
    isDrawing = false
    currentPathIsDot = false

    // Clear redo stack when new action is performed
    redoStack.removeAll()

    // Don't persist the clear immediately — let the dismiss logic
    // (onChange(of: isShowing) / onDisappear / runSaveFlow) handle saving
    // the empty-paths state to the store when the canvas is closed.
  }

}

#Preview {
  ZStack {
    Color.black
    DrawingCanvasView(
      date: Date(),
      entry: DayEntry(body: "HELLO", createdAt: Date(), drawingData: nil),
      onDismiss: {},
      isShowing: true
    )
    .environmentObject(CameraReferenceContext())
  }

}

#Preview("Mock Mode - Tutorial") {
  struct MockPreview: View {
    @StateObject private var mockStore = MockDataStore()

    var body: some View {
      DrawingCanvasView(
        date: Date(),
        entry: nil,
        onDismiss: {},
        isShowing: true,
        mockStore: mockStore,
        mockEntry: nil
      )
      .environmentObject(CameraReferenceContext())
    }
  }
  return MockPreview()
}
