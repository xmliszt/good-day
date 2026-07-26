//
//  ContentView.swift
//  Joodle
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftData
import SwiftUI

struct ContentView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.userPreferences) private var userPreferences
  @Environment(\.cloudSyncManager) private var cloudSyncManager

  @Query private var entries: [DayEntry]
  @StateObject private var subscriptionManager = SubscriptionManager.shared

  /// Data provider for the grid (abstracts data source for shared JoodleGridInteractionView)
  @StateObject private var dataProvider = AppDataProvider()

  @Binding var selectedDateFromWidget: Date?

  // --- GESTURE STATE ---
  // Tracks what the user is currently doing
  @State private var isScrubbing = false
  @State private var isPinching = false
  @State private var highlightedId: String?
  // --- END GESTURE STATE ---

  // --- MOVE DRAWING STATE ---
  /// Whether user is in "move drawing" mode
  @State private var isMovingDrawing = false
  /// Ripple animation trigger — increment to fire a new ripple
  @State private var rippleTrigger: Int = 0
  /// Screen-space origin for the ripple (set to screen center when entering move mode)
  @State private var rippleOrigin: CGPoint = .zero
  /// The source entry whose drawing is being moved (stored independently of selectedDateItem)
  @State private var moveSourceEntry: DayEntry?
  /// The source date for the drawing being moved
  @State private var moveSourceDate: Date?
  /// Target date selected by the user for the confirmation alert
  @State private var moveTargetDate: Date?
  /// Whether to show the move confirmation alert
  @State private var showMoveConfirmation = false
  // --- END MOVE DRAWING STATE ---

  @State private var yearGridViewSize: CGSize = .zero
  @State private var scrollProxy: ScrollViewProxy?
  @State private var showDrawingCanvas: Bool = false
  /// Flipped true to ask `DrawingCanvasView` to run its save flow (saving-state
  /// UI → persist) before collapsing. The canvas resets it once it begins.
  @State private var canvasSaveDismissTrigger: Bool = false
  /// Set when a quick action requests opening the canvas before a date selection has landed.
  @State private var pendingOpenCanvasFromShortcut: Bool = false
  @State private var showNotePromptPopup: Bool = false
  @State private var isNoteEditing: Bool = false
  @State private var noteEditingInitialText: String = ""
  @State private var noteEditingSaveHandler: ((String) -> Void)?
  @State private var dateForNotePrompt: Date? = nil
  /// Tracks whether the entry had a doodle when the drawing canvas was opened (for note prompt logic)
  @State private var entryHadDoodleOnCanvasOpen: Bool = false

  @State private var navigateToSettings = false
  @State private var navigateToNotePromptSetting = false
  @State private var hideDynamicIslandView = false

  // --- CONVERSION FUNNEL STATE ---
  /// One-time post-trial comparison sheet (trial ended / claim offer expired)
  @State private var showPostTrialSheet = false
  /// Which post-trial copy variant the sheet shows
  @State private var postTrialOfferExpired = false
  /// The "7 days on us" claim paywall (auto-presented at the doodle limit,
  /// or as a winback for legacy installs)
  @State private var showTrialClaimSheet = false
  @StateObject private var trialOfferManager = TrialOfferManager.shared
  // --- END CONVERSION FUNNEL STATE ---

  /// Shared camera-reference state. Consumed by DrawingCanvasView for the
  /// in-canvas preview / top-row controls, and by this view for the
  /// fullscreen blurred backdrop and the bottom shutter overlay.
  @StateObject private var cameraContext = CameraReferenceContext()

  /// Temporary edge-drag zoom control (JOO-147). When the user drags inward from
  /// the screen edge *opposite* their handedness preference, a second, identical
  /// zoom ruler is pulled out of that edge. `tempZoomReveal` (0…1) tracks how far
  /// it has emerged — set live from the drag so it follows the finger — and
  /// `tempZoomCommitted` records whether a released drag came out far enough to
  /// stay. Both are in-the-moment view state only; they never touch the
  /// `cameraZoomSliderHandedness` preference and reset when live mode ends.
  @State private var tempZoomReveal: CGFloat = 0
  @State private var tempZoomCommitted: Bool = false

  private let headerHeight: CGFloat = 100.0

  // Hit testing optimization (O(1) lookup)
  @State private var hitTestingGrid: [[String?]] = []
  @State private var gridMetrics: GridMetrics?

  struct GridMetrics {
    let rowHeight: CGFloat
    let colWidth: CGFloat
    let startX: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
  }

  // Gesture states
  private let scaleThreshold: CGFloat = 0.9  // Threshold for detecting significant pinch
  private let expandThreshold: CGFloat = 1.2  // Threshold for detecting significant expand

  // MARK: Computed

  private var currentHighlightedItem: DateItem? {
    highlightedId.flatMap { dataProvider.getItem(from: $0) }
  }

  private var currentHighlightedEntry: DayEntry? {
    if let itemDate = currentHighlightedItem?.date {
      return entries.first(where: { $0.matches(date: itemDate) })
    }
    return nil
  }

  /// Compute selectedEntry on-the-fly to avoid binding propagation issues
  private var selectedEntry: DayEntry? {
    guard let date = dataProvider.selectedDateItem?.date else { return nil }
    let candidates = entries.filter { $0.matches(date: date) }
    return candidates.first(where: { ($0.drawingData?.isEmpty == false) || !$0.body.isEmpty }) ?? candidates.first
  }

  private var isBottomViewVisible: Bool {
    dataProvider.selectedDateItem != nil
  }

  /// The scrollable year grid. Extracted from `body` to keep the main view
  /// expression within the Swift type-checker's complexity budget.
  private func yearGridScrollView(geometry: GeometryProxy) -> some View {
    ScrollViewReader { scrollProxy in
      ScrollView(showsIndicators: false) {
        // Add spacer at top to account for header overlay
        Spacer()
          .frame(height: headerHeight)
          .id("topSpacer")

        // Use shared JoodleGridInteractionView with optimized hit testing
        JoodleGridInteractionView(
          dataProvider: dataProvider,
          additionalEntries: entries,
          geometry: geometry,
          isScrubbing: $isScrubbing,
          highlightedId: highlightedId,
          callbacks: createGridCallbacks(geometry: geometry, scrollProxy: scrollProxy),
          minimumPressDuration: 0.3,
          allowsHitTesting: true,
          overlayContent: nil,
          customHitTestFunction: { location in
            getItemId(at: location, for: geometry)
          },
          isInMoveMode: isMovingDrawing,
          moveSourceDateString: isMovingDrawing ? moveSourceDateString : nil
        )
        .simultaneousGesture(
          MagnificationGesture()
            .onChanged { handlePinchChanged(value: $0) }
            .onEnded { handlePinchEnded(value: $0) }
        )
      }
      // When view mode changes, rebuild hit testing grid
      .onChange(of: dataProvider.viewMode) {
        hitTestingGrid = []  // Clear grid to trigger rebuild
        gridMetrics = nil

        if let selectedDateItem = dataProvider.selectedDateItem {
          // Delay scroll to allow grid animation to complete
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            scrollToRelevantDate(
              itemId: selectedDateItem.id, scrollProxy: scrollProxy, anchor: .center)
          }
        } else {
          // Delay scroll to allow grid animation to complete
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            scrollToTodayOrTop(scrollProxy: scrollProxy)
          }
        }
      }
      // When year changes, scroll to relevant date and rebuild hit testing grid
      .onChange(of: dataProvider.selectedYear) {
        hitTestingGrid = []  // Clear grid to trigger rebuild
        gridMetrics = nil

        // Don't clear selection in move mode — user is browsing years for a target
        if !isMovingDrawing {
          dataProvider.clearSelection()
        }

        DispatchQueue.main.async {
          scrollToTodayOrTop(scrollProxy: scrollProxy)
        }
      }
      // Initial scroll to today's dot for both modes
      .onAppear {
        yearGridViewSize = geometry.size
        self.scrollProxy = scrollProxy

        DispatchQueue.main.async {
          scrollToTodayOrTop(scrollProxy: scrollProxy)

          // Auto-select today on launch
          let currentYear = Calendar.current.component(.year, from: Date())
          if dataProvider.selectedYear == currentYear {
            let targetId = dataProvider.getRelevantDateId(for: Date())
            if let item = dataProvider.getItem(from: targetId) {
              selectDateItem(item: item, scrollProxy: scrollProxy)
            }
          }
        }
      }
      .onDisappear {
        self.scrollProxy = nil
      }
      .scrollDisabled(isScrubbing || isPinching)
    }
  }

  /// Temporary edge-drag zoom control (JOO-147). Rendered on the edge *opposite*
  /// the user's handedness preference. A thin invisible grab strip on that edge
  /// tracks an inward drag into `tempZoomReveal` (0…1), which slides a second,
  /// identical zoom ruler out of the edge in real time; releasing past the
  /// halfway point commits it (it stays out and takes over its own zoom drag),
  /// otherwise it retracts. Both rulers drive the same live zoom and the
  /// handedness preference is never written. Broken out of `body` so the main
  /// view expression stays within the SwiftUI type-checker's complexity budget.
  /// Which edge zoom ruler the temporary control is currently mirroring. Live
  /// camera and reference-photo adjustment are mutually exclusive and each own a
  /// separate zoom value, so the token both gates visibility (`.inactive` hides
  /// the control) and, on any change, resets the in-the-moment reveal — switching
  /// contexts starts a fresh pull rather than carrying a committed ruler over.
  private enum TempZoomContext: Equatable {
    case inactive
    case liveCamera
    case referencePhoto
  }

  @ViewBuilder
  private func temporaryZoomSliderOverlay(
    context: TempZoomContext,
    defaultEdge: HorizontalEdge,
    zoomFactor: CGFloat,
    range: ClosedRange<CGFloat>,
    keyFactors: [CGFloat],
    onChange: @escaping (CGFloat) -> Void
  ) -> some View {
    let isShowing = context != .inactive
    let tempEdge: HorizontalEdge = defaultEdge == .trailing ? .leading : .trailing
    // Same off-edge hide distance the default ruler uses to tuck fully away.
    let hiddenOffset: CGFloat = tempEdge == .trailing ? 140 : -140
    // Inward drag distance (points) for the ruler to fully emerge.
    let pullDistance: CGFloat = 120

    Group {
      // The temporary ruler. Its horizontal offset interpolates from fully
      // hidden (reveal 0) to flush against the edge (reveal 1), so it tracks
      // the pull out of the edge in real time.
      HStack(spacing: 0) {
        if tempEdge == .leading {
          CameraZoomSlider(
            zoomFactor: zoomFactor,
            range: range,
            keyFactors: keyFactors,
            edge: .leading,
            onChange: onChange
          )
        }
        Spacer(minLength: 0)
        if tempEdge == .trailing {
          CameraZoomSlider(
            zoomFactor: zoomFactor,
            range: range,
            keyFactors: keyFactors,
            edge: .trailing,
            onChange: onChange
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      .padding(.bottom, 80)
      .ignoresSafeArea()
      .opacity(isShowing && tempZoomReveal > 0.001 ? 1 : 0)
      .offset(x: hiddenOffset * (1 - tempZoomReveal))
      // The emerged ruler owns its own zoom drag only once committed; until
      // then the grab strip below is what tracks the pull, so the reveal
      // gesture and the ruler's zoom gesture never fight.
      .allowsHitTesting(isShowing && tempZoomCommitted)

      // Invisible edge grab band on the non-default edge, hosting a
      // UIScreenEdgePanGestureRecognizer — the platform's own tool for an
      // inward drag that starts at the very screen edge (a pure SwiftUI
      // DragGesture there loses the touch-down to the system's edge pan). The
      // band is parked at the edge by the outer frame and only intercepts while
      // uncommitted, so the emerged ruler takes over its own zoom drag after.
      ScreenEdgePanCatcher(
        edge: tempEdge,
        onChanged: { inward in
          tempZoomReveal = EdgeDragReveal.revealFraction(
            inwardTranslation: inward, pullDistance: pullDistance)
        },
        onEnded: { inward in
          let reveal = EdgeDragReveal.revealFraction(
            inwardTranslation: inward, pullDistance: pullDistance)
          let commit = EdgeDragReveal.shouldCommit(reveal: reveal)
          withAnimation(.easeOut(duration: 0.25)) {
            tempZoomReveal = commit ? 1 : 0
            tempZoomCommitted = commit
          }
          if commit { Haptic.play() }
        }
      )
      .frame(width: 44)
      .frame(maxHeight: .infinity)
      .frame(maxWidth: .infinity, maxHeight: .infinity,
             alignment: tempEdge == .leading ? .leading : .trailing)
      .ignoresSafeArea()
      .allowsHitTesting(isShowing && !tempZoomCommitted)
    }
    // In-the-moment only: clear the temporary control whenever the active zoom
    // context changes — the ruler goes away (capture, cancel, the system Camera
    // Control overlay), or the user moves between live camera and photo-adjust.
    // Never writes the handedness preference.
    .onChange(of: context) { _, _ in
      if tempZoomReveal != 0 || tempZoomCommitted {
        tempZoomReveal = 0
        tempZoomCommitted = false
      }
    }
  }

  var body: some View {
    ZStack {
      GeometryReader { geometry in
        ZStack(alignment: .top) {
          ResizableSplitView(
            top: {
              ZStack {
                // Backdrop background color to cover the top handle area
                Color(UIColor.systemBackground)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Time-passing water backdrop (hide when bottom view is visible or disabled in settings)
                // Joodle Pro feature — free users never see it, even if the preference
                // was switched on while it was free.
                if userPreferences.enableTimeBackdrop && subscriptionManager.hasPremiumAccess {
                  LiquidMetaballBackdropView()
                }

                // Full-screen scrollable year grid with time-passing backdrop
                yearGridScrollView(geometry: geometry)
              }
            },
            bottom: {
              EntryEditingView(
                date: dataProvider.selectedDateItem?.date,
                entry: selectedEntry,
                onOpenDrawingCanvas: {
                  Haptic.play()
                  // Track if entry already has doodle before opening canvas
                  entryHadDoodleOnCanvasOpen = selectedEntry?.drawingData != nil
                  showDrawingCanvas = true
                },
                onFocusChange: { isFocused in
                  guard isFocused, let selectedDateItem = dataProvider.selectedDateItem, let scrollProxy else { return }

                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    scrollToRelevantDate(
                      itemId: selectedDateItem.id, scrollProxy: scrollProxy, anchor: .center)
                  }
                },
                onNoteEditRequested: { initialText, onSave in
                  noteEditingInitialText = initialText
                  noteEditingSaveHandler = onSave
                  isNoteEditing = true
                },
                onNoteEditDismissed: {
                  isNoteEditing = false
                },
                onMoveDrawingRequested: {
                  enterMoveDrawingMode()
                }
              )
            }, hasBottomView: dataProvider.selectedDateItem != nil,
            onBottomDismissed: {
              // Delay clearing selection so the scroll-to-center animation can play out
              // before the re-render caused by selection change interrupts it
              DispatchQueue.main.async {
                dataProvider.clearSelection()
              }
            },
            onTopViewHeightChange: { newHeight in
              yearGridViewSize.height = newHeight
              // Scroll after height change is complete, only do so if there is item selected.
              guard let selectedDateItem = dataProvider.selectedDateItem, let scrollProxy else { return }
              scrollToRelevantDate(
                itemId: selectedDateItem.id, scrollProxy: scrollProxy, anchor: .center)
            }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .ignoresSafeArea(.container, edges: .bottom)

          // Floating header with blur backdrop
          HeaderView(
            highlightedEntry: currentHighlightedEntry,
            geometry: geometry,
            highlightedItem: currentHighlightedItem,
            selectedYear: Binding(
              get: { dataProvider.selectedYear },
              set: { dataProvider.selectedYear = $0 }
            ),
            viewMode: dataProvider.viewMode,
            onToggleViewMode: { toggleViewMode(to: dataProvider.viewMode == .now ? .year : .now) },
            onSettingsAction: {
              UIApplication.shared.hideKeyboard()
              navigateToSettings = true
            },
            isInMoveMode: isMovingDrawing
          )
        }
      }
      .ignoresSafeArea(.all, edges: .bottom)
      // Navigate to setting view
      .navigationDestination(isPresented: $navigateToSettings) {
        SettingsView(navigateToNotePromptSetting: $navigateToNotePromptSetting)
      }
      .navigationTitle("Home")
      .toolbar(.hidden, for: .navigationBar)
      .onChange(of: navigateToSettings) { _, newValue in
        // If setting presented, hide dynamic island view
        if newValue == true {
          hideDynamicIslandView = true
        }
        // If setting dismissed, show dynamic island view after a short delay
        else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            hideDynamicIslandView = false
          }
        }
      }

      // Floating drawing canvas — same component on every device. On DI
      // devices it tucks behind the cutout when collapsed; on notch / other
      // devices it sits just below the top safe area as a floating panel.
      if dataProvider.selectedDateItem != nil {
        DynamicIslandExpandedView(
          isExpanded: $showDrawingCanvas,
          content: {
            DrawingCanvasView(
              date: dataProvider.selectedDateItem!.date,
              entry: selectedEntry,
              // Called by the canvas only after its save flow completes, so the
              // collapse animation runs against an already-persisted entry.
              onDismiss: {
                performDrawingCanvasDismiss()
              },
              isShowing: showDrawingCanvas,
              saveDismissTrigger: $canvasSaveDismissTrigger
            )
            .environmentObject(cameraContext)
          },
          // Hide floating canvas view when navigating to settings
          hidden: hideDynamicIslandView,
          // Tapping outside requests a save + dismiss; the canvas shows its
          // saving state, persists, then drives the collapse via onDismiss.
          onDismiss: {
            requestCanvasSaveAndDismiss()
          }
        )
        .id("DynamicIslandExpandedView-\(dataProvider.selectedDateItem?.id ?? "none")")
      }

      // Note editing popup — shown when user taps the note area in EntryEditingView
      if isNoteEditing, let saveHandler = noteEditingSaveHandler {
        NoteEditingPopupView(
          initialText: noteEditingInitialText,
          onSave: saveHandler,
          onDismiss: { isNoteEditing = false }
        )
        .zIndex(100)
      }

      // Note prompt popup - shown after first doodle
      if showNotePromptPopup {
        NotePromptPopupView(
          isPresented: $showNotePromptPopup,
          onSave: { note in
            saveNoteForEntry(note: note)
          },
          onNavigateToSettings: {
            // Navigate to Customization settings and scroll to note prompt setting
            navigateToNotePromptSetting = true
            navigateToSettings = true
          },
          drawingData: dateForNotePrompt.flatMap { date in
            entries.first(where: { $0.matches(date: date) })?.drawingData
          }
        )
        .zIndex(100)
      }

      // Move drawing mode — animated gradient border (non-interactive)
      if isMovingDrawing {
        MoveDrawingGradientBorder()
          .modifier(RippleEffect(at: rippleOrigin, trigger: rippleTrigger))
          .ignoresSafeArea()
          .allowsHitTesting(false)
          .zIndex(50)
          .transition(.opacity)
      }

      // Camera reference mode — bottom shutter overlay (all devices).
      VStack {
        Spacer()
        ShutterButton(style: .glass) {
          Task { await cameraContext.capture() }
        }
        .disabled(cameraContext.isShutterCycling)
        .padding(.bottom, 32)
      }
      .ignoresSafeArea(.container, edges: .bottom)
      // Hidden while the iPhone 16 Camera Control system overlay is up — the
      // system shows its own controls, so the app hides its on-screen UI.
      .opacity(cameraContext.mode == .live && !cameraContext.systemControlsActive ? 1 : 0)
      .allowsHitTesting(cameraContext.mode == .live && !cameraContext.systemControlsActive)
      .animation(.easeInOut(duration: 0.2), value: cameraContext.mode == .live)
      .animation(.easeInOut(duration: 0.2), value: cameraContext.systemControlsActive)

      // Hardware shutter: volume buttons (all devices) and the iPhone 16 Camera
      // Control click trigger a capture while live.
      CameraCaptureEventView(isEnabled: cameraContext.mode == .live) {
        Task { await cameraContext.capture() }
      }
      .allowsHitTesting(false)
      .frame(width: 0, height: 0)

      // Camera zoom slider — hugs the screen edge (side per handedness),
      // anchored 100pt above the bottom so it sits below the floating canvas and
      // above the shutter. It slides in/out from the edge, and stays hidden
      // while the iPhone 16 Camera Control system overlay is up so the two
      // don't compete.
      let zoomCaps = cameraContext.zoomCapabilities
      let zoomSliderEdge: HorizontalEdge =
        userPreferences.cameraZoomSliderHandedness == .right ? .trailing : .leading
      let showZoomSlider = cameraContext.mode == .live
        && !cameraContext.systemControlsActive
        && zoomCaps.minDisplayZoom < zoomCaps.maxDisplayZoom
      HStack(spacing: 0) {
        if zoomSliderEdge == .leading {
          CameraZoomSlider(
            zoomFactor: cameraContext.displayZoomFactor,
            range: zoomCaps.minDisplayZoom...max(zoomCaps.minDisplayZoom, zoomCaps.maxDisplayZoom),
            keyFactors: zoomCaps.keyZoomFactors,
            edge: .leading,
            onChange: { cameraContext.setZoom($0) }
          )
        }
        Spacer(minLength: 0)
        if zoomSliderEdge == .trailing {
          CameraZoomSlider(
            zoomFactor: cameraContext.displayZoomFactor,
            range: zoomCaps.minDisplayZoom...max(zoomCaps.minDisplayZoom, zoomCaps.maxDisplayZoom),
            keyFactors: zoomCaps.keyZoomFactors,
            edge: .trailing,
            onChange: { cameraContext.setZoom($0) }
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      .padding(.bottom, 80)
      .ignoresSafeArea()
      .opacity(showZoomSlider ? 1 : 0)
      .offset(x: showZoomSlider ? 0 : (zoomSliderEdge == .trailing ? 140 : -140))
      .allowsHitTesting(showZoomSlider)
      // Ease-out slide out of / back into the screen edge. No bounce: an
      // overshoot would pull the panel inward off the edge and break the morph.
      .animation(.easeOut(duration: 0.28), value: showZoomSlider)

      // Temporary edge-drag zoom control (JOO-147) — on the NON-default edge.
      // Dragging inward from the opposite screen edge pulls a second, identical
      // zoom ruler out of that edge at the rate of the finger, so the user can
      // reach whichever side is convenient right now without changing their
      // handedness preference. Both rulers coexist and drive the same zoom.
      // Serves whichever edge ruler is currently up: the live-camera zoom, or
      // the reference-photo scale once a tracing photo is in the canvas (these
      // two are mutually exclusive). Extracted into its own builder so
      // ContentView.body stays within the SwiftUI type-checker's complexity budget.
      let showPhotoZoom = cameraContext.backdropImage != nil
        && showDrawingCanvas
        && !hideDynamicIslandView
        && cameraContext.mode != .live
      let tempZoomContext: TempZoomContext = showZoomSlider
        ? .liveCamera
        : (showPhotoZoom ? .referencePhoto : .inactive)
      temporaryZoomSliderOverlay(
        context: tempZoomContext,
        defaultEdge: zoomSliderEdge,
        zoomFactor: tempZoomContext == .referencePhoto
          ? cameraContext.backdropZoom
          : cameraContext.displayZoomFactor,
        range: tempZoomContext == .referencePhoto
          ? CameraReferenceContext.photoZoomRange
          : zoomCaps.minDisplayZoom...max(zoomCaps.minDisplayZoom, zoomCaps.maxDisplayZoom),
        keyFactors: tempZoomContext == .referencePhoto
          ? CameraReferenceContext.photoZoomKeyFactors
          : zoomCaps.keyZoomFactors,
        onChange: { newValue in
          if tempZoomContext == .referencePhoto {
            cameraContext.setBackdropZoom(newValue)
          } else {
            cameraContext.setZoom(newValue)
          }
        }
      )

      // Reference-photo adjustment controls — shown once a tracing photo has
      // been captured/imported (idle mode with a backdrop). They let the user
      // zoom (the same edge ruler as the live camera), translate (2-axis pad)
      // and rotate (arc) the reference to line it up for tracing. Grouped so the
      // two overlays count as a single child of the root ZStack.
      Group {
      let showPhotoAdjust = cameraContext.backdropImage != nil
        && showDrawingCanvas
        && !hideDynamicIslandView
        && cameraContext.mode != .live

      // Photo-zoom slider — reuses the camera zoom ruler at the handedness edge,
      // driving the reference-photo scale instead of the live optical zoom.
      HStack(spacing: 0) {
        if zoomSliderEdge == .leading {
          CameraZoomSlider(
            zoomFactor: cameraContext.backdropZoom,
            range: CameraReferenceContext.photoZoomRange,
            keyFactors: CameraReferenceContext.photoZoomKeyFactors,
            edge: .leading,
            onChange: { cameraContext.setBackdropZoom($0) }
          )
        }
        Spacer(minLength: 0)
        if zoomSliderEdge == .trailing {
          CameraZoomSlider(
            zoomFactor: cameraContext.backdropZoom,
            range: CameraReferenceContext.photoZoomRange,
            keyFactors: CameraReferenceContext.photoZoomKeyFactors,
            edge: .trailing,
            onChange: { cameraContext.setBackdropZoom($0) }
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      .padding(.bottom, 80)
      .ignoresSafeArea()
      .opacity(showPhotoAdjust ? 1 : 0)
      .offset(x: showPhotoAdjust ? 0 : (zoomSliderEdge == .trailing ? 140 : -140))
      .allowsHitTesting(showPhotoAdjust)
      .animation(.easeOut(duration: 0.28), value: showPhotoAdjust)

      // Native-Camera-style 2-axis translation pad wrapped by the rotation
      // dial, centered above the bottom edge. The dial is a polaroid-style bezel
      // that hugs the pad's perimeter and sits z-behind it, so only the ring
      // around the pad is exposed for turning. Travel bound tracks zoom +
      // rotation: zero at 1× (the photo exactly covers the canvas, so there's
      // nothing to reveal), opening up to the photo's own edges as the user
      // zooms in.
      VStack {
        Spacer()
        ZStack {
          PhotoRotationDial(
            rotation: cameraContext.backdropRotation,
            onRotationChange: { cameraContext.setBackdropRotation($0) },
            innerSide: PhotoTranslationPad.containerSide
          )
          PhotoTranslationPad(
            offset: cameraContext.backdropOffset,
            translationRange: cameraContext.backdropTranslationRange,
            onOffsetChange: { cameraContext.backdropOffset = $0 }
          )
        }
        .padding(.bottom, 24)
      }
      .ignoresSafeArea(.container, edges: .bottom)
      .opacity(showPhotoAdjust ? 1 : 0)
      .allowsHitTesting(showPhotoAdjust)
      .animation(.easeInOut(duration: 0.25), value: showPhotoAdjust)
      }

      // Move drawing mode — floating instruction bar (interactive)
      if isMovingDrawing {
        VStack {
          Spacer()
          MoveDrawingBottomBar(onCancel: {
            exitMoveDrawingMode(reselectSource: true)
          })
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
        .zIndex(51)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .postHogScreenView("Home")
    .alert("Subscription Ended", isPresented: $subscriptionManager.subscriptionJustExpired) {
      Button("OK") {
        subscriptionManager.acknowledgeExpiry()
      }
    } message: {
      Text("Your Joodle Pro subscription has ended. Some features are now limited.")
    }
    .sheet(isPresented: $showPostTrialSheet, onDismiss: {
      // Ask for the App Store review right after the trial-ended sheet goes
      // away — the user just lived a week with full Pro, so perceived value
      // peaks here. Never for the never-claimed path, and never stacked on
      // top of the sheet itself.
      if !postTrialOfferExpired {
        ReviewRequestManager.shared.requestReviewAfterTrialEnded()
      }
    }) {
      StandalonePaywallView(
        source: postTrialOfferExpired ? "trial_offer_expired" : "trial_ended",
        context: .trialEnded(offerExpired: postTrialOfferExpired)
      )
    }
    .sheet(isPresented: $showTrialClaimSheet) {
      TrialClaimPaywallView(source: "doodle_limit")
    }
    .alert(String(localized: "Move Doodle"), isPresented: $showMoveConfirmation) {
      Button(String(localized: "Move"), role: .none) {
        executeMoveDrawing()
      }
      Button(String(localized: "Cancel"), role: .cancel) {
        // Stay in move mode — user can pick another date
        moveTargetDate = nil
      }
    } message: {
      if let targetDate = moveTargetDate {
        Text(String(localized: "Move your doodle to \(CalendarDate.from(targetDate).displayString)?"))
      }
    }
    .onAppear {
      // Sync widget data when app launches — batch subscription + entries into one reload pass
      WidgetHelper.shared.updateSubscriptionStatus(reload: false)
      WidgetHelper.shared.updateWidgetData(in: modelContext)

      // Refresh subscription status FIRST, then run the funnel's launch check
      Task {
        await subscriptionManager.updateSubscriptionStatus()

        // Post-trial sheet: one-time, on the next open after the trial ended
        // or the claim window lapsed. Must run AFTER the subscription refresh
        // so active subscribers never see it.
        if trialOfferManager.shouldPresentPostTrialSheet, !subscriptionManager.hasPremiumAccess {
          postTrialOfferExpired = trialOfferManager.postTrialReason == .offerExpired
          // Arm the 50%-off window first so the sheet renders with the live
          // promo price and countdown.
          await LimitedTimeOfferManager.shared.refresh()
          showPostTrialSheet = true
          trialOfferManager.markPostTrialSheetShown()
          AnalyticsManager.shared.track(
            .trialEndedSheetShown,
            properties: [.source: postTrialOfferExpired ? "offer_expired" : "trial_ended"]
          )
          // This launch belongs to the post-trial sheet; it already quotes
          // the promo price and countdown while the offer window is live, so
          // consume the offer sheet's auto-present instead of stacking a
          // second sheet. The Settings banner stays as the re-entry point.
          if LimitedTimeOfferManager.shared.shouldAutoPresent {
            LimitedTimeOfferManager.shared.markCurrentCampaignSeen()
          }
        } else {
          // Claim-offer auto-present: new installs at the doodle limit, and
          // legacy installs (winback) on their first open after the update.
          maybeAutoPresentClaimOffer()
        }
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      switch newPhase {
      case .background:
        // Avoid extra fetch/write contention if CloudKit is actively syncing while backgrounding.
        if cloudSyncManager.isSyncing {
          print("ContentView: Skipping background widget sync during active iCloud sync")
        } else {
          // App went to background - sync data one final time
          WidgetHelper.shared.updateWidgetData(in: modelContext)
        }
      case .active:
        // iOS may never wake the BGProcessingTask if the user rarely opens the
        // app. Catch up on foreground if the last auto-backup is overdue.
        BackupScheduler.shared.runBackupIfOverdue()
      default:
        break
      }
    }
    .onChange(of: showDrawingCanvas) { _, isShowing in
      // The 7th-doodle moment: the canvas just closed, possibly having saved
      // the doodle that used up the free allowance. Give the collapse
      // animation room, then offer the trial claim.
      guard !isShowing else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        maybeAutoPresentClaimOffer()
      }
    }
    .onChange(of: selectedDateFromWidget) { _, newDate in
      // Handle deep link from widget
      guard let date = newDate, let scrollProxy = scrollProxy else { return }
      guard !isMovingDrawing else { return }

      // Clear the binding after handling
      DispatchQueue.main.async {
        selectedDateFromWidget = nil
      }

      // Update selected year if needed
      let calendar = Calendar.current
      let year = calendar.component(.year, from: date)
      let yearChanged = year != dataProvider.selectedYear
      if yearChanged {
        dataProvider.selectedYear = year
      }

      // Calculate item ID directly from date (ID = timestamp of start of day)
      // This avoids dependency on itemsInYear which may not be updated yet after year change
      let startOfDay = calendar.startOfDay(for: date)
      let itemId = "\(Int(startOfDay.timeIntervalSince1970))"
      let dateItem = DateItem(id: itemId, date: startOfDay)

      // Use longer delay if year changed to allow view to re-render with new items
      let delay = yearChanged ? 0.3 : 0.1
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        dataProvider.selectDateItem(dateItem)
        scrollToRelevantDate(itemId: dateItem.id, scrollProxy: scrollProxy, anchor: .center)

        if pendingOpenCanvasFromShortcut || ShortcutActionState.pendingOpenCanvas {
          pendingOpenCanvasFromShortcut = false
          ShortcutActionState.pendingOpenCanvas = false
          entryHadDoodleOnCanvasOpen = selectedEntry?.drawingData != nil
          showDrawingCanvas = true
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .openDrawingCanvasFromShortcut)) { _ in
      guard !isMovingDrawing else { return }
      ShortcutActionState.pendingOpenCanvas = false
      if dataProvider.selectedDateItem != nil {
        entryHadDoodleOnCanvasOpen = selectedEntry?.drawingData != nil
        showDrawingCanvas = true
      } else {
        pendingOpenCanvasFromShortcut = true
      }
    }
  }

  // MARK: - Conversion Funnel

  /// Auto-presents the "7 days on us" claim paywall once, when the funnel
  /// says the offer is due (doodle limit reached, or legacy winback). Skipped
  /// while another surface owns the screen.
  private func maybeAutoPresentClaimOffer() {
    guard !showPostTrialSheet, !showTrialClaimSheet, !showDrawingCanvas else { return }
    let doodleCount = entries.filter { $0.drawingData?.isEmpty == false }.count
    if trialOfferManager.shouldAutoPresentClaimOffer(doodleCount: doodleCount) {
      trialOfferManager.markClaimOfferAutoPresented()
      showTrialClaimSheet = true
    }
  }

  // MARK: - Grid Interaction Callbacks

  /// Create callbacks for JoodleGridInteractionView
  private func createGridCallbacks(geometry: GeometryProxy, scrollProxy: ScrollViewProxy) -> GridInteractionCallbacks {
    GridInteractionCallbacks(
      onScrubbingBegan: { location in
        if isMovingDrawing { return }
        highlightedId = nil
        isScrubbing = true
        dataProvider.clearSelection()

        let newId = getItemId(at: location, for: geometry)
        if highlightedId == nil { Haptic.play(with: .medium) }
        highlightedId = newId
      },
      onScrubbingChanged: { location in
        if isMovingDrawing { return }
        let newId = getItemId(at: location, for: geometry)
        if newId != highlightedId { Haptic.play() }
        highlightedId = newId
      },
      onScrubbingEnded: { _ in
        if isMovingDrawing { return }
        if let highlightedId, let item = dataProvider.getItem(from: highlightedId) {
          selectDateItem(item: item, scrollProxy: scrollProxy)
        }
        highlightedId = nil
        isScrubbing = false
      },
      onTap: { location in
        if isScrubbing { return }

        // Move mode: tap selects a target date
        if isMovingDrawing {
          guard let itemId = getItemId(at: location, for: geometry),
                let item = dataProvider.getItem(from: itemId)
          else { return }
          handleMoveModeTap(item: item)
          return
        }

        guard let itemId = getItemId(at: location, for: geometry),
              let item = dataProvider.getItem(from: itemId)
        else { return }
        selectDateItem(item: item, scrollProxy: scrollProxy)
        Haptic.play()
      }
    )
  }

  /// Calculate spacing between dots based on view mode
  private func calculateSpacing(containerWidth: CGFloat, viewMode: ViewMode) -> CGFloat {
    CalendarGridHelper.calculateSpacing(containerWidth: containerWidth, viewMode: viewMode)
  }

  // MARK: User interactions
  private func handlePinchChanged(value: MagnificationGesture.Value) {
    if isMovingDrawing { return }  // No view mode changes in move mode
    if isPinching { return }

    isPinching = true

    // Clean up any ongoing drag gesture state when pinch begins
    highlightedId = nil
  }

  private func handlePinchEnded(value: MagnificationGesture.Value) {
    isPinching = false
    highlightedId = nil

    // Pinch in: switch from "now" to "year" mode
    if value < scaleThreshold && dataProvider.viewMode == .now {
      toggleViewMode(to: .year)
    }
    // Pinch out: switch from "year" to "now" mode
    else if value > expandThreshold && dataProvider.viewMode == .year {
      toggleViewMode(to: .now)
    }
  }

  // MARK: - Hit Testing (O(1) Optimized)

  /// Get the item id for a particular CGPoint location using pre-calculated hit testing grid
  private func getItemId(at location: CGPoint, for geometry: GeometryProxy) -> String? {
    // Use fast O(1) lookup if grid is built
    if let metrics = gridMetrics, !hitTestingGrid.isEmpty {
      return getItemIdFromGrid(at: location, metrics: metrics)
    }

    // Fallback to original method and rebuild grid
    buildHitTestingGrid(for: geometry)
    if let metrics = gridMetrics {
      return getItemIdFromGrid(at: location, metrics: metrics)
    }

    return getItemIdLegacy(at: location, for: geometry)
  }

  /// Fast O(1) hit testing using pre-built grid
  private func getItemIdFromGrid(at location: CGPoint, metrics: GridMetrics) -> String? {
    let adjustedLocation = adjustTouchLocationForGrid(location)
    let adjustedX = adjustedLocation.x - metrics.offsetX
    let adjustedY = adjustedLocation.y - metrics.offsetY

    // Account for dot centering - dots are positioned with their centers, so we need to
    // adjust hit testing to match. We need half spacing + half dot size + adjusted Y position
    let spacing = calculateSpacing(containerWidth: yearGridViewSize.width, viewMode: dataProvider.viewMode)
    let centeredY = adjustedY + (spacing / 2) + (dataProvider.viewMode.dotSize / 2)
    let row = max(0, Int(floor(centeredY / metrics.rowHeight)))
    let col = max(0, Int(floor(adjustedX / metrics.colWidth)))

    guard row < hitTestingGrid.count,
          col < hitTestingGrid[row].count
    else { return nil }

    return hitTestingGrid[row][col]
  }

  /// Build hit testing grid for fast lookups
  private func buildHitTestingGrid(for geometry: GeometryProxy) {
    let spacing = calculateSpacing(containerWidth: geometry.size.width, viewMode: dataProvider.viewMode)
    let containerWidth = geometry.size.width - (2 * GRID_HORIZONTAL_PADDING)
    let totalSpacingWidth = CGFloat(dataProvider.viewMode.dotsPerRow - 1) * spacing
    let totalDotWidth = containerWidth - totalSpacingWidth
    let itemSpacing = totalDotWidth / CGFloat(dataProvider.viewMode.dotsPerRow)

    let rowHeight = dataProvider.viewMode.dotSize + spacing
    let colWidth = itemSpacing + spacing
    let startX = itemSpacing / 2

    // Store metrics for fast access
    gridMetrics = GridMetrics(
      rowHeight: rowHeight,
      colWidth: colWidth,
      startX: startX,
      offsetX: startX - colWidth / 2,
      offsetY: 0  // No additional Y offset needed since we account for header in adjustTouchLocationForGrid
    )

    // Build 2D grid accounting for leading empty slots
    let numberOfRows = CalendarGridHelper.totalRows(
      forItemCount: dataProvider.itemsInYear.count,
      viewMode: dataProvider.viewMode,
      year: dataProvider.selectedYear
    )
    hitTestingGrid = Array(
      repeating: Array(repeating: nil, count: dataProvider.viewMode.dotsPerRow), count: numberOfRows)

    for (index, item) in dataProvider.itemsInYear.enumerated() {
      // Use CalendarGridHelper for grid position (accounts for leading empty slots)
      let (row, col) = CalendarGridHelper.gridPosition(
        forItemIndex: index,
        viewMode: dataProvider.viewMode,
        year: dataProvider.selectedYear
      )
      hitTestingGrid[row][col] = item.id
    }
  }

  /// Legacy hit testing method (fallback)
  private func getItemIdLegacy(at location: CGPoint, for geometry: GeometryProxy) -> String? {
    let adjustedLocation = adjustTouchLocationForGrid(location)

    // Use CalendarGridHelper for hit testing (handles all grid math and calendar alignment)
    return CalendarGridHelper.itemId(
      at: adjustedLocation,
      containerWidth: geometry.size.width,
      viewMode: dataProvider.viewMode,
      year: dataProvider.selectedYear,
      items: dataProvider.itemsInYear,
      horizontalPaddingAdjustment: false  // Already adjusted by adjustTouchLocationForGrid
    )
  }

  private func selectDateItem(item: DateItem, scrollProxy: ScrollViewProxy) {
    // Don't create entry here - only create when user actually saves content
    // This prevents empty entries from being created just by selecting a date
    dataProvider.selectDateItem(item)
    scrollToRelevantDate(itemId: item.id, scrollProxy: scrollProxy)

  }

  /// Toggle the view mode to a specific mode
  private func toggleViewMode(to newViewMode: ViewMode) {
    let previousMode = dataProvider.viewMode.rawValue

    // Use a spring animation for morphing effect
    withAnimation(.springFkingSatifying) {
      dataProvider.toggleViewMode(to: newViewMode)
    }

    // Track view mode change
    AnalyticsManager.shared.trackViewModeChanged(to: newViewMode.rawValue, from: previousMode)
  }

  // MARK: - Move Drawing Mode

  /// Enter move drawing mode — store source entry and collapse bottom panel
  private func enterMoveDrawingMode() {
    guard let entry = selectedEntry,
          entry.drawingData != nil,
          !(entry.drawingData?.isEmpty ?? true),
          let date = dataProvider.selectedDateItem?.date
    else { return }

    moveSourceEntry = entry
    moveSourceDate = date

    // Switch to regular view if currently in minimized mode
    if dataProvider.viewMode != .now {
      withAnimation(.springFkingSatifying) {
        dataProvider.toggleViewMode(to: .now)
      }
    }

    // Collapse bottom panel by clearing selection
    dataProvider.clearSelection()

    // Activate move mode after a brief delay so the panel collapse animation plays
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      withAnimation(.springFkingSatifying) {
        isMovingDrawing = true
      }
      let bounds = UIScreen.main.bounds
      rippleOrigin = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
      rippleTrigger += 1
    }

    Haptic.play(with: .medium)
  }

  /// Exit move drawing mode and optionally re-select the source date
  private func exitMoveDrawingMode(reselectSource: Bool = true) {
    withAnimation(.springFkingSatifying) {
      isMovingDrawing = false
    }

    // Re-open the source entry if requested (e.g. on cancel)
    if reselectSource, let date = moveSourceDate, let scrollProxy {
      let itemId = dataProvider.getItemId(for: date)
      let item = DateItem(id: itemId, date: Calendar.current.startOfDay(for: date))
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        selectDateItem(item: item, scrollProxy: scrollProxy)
      }
    }

    moveSourceEntry = nil
    moveSourceDate = nil
    moveTargetDate = nil
  }

  /// Handle a tap in move drawing mode — check if target is valid and show confirmation
  private func handleMoveModeTap(item: DateItem) {
    // Check if target has a drawing already
    let targetEntry = entries.first(where: { $0.matches(date: item.date) })
    let targetHasDrawing = targetEntry?.drawingData != nil && !(targetEntry?.drawingData?.isEmpty ?? true)

    // Ignore taps on dates that already have drawings
    if targetHasDrawing { return }

    // Ignore taps on the source date itself
    if let sourceDate = moveSourceDate,
       Calendar.current.isDate(item.date, inSameDayAs: sourceDate) {
      return
    }

    // Valid target — show confirmation
    moveTargetDate = item.date
    showMoveConfirmation = true
    Haptic.play()
  }

  /// Execute the drawing move from source to target date
  private func executeMoveDrawing() {
    guard let targetDate = moveTargetDate,
          let sourceDate = moveSourceDate
    else { return }

    // Re-fetch source entry to ensure it's fresh
    let freshSourceEntry = DayEntry.findOrCreate(for: sourceDate, in: modelContext)
    guard freshSourceEntry.drawingData != nil && !(freshSourceEntry.drawingData?.isEmpty ?? true) else {
      // Drawing was somehow removed — exit move mode
      exitMoveDrawingMode(reselectSource: false)
      return
    }

    // 1. Get or create the target entry
    let targetEntry = DayEntry.findOrCreate(for: targetDate, in: modelContext)

    // 2. Move drawing data
    targetEntry.drawingData = freshSourceEntry.drawingData
    targetEntry.drawingThumbnail20 = freshSourceEntry.drawingThumbnail20
    targetEntry.drawingThumbnail200 = freshSourceEntry.drawingThumbnail200

    // 3. Clear drawing from source
    freshSourceEntry.drawingData = nil
    freshSourceEntry.drawingThumbnail20 = nil
    freshSourceEntry.drawingThumbnail200 = nil

    // 4. If source entry is now empty (no text, no drawing), delete it
    if freshSourceEntry.body.isEmpty {
      freshSourceEntry.deleteAllForSameDate(in: modelContext)
    }

    // 5. Save
    try? modelContext.save()

    // 6. Sync widgets
    WidgetHelper.shared.scheduleWidgetDataUpdate(in: modelContext)

    // 7. Track analytics
    AnalyticsManager.shared.trackDrawingMoved(
      fromDate: CalendarDate.from(sourceDate).dateString,
      toDate: CalendarDate.from(targetDate).dateString
    )

    // 8. Haptic feedback
    Haptic.play(with: .medium)

    // 9. Exit move mode and select the target date
    let targetItemId = dataProvider.getItemId(for: targetDate)
    let targetItem = DateItem(id: targetItemId, date: Calendar.current.startOfDay(for: targetDate))

    withAnimation(.springFkingSatifying) {
      isMovingDrawing = false
    }
    moveSourceEntry = nil
    moveSourceDate = nil
    moveTargetDate = nil

    // Select the target date to show the moved drawing
    if let scrollProxy {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        selectDateItem(item: targetItem, scrollProxy: scrollProxy)
      }
    }
  }

  /// Set of dateStrings that have drawings (for move mode target filtering)
  private var datesWithDrawings: Set<String> {
    Set(entries.compactMap { entry in
      guard let data = entry.drawingData, !data.isEmpty else { return nil }
      return entry.dateString
    })
  }

  /// Source date string for the drawing being moved
  private var moveSourceDateString: String? {
    guard let date = moveSourceDate else { return nil }
    return CalendarDate.from(date).dateString
  }

  // MARK: Layout Calculations
  /// Scrolls to center the selected item by its ID
  private func scrollToRelevantDate(
    itemId: String, scrollProxy: ScrollViewProxy, anchor: UnitPoint? = nil
  ) {
    // When centering with bottom view visible, offset downward to account for the header overlay
    // so the item lands at the true visual center of the unobscured area.
    // Only apply when the top view is compressed (bottom view shown), not at fullscreen.
    let effectiveAnchor: UnitPoint?
    if anchor == .center, isBottomViewVisible, yearGridViewSize.height > 0 {
      effectiveAnchor = UnitPoint(x: 0.5, y: 0.5 + (headerHeight - 40) / (2 * yearGridViewSize.height) )
    } else {
      effectiveAnchor = anchor
    }
    withAnimation(.springFkingSatifying) {
      scrollProxy.scrollTo(itemId, anchor: effectiveAnchor)
    }
  }

  /// Scrolls to today's date or first day of year
  private func scrollToTodayOrTop(scrollProxy: ScrollViewProxy) {
    let currentYear = Calendar.current.component(.year, from: Date())

    withAnimation(.springFkingSatifying) {
      if dataProvider.selectedYear != currentYear {
        // For non-current years, scroll to the top spacer to show first row properly
        scrollProxy.scrollTo("topSpacer", anchor: .top)
      } else {
        let targetId = dataProvider.getRelevantDateId(for: Date())
        scrollProxy.scrollTo(targetId, anchor: .center)
      }
    }
  }

  private func getFormattedDate(_ date: Date) -> String {
    return date.formatted(date: .abbreviated, time: .omitted)
  }

  /// Ask the drawing canvas to run its save flow (saving state UI → persist),
  /// after which it drives the actual collapse via its `onDismiss`. This keeps
  /// the synchronous CloudKit save from freezing the collapse animation — the
  /// canvas shows an explicit saving state instead, then dismisses smoothly.
  private func requestCanvasSaveAndDismiss() {
    // Disallow dismissing the canvas while the camera reference is live. The
    // user returns to drawing mode via the in-canvas exit-camera button
    // (`cancelLive`) and dismisses from there. Dismissing straight from live
    // mode raced the camera-session teardown against the container collapse —
    // leaving the canvas stuck black — and there's already a clear way back.
    if cameraContext.mode == .live {
      return
    }
    // Also block while the shutter is mid-cycle (close → camera swap → open):
    // dismissing mid-cycle races the camera session lifecycle (we've seen it
    // crash on `stopRunning` during the prep config lock). Once the cycle
    // settles the user can dismiss normally.
    if cameraContext.isShutterCycling {
      return
    }
    canvasSaveDismissTrigger = true
  }

  private func performDrawingCanvasDismiss() {
    let selectedDate = dataProvider.selectedDateItem?.date

    // Close the drawing canvas first
    showDrawingCanvas = false

    // Check if we should show note prompt popup
    // Conditions: setting is enabled, entry didn't have doodle when canvas opened, and now has doodle
    guard userPreferences.promptForNotesAfterDoodling,
          !entryHadDoodleOnCanvasOpen,
          let date = selectedDate
    else { return }

    // Get the entry for this date
    let entry = entries.first(where: { $0.matches(date: date) })

    // Check if the entry now has drawing data (user actually saved something new)
    let entryHasDrawingNow = entry?.drawingData != nil

    // Only show prompt if: entry had no doodle before AND has doodle now
    guard entryHasDrawingNow else { return }

    // Don't show prompt if entry already has notes
    let entryHasNotes = !(entry?.body.isEmpty ?? true)
    guard !entryHasNotes else { return }

    // Store the date for saving notes later
    dateForNotePrompt = date

    // Show the note prompt popup after a short delay for smooth transition
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      withAnimation {
        showNotePromptPopup = true
      }
    }
  }

  /// Save note from the popup to the entry
  private func saveNoteForEntry(note: String) {
    guard let date = dateForNotePrompt else { return }

    // Find or create entry for this date
    let entryToUpdate = DayEntry.findOrCreate(for: date, in: modelContext)
    entryToUpdate.body = note

    try? modelContext.save()

    // Sync note to widgets
    WidgetHelper.shared.scheduleWidgetDataUpdate(in: modelContext)

    // Defer clearing until after the popup's dismiss animation completes,
    // so the doodle preview keeps its drawing data while the dialog animates out.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      dateForNotePrompt = nil
    }
  }

  /// Adjusts the touch location from the parent coordinate system to the grid's coordinate system
  private func adjustTouchLocationForGrid(_ location: CGPoint) -> CGPoint {
    // Adjust for the header height and horizontal padding
    return CGPoint(
      x: location.x - GRID_HORIZONTAL_PADDING,
      y: location.y
    )
  }
}

#Preview {
  ContentView(selectedDateFromWidget: .constant(nil))
    .modelContainer(for: DayEntry.self, inMemory: true)
    .environment(\.userPreferences, UserPreferences.shared)
    .preferredColorScheme(.light)
}
