//
//  InteractiveTutorialView.swift
//  Joodle
//
//  Interactive tutorial view that teaches users app features in a sandboxed environment.
//

import SwiftUI

struct InteractiveTutorialView: View {
    /// ViewModel for onboarding flow (nil when used standalone from Settings)
    private var viewModel: OnboardingViewModel?

    // Tutorial state
    @StateObject private var coordinator: TutorialCoordinator
    @StateObject private var mockStore: MockDataStore

    // Animation state
    @State private var hasAnimatedIn = false
    @State private var gridOpacity: Double = 0
    @State private var overlayOpacity: Double = 0

    // Transition safety: blocks all grid interactions until overlay is ready
    @State private var isTransitionComplete = false

    // View state
    @State private var showDrawingCanvas = false
    @State private var showReminderSheet = false
    /// Stub camera context — feature is fully gated behind isMockMode and never activates here.
    @StateObject private var tutorialCameraContext = CameraReferenceContext()
    @State private var isScrubbing = false
    @State private var highlightedId: String?

    // Scroll state for auto-scrolling to doodle
    @State private var scrollProxy: ScrollViewProxy?
    @State private var hasScrolledToEntry = false

    // Move mode confirmation alert state
    @State private var moveTutorialTargetDate: Date?
    @State private var showMoveTutorialConfirmation = false

    // Standalone mode state (for black screen fix when presented as fullScreenCover)
    @State private var isReady = false
    @State private var forceRefresh = UUID()

    // Configuration
    let singleStepMode: Bool
    let startingStepType: TutorialStepType?
    let onDismiss: (() -> Void)?

    /// Whether this is shown during onboarding (vs from Settings)
    var isOnboarding: Bool {
        viewModel != nil && !singleStepMode
    }

    /// Whether the current step is a gesture hint step (fully interactable screen)
    private var isGestureHintStep: Bool {
        guard let step = coordinator.currentStep else { return false }
        if case .gesture = step.highlightAnchor {
            return true
        }
        return false
    }

    /// Whether the current step is the scrubbing step (disable scroll to prevent accidental scrolling)
    private var isScrubbingStep: Bool {
        coordinator.currentStep?.type == .scrubbing
    }

    /// Whether the current step is the moveDrawing step (disable tap-to-edit on drawing)
    private var isMoveDrawingStep: Bool {
        coordinator.currentStep?.type == .moveDrawing
    }

    // MARK: - Init (Onboarding mode)

    init(
        viewModel: OnboardingViewModel,
        singleStepMode: Bool = false,
        startingStepType: TutorialStepType? = nil
    ) {
        self.viewModel = viewModel
        self.singleStepMode = singleStepMode
        self.startingStepType = startingStepType
        self.onDismiss = nil

        let steps = singleStepMode && startingStepType != nil
            ? TutorialSteps.singleStep(startingStepType!)
            : TutorialSteps.onboarding

        let startIndex = startingStepType != nil && !singleStepMode
            ? TutorialSteps.startingIndex(for: startingStepType!)
            : 0

        _coordinator = StateObject(wrappedValue: TutorialCoordinator(
            steps: steps,
            startingIndex: startIndex,
            singleStepMode: singleStepMode,
            onComplete: { }
        ))

        _mockStore = StateObject(wrappedValue: MockDataStore())
    }

    // MARK: - Init (Standalone mode from Settings)

    init(
        stepType: TutorialStepType,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = nil
        self.singleStepMode = true
        self.startingStepType = stepType
        self.onDismiss = onDismiss

        let steps = TutorialSteps.singleStep(stepType)

        _coordinator = StateObject(wrappedValue: TutorialCoordinator(
            steps: steps,
            startingIndex: 0,
            singleStepMode: true,
            onComplete: { }
        ))

        _mockStore = StateObject(wrappedValue: MockDataStore())
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Background always visible (prevents black screen in standalone mode)
            Color.backgroundColor
                .ignoresSafeArea()

            // Main content - conditionally rendered for standalone mode
            if isOnboarding || isReady {
                GeometryReader { geometry in
                    ZStack {
                        // Main tutorial content
                        tutorialContent(geometry: geometry)
                            .opacity(gridOpacity)

                        // Floating drawing canvas — uniform across all devices.
                        DynamicIslandExpandedView(
                            isExpanded: $showDrawingCanvas,
                            content: {
                                DrawingCanvasView(
                                    date: mockStore.selectedDateItem?.date ?? Date(),
                                    entry: nil,
                                    onDismiss: {
                                        showDrawingCanvas = false
                                    },
                                    isShowing: showDrawingCanvas,
                                    mockStore: mockStore,
                                    mockEntry: mockStore.selectedEntry
                                )
                                .environmentObject(tutorialCameraContext)
                            },
                            hidden: false,
                            onDismiss: {
                                showDrawingCanvas = false
                            },
                            tutorialAnchorID: "drawingCanvas",
                            // The tutorial drives canvas dismissal explicitly
                            // per step; a stray backdrop tap must not close the
                            // canvas out of band and wedge the flow.
                            dismissOnTapOutside: false
                        )

                        // Gesture-blocking overlay during transition (before tutorial overlay is ready)
                        // This prevents accidental taps on the grid during the scroll animation
                        if !isTransitionComplete {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .allowsHitTesting(true)
                                .onTapGesture { } // Absorb all taps
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { _ in } // Absorb all drags
                                )
                                .ignoresSafeArea()
                        }

                        // Move drawing mode overlays (shown instead of tutorial overlay)
                        if mockStore.isInMoveMode {
                            MoveDrawingGradientBorder()
                                .ignoresSafeArea()
                                .allowsHitTesting(false)
                                .transition(.opacity)

                            // Tutorial instruction anchored at top center
                            VStack(spacing: 0) {
                                Spacer().frame(height: geometry.safeAreaInsets.top + 20)
                                Text(String(localized: "Tap any date to move your doodle there"))
                                    .font(.appSubheadline(weight: .medium))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Capsule().fill(Color.appAccent.opacity(0.9)))
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            .allowsHitTesting(false)
                            .transition(.move(edge: .top).combined(with: .opacity))

                        }

                        // Camera-reference tutorial: floating shutter while live.
                        // Mirrors the real app's ContentView shutter placement so
                        // the user can capture without leaving the tutorial.
                        if tutorialCameraContext.mode == .live {
                            VStack {
                                Spacer()
                                ShutterButton(style: .glass) {
                                    Task { await tutorialCameraContext.capture() }
                                }
                                .disabled(tutorialCameraContext.isShutterCycling)
                                .tutorialHighlightAnchor(.button(id: .shutterButton), cornerRadius: 36)
                                .padding(.bottom, 32)
                            }
                            .ignoresSafeArea(.container, edges: .bottom)
                            .transition(.opacity)
                        }

                        // Tutorial overlay (dimmed with cutout + tooltip)
                        // Hidden while in move mode — move mode UI provides instructions
                        if coordinator.isActive && hasAnimatedIn && !mockStore.isInMoveMode {
                            TutorialOverlayView(
                                coordinator: coordinator,
                                onSkip: { skipCurrentStep() }
                            )
                            .opacity(overlayOpacity)
                        }

                        #if DEBUG
                        // Debug overlay for development - now draggable
                        TutorialDebugOverlay(coordinator: coordinator)
                        #endif
                    }
                    .onPreferenceChange(HighlightFramePreferenceKey.self) { frames in
                        #if DEBUG
                        // Debug: Log bellIcon frame registration
                        if let bellFrame = frames[TutorialButtonId.bellIcon.rawValue] {
                            print("🔔 [addReminder] bellIcon frame: \(Int(bellFrame.minX)),\(Int(bellFrame.minY)) ✓")
                        }
                        #endif

                        frames.forEach { key, frame in
                            coordinator.registerHighlightFrame(id: key, frame: frame)
                        }
                    }
                    .onPreferenceChange(HighlightCornerRadiusPreferenceKey.self) { radii in
                        radii.forEach { key, radius in
                            coordinator.registerHighlightCornerRadius(id: key, cornerRadius: radius)
                        }
                    }
                }
                .id(forceRefresh)  // Force view recreation on refresh (standalone mode)
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            setupInitialState()
            animateIn()
        }
        .task {
            // For standalone mode: delay to ensure fullScreenCover transition completes
            if !isOnboarding {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds
                await MainActor.run {
                    forceRefresh = UUID()
                    withAnimation(.easeIn(duration: 0.2)) {
                        isReady = true
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tutorialPrerequisiteNeeded)) { notification in
            handlePrerequisite(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tutorialDoubleTapCompleted)) { _ in
            handleDoubleTapCompleted()
        }
        .onChange(of: mockStore.viewMode) { oldValue, newValue in
            handleViewModeChange(from: oldValue, to: newValue)
        }
        .onChange(of: mockStore.selectedYear) { oldValue, newValue in
            handleYearChange(from: oldValue, to: newValue)
        }
        .onChange(of: showDrawingCanvas) { oldValue, newValue in
            handleDrawingCanvasChange(from: oldValue, to: newValue)
        }
        .onChange(of: showReminderSheet) { oldValue, newValue in
            handleReminderSheetChange(from: oldValue, to: newValue)
        }
        .onChange(of: isScrubbing) { oldValue, newValue in
            handleScrubbingChange(from: oldValue, to: newValue)
        }
        .onChange(of: tutorialCameraContext.mode) { _, newValue in
            if newValue == .live {
                _ = coordinator.checkEndCondition(.cameraLiveEntered)
            }
        }
        .onChange(of: tutorialCameraContext.captureFlashID) { oldValue, newValue in
            // captureFlashID is bumped exactly once per shutter capture.
            if oldValue != newValue, newValue != nil {
                _ = coordinator.checkEndCondition(.cameraReferenceCaptured)
            }
        }
        .onChange(of: coordinator.currentStepIndex) { _, _ in
            handleStepChange()
        }
        // Safety: If bottom view appears during scrubbing step transition, dismiss it and re-scroll
        .onChange(of: mockStore.selectedDateItem) { oldValue, newValue in
            handleSelectionChangeDuringTransition(from: oldValue, to: newValue)
        }
        // Watch for tutorial completion to navigate to next step or dismiss
        .onChange(of: coordinator.isActive) { oldValue, newValue in
            // Tutorial just became inactive (completed)
            if oldValue == true && newValue == false {
                if isOnboarding {
                    viewModel?.completeStep(.yearGridDemo)
                } else {
                    onDismiss?()
                }
            }
        }
    }

    // MARK: - Step Skipping

    /// Called when the user taps "Next" on a tooltip. Performs the state
    /// mutation the step's interaction would normally produce, so the next
    /// step's anchor has a real target and the existing end-condition
    /// observers can fire `advance()` naturally. Falls through to a plain
    /// `coordinator.advance()` for steps that don't need state changes.
    private func skipCurrentStep() {
        guard let step = coordinator.currentStep else {
            coordinator.advance()
            return
        }

        switch step.endCondition {
        case .scrubEnded:
            // Selecting today triggers the same selection state a real scrub
            // ends with; handleScrubbingChange advances when isScrubbing goes
            // back to false, so call advance directly here.
            mockStore.selectDate(Date())
            coordinator.advance()

        case .buttonTapped(let id):
            switch id {
            case .paintButton:
                // Open the canvas — handlePaintButtonTapped advances itself.
                handlePaintButtonTapped()
            case .cameraButton:
                // Entering live mode fires the `.cameraLiveEntered` observer.
                Task { await tutorialCameraContext.enterLive() }
            case .shutterButton, .canvasSaveButton, .centerHandle, .viewModeButton, .yearSelector, .bellIcon:
                // No straightforward simulation for these button taps — just
                // advance. (None of them are currently used with the
                // .buttonTapped end condition except .paintButton.)
                coordinator.advance()
            }

        case .viewDismissed(let viewId):
            if viewId == "drawingCanvas", showDrawingCanvas {
                // Closing the canvas fires handleDrawingCanvasChange which
                // advances on the .viewDismissed end condition.
                showDrawingCanvas = false
            } else {
                // The canvas is already closed (e.g. it was dismissed out of
                // band during the camera-reference flow), so assigning
                // `showDrawingCanvas = false` again would be a no-op and fire
                // no onChange — leaving the tutorial wedged. Advance directly.
                coordinator.advance()
            }

        case .viewModeChanged(let mode):
            // handleViewModeChange advances when the mode lands on `mode`.
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                mockStore.viewMode = mode
            }

        case .pinchGestureCompleted:
            // Pinch-out completes by going from .year → .now. The same handler
            // also covers this transition.
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                mockStore.viewMode = .now
            }

        case .yearChanged:
            // handleYearChange advances on any selectedYear delta.
            let currentYear = Calendar.current.component(.year, from: Date())
            withAnimation {
                mockStore.selectedYear = currentYear + 1
            }

        case .sheetDismissed:
            // handleReminderSheetChange advances when the sheet closes.
            showReminderSheet = false
            // If the sheet wasn't open (user skipped before opening it),
            // there's nothing to dismiss — advance directly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if coordinator.currentStep?.endCondition == .sheetDismissed {
                    coordinator.advance()
                }
            }

        case .doubleTapCompleted:
            // Nothing to simulate visually — just advance.
            coordinator.advance()

        case .drawingMoved:
            // The user is in move-mode (no anchor). Exit move-mode cleanly and
            // advance; this is the last step, so advance kicks off completion.
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                mockStore.exitMoveMode()
            }
            coordinator.advance()

        case .moveContextMenuOptionTapped:
            // Same path as a real "Move to Another Date" tap.
            handleMoveDrawingRequested()

        case .cameraLiveEntered:
            // Mirrors what tapping the camera button does — but only when the
            // camera is actually usable. If access was denied/restricted,
            // entering live is impossible and re-invoking it would just
            // re-trigger the permission-denied alert in a loop, trapping the
            // user. Skip the whole camera-reference segment instead.
            if tutorialCameraContext.isCameraAccessBlocked {
                skipCameraReferenceSegment()
            } else {
                Task { await tutorialCameraContext.enterLive() }
            }

        case .cameraReferenceCaptured:
            // Fake a capture so step D's "canvas with backdrop" is reachable.
            // If the live session is actually running, capture for real;
            // otherwise just bump the flash ID + reset mode so the observer
            // fires and the canvas comes back.
            if tutorialCameraContext.mode == .live {
                Task { await tutorialCameraContext.capture() }
            } else {
                tutorialCameraContext.captureFlashID = UUID()
            }
        }
    }

    /// Advance past every remaining consecutive `.cameraReference` step. Used
    /// when camera access is unavailable so the user isn't trapped on a step
    /// whose (camera-dependent) end condition can never be satisfied.
    private func skipCameraReferenceSegment() {
        // Close the canvas if the segment left it open, so the next step starts
        // from a clean state.
        if showDrawingCanvas {
            showDrawingCanvas = false
        }
        while coordinator.currentStep?.type == .cameraReference {
            let wasLastStep = coordinator.isLastStep
            coordinator.advance()
            // advance() on the last step kicks off the completion sequence
            // without moving currentStepIndex, so stop looping to avoid a hang.
            if wasLastStep { break }
        }
    }

    // MARK: - Tutorial Content

    @ViewBuilder
    private func tutorialContent(geometry: GeometryProxy) -> some View {
        let itemsSpacing = calculateSpacing(
            containerWidth: geometry.size.width,
            viewMode: mockStore.viewMode
        )

        ZStack(alignment: .top) {
            // Resizable split view with grid and entry editing
            ResizableSplitView(
                top: {
                    // Year grid with ScrollViewReader for auto-scrolling
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 0) {
                                Spacer().frame(height: 100)

                                // Use shared JoodleGridInteractionView for gesture handling
                                JoodleGridInteractionView(
                                    dataProvider: mockStore,
                                    geometry: geometry,
                                    isScrubbing: $isScrubbing,
                                    highlightedId: highlightedId,
                                    callbacks: createGridCallbacks(geometry: geometry),
                                    minimumPressDuration: 0.3,
                                    allowsHitTesting: true,
                                    overlayContent: AnyView(
                                        todayEntryAnchorOverlay(geometry: geometry, itemsSpacing: itemsSpacing)
                                    ),
                                    isInMoveMode: mockStore.isInMoveMode,
                                    moveSourceDateString: mockStore.moveSourceDateString
                                )

                                // Extra space at bottom for scrolling
                                Spacer().frame(height: 200)
                            }
                        }
                        .background(Color.backgroundColor)
                        // Disable scroll during scrubbing step (prevents accidental scroll when tap doesn't hold long enough)
                        // Also disable when actively scrubbing
                        .scrollDisabled(isScrubbingStep || isScrubbing)
                        .onAppear {
                            scrollProxy = proxy
                        }
                    }
                },
                bottom: {
                    // Entry editing view - using real view with mock store
                    EntryEditingView(
                        date: mockStore.selectedDateItem?.date,
                        onOpenDrawingCanvas: { _ in
                            handlePaintButtonTapped()
                        },
                        onFocusChange: nil,
                        mockStore: mockStore,
                        tutorialMode: true,
                        showReminderSheetBinding: $showReminderSheet,
                        onMoveDrawingRequested: { _ in
                            handleMoveDrawingRequested()
                        },
                        disableDrawingTap: isMoveDrawingStep
                    )
                },
                hasBottomView: mockStore.selectedDateItem != nil,
                onBottomDismissed: {
                    mockStore.clearSelection()
                },
                onTopViewHeightChange: { _ in
                    // When bottom view appears/resizes, scroll to keep selected entry visible
                    scrollToSelectedEntry()
                },
                tutorialMode: true,
                allowHandleDrag: isGestureHintStep  // Allow dragging during gesture hint steps
            )
            .ignoresSafeArea(.container, edges: .bottom)

            // Header - using custom tutorial header that only shows year
            TutorialHeaderView(
                mockStore: mockStore,
                geometry: geometry,
                highlightedItemId: highlightedId,
                entries: mockEntriesToDayEntries()
            )
        }
        // Reminder sheet - using real view with mock store
        .sheet(isPresented: $showReminderSheet) {
            if let date = mockStore.selectedDateItem?.date {
                ReminderSheet(
                    dateString: CalendarDate.from(date).dateString,
                    entryBody: mockStore.selectedEntry?.body,
                    mockStore: mockStore
                )
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
            }
        }
        // Move confirmation alert (matches real app flow)
        .alert(String(localized: "Move Doodle"), isPresented: $showMoveTutorialConfirmation) {
            Button(String(localized: "Move"), role: .none) {
                if let targetDate = moveTutorialTargetDate {
                    mockStore.performMockMove(to: targetDate)
                    _ = coordinator.checkEndCondition(.drawingMoved)
                }
                moveTutorialTargetDate = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                moveTutorialTargetDate = nil
            }
        } message: {
            if let targetDate = moveTutorialTargetDate {
                Text(String(localized: "Move your doodle to \(CalendarDate.from(targetDate).displayString)?"))
            }
        }
    }

    @ViewBuilder
    private func todayEntryAnchorOverlay(geometry: GeometryProxy, itemsSpacing: CGFloat) -> some View {
        let todayIndex = getTodayIndex()
        let dotSize = mockStore.viewMode.dotSize

        // Use CalendarGridHelper for grid position calculation (accounts for leading empty slots)
        let (row, col) = CalendarGridHelper.gridPosition(
            forItemIndex: todayIndex,
            viewMode: mockStore.viewMode,
            year: mockStore.selectedYear
        )
      let x = GRID_HORIZONTAL_PADDING + CGFloat(col) * (dotSize + itemsSpacing) - dotSize * 1.5
      let y = CGFloat(row) * (dotSize + itemsSpacing) - dotSize * 1.5

        // Position a small anchor view exactly at today's entry location
        // and use GeometryReader on that specific view to get accurate frame
        Color.clear
            .frame(width: dotSize * 4, height: dotSize * 4)
            .background(
                GeometryReader { entryGeo in
                    Color.clear
                        .preference(
                            key: HighlightFramePreferenceKey.self,
                            value: ["gridEntry.0": entryGeo.frame(in: .global)]
                        )
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: x, y: y)
    }

    // MARK: - Setup & Animation

    private func setupInitialState() {
        if isOnboarding {
            // Onboarding mode: use user's doodle from onboarding flow
            if let drawingData = viewModel?.firstJoodleData {
                mockStore.populateUserDrawing(drawingData)
            } else {
                mockStore.populateUserDrawing(PLACEHOLDER_DATA)
            }
        } else {
            // Standalone mode: setup based on step type
            mockStore.populateUserDrawing(PLACEHOLDER_DATA)

            switch startingStepType {
            case .scrubbing:
                break // Just need the grid with today's entry visible

            case .quickSwitchToday:
                // Need bottom view visible so center handle is shown
                mockStore.selectDate(Date())

            case .drawAndEdit:
                // First sub-step needs EntryEditingView open to show paint button
                mockStore.selectDate(Date())

            case .switchViewMode:
                // First sub-step needs viewModeButton visible (always in header)
                break

            case .switchYear:
                // Year selector is always visible in header
                break

            case .addReminder:
                // Need future year with anniversary entry, and EntryEditingView open
                mockStore.ensureFutureYear()
                mockStore.populateAnniversaryEntry()

            case .moveDrawing:
                // Need EntryEditingView open so user can see drawing and access context menu
                mockStore.selectDate(Date())

            case .cameraReference:
                // Need an empty entry for today so the canvas opens without an
                // existing drawing (camera button only shows on an empty canvas).
                // Also opt the sandboxed canvas back into the camera feature.
                mockStore.entries.removeAll()
                mockStore.cameraTutorialEnabled = true
                mockStore.selectDate(Date())

            case .none:
                break
            }
        }
    }

    private func animateIn() {
        // Animate grid fade in
        withAnimation(.easeOut(duration: 0.5).delay(0.2)) {
            gridOpacity = 1.0
        }

        // Only scroll to today for steps that need it
        // addReminder shows future year content, switchYear doesn't need scroll
        let needsScrollToToday = startingStepType != .addReminder
            && startingStepType != .switchYear

        // Scroll to today's entry after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if needsScrollToToday || isOnboarding {
                scrollToTodayEntry()
            }
        }

        // Show tutorial overlay after grid appears and scrolls
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            hasAnimatedIn = true
            withAnimation(.easeIn(duration: 0.3)) {
                overlayOpacity = 1.0
            }
            // Mark transition as complete - now user can interact with the grid
            isTransitionComplete = true
        }
    }

    private func scrollToTodayEntry() {
        guard !hasScrolledToEntry else { return }
        hasScrolledToEntry = true

        // Scroll to today's actual item ID instead of using a separate anchor
        // The anchor approach with offset doesn't work because .offset() only moves the view visually
        // but doesn't change its position for scrolling purposes
        let calendar = Calendar.current
        let today = Date()

        if let todayItem = mockStore.itemsInYear.first(where: { calendar.isDate($0.date, inSameDayAs: today) }) {
            withAnimation(.easeInOut(duration: 0.6)) {
                scrollProxy?.scrollTo(todayItem.id, anchor: .center)
            }
        }
    }

    /// Scroll to the currently selected entry (used when bottom view appears)
    private func scrollToSelectedEntry() {
        guard let selectedItem = mockStore.selectedDateItem else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            scrollProxy?.scrollTo(selectedItem.id, anchor: .center)
        }
    }

    // MARK: - Prerequisite Handling

    private func handlePrerequisite(_ notification: Notification) {
        guard let prerequisite = notification.userInfo?["prerequisite"] as? TutorialPrerequisite else { return }

        switch prerequisite {
        case .ensureFutureYear:
            mockStore.ensureFutureYear()

        case .populateAnniversaryEntry:
            // First clear any existing selection to avoid capturing frames during transition
            mockStore.clearSelection()

            // Wait for clear animation to finish, then populate and select anniversary entry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                mockStore.ensureFutureYear()
                mockStore.populateAnniversaryEntry()
            }

        case .openEntryEditingView:
            // Entry should already be open from scrubbing step
            if mockStore.selectedDateItem == nil {
                mockStore.selectDate(Date())
            }

        case .clearSelectionAndScroll:
            // Deselect any selected entry to dismiss the bottom entry editing view
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                mockStore.clearSelection()
            }
            // Reset scroll flag and scroll to today's entry again
            hasScrolledToEntry = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                scrollToTodayEntry()
            }

        case .navigateToToday:
            // Simulate the effect of double-tapping the center handle
            // Scroll to today's entry and select it
            hasScrolledToEntry = false
            scrollToTodayEntry()
            // Small delay to let scroll complete, then select today
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                mockStore.selectDate(Date())
            }

        case .prepareForCameraReference:
            // Wipe any seeded drawing and reselect today so the canvas opens
            // on an empty entry (camera button is gated on `paths.isEmpty`).
            mockStore.entries.removeAll()
            mockStore.cameraTutorialEnabled = true
            mockStore.clearSelection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                mockStore.selectDate(Date())
            }

        case .prepareForMoveDrawing:
            // Return to current year, clear any selection (closes anniversary entry view), scroll to today, then select today's entry
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                mockStore.selectedYear = Calendar.current.component(.year, from: Date())
                mockStore.clearSelection()
            }
            hasScrolledToEntry = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                scrollToTodayEntry()
            }
            // Select today after scroll settles so EntryEditingView opens with the drawing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    mockStore.selectDate(Date())
                }
            }
        }
    }

    // MARK: - Event Handlers

    private func handlePaintButtonTapped() {
        Haptic.play()

        // Check if current step expects paint button tap
        if let step = coordinator.currentStep,
           case .buttonTapped(let buttonId) = step.endCondition,
           buttonId == .paintButton {
            // Advance to next step first, then open canvas
            coordinator.advance()
        }

        // Open the drawing canvas
        showDrawingCanvas = true
    }

    private func handleViewModeChange(from oldValue: ViewMode, to newValue: ViewMode) {
        guard let step = coordinator.currentStep else { return }

        if case .viewModeChanged(let targetMode) = step.endCondition {
            if newValue == targetMode {
                coordinator.advance()
            }
        }

        // Check for pinch gesture completion (expanding from year to now)
        if case .pinchGestureCompleted = step.endCondition {
            if oldValue == .year && newValue == .now {
                coordinator.advance()
            }
        }
    }

    private func handleYearChange(from oldValue: Int, to newValue: Int) {
        guard let step = coordinator.currentStep else { return }

        if case .yearChanged = step.endCondition {
            if newValue != oldValue {
                coordinator.advance()
            }
        }
    }

    /// Runs whenever the coordinator moves to a new step. Re-asserts any UI
    /// state the incoming step depends on but doesn't set up itself.
    private func handleStepChange() {
        guard let step = coordinator.currentStep else { return }

        // The camera-reference "trace over your reference" step (Step D)
        // highlights the whole drawing canvas and advances when the canvas is
        // dismissed. Its anchor only resolves to a real frame while the canvas
        // is open; if anything closed it out of band during the capture -> trace
        // transition, the highlight would collapse to the (zero-size on
        // non-Dynamic-Island devices) container and the step would be
        // unrecoverable. Re-open the canvas so the highlight lands correctly.
        if step.type == .cameraReference,
           step.highlightAnchor == .drawingCanvas,
           !showDrawingCanvas {
            showDrawingCanvas = true
        }
    }

    private func handleDrawingCanvasChange(from oldValue: Bool, to newValue: Bool) {
        guard let step = coordinator.currentStep else { return }

        // Canvas was dismissed
        if oldValue == true && newValue == false {
            if case .viewDismissed(let viewId) = step.endCondition {
                if viewId == "drawingCanvas" {
                    coordinator.advance()
                }
            }
        }
    }

    private func handleReminderSheetChange(from oldValue: Bool, to newValue: Bool) {
        guard let step = coordinator.currentStep else { return }

        // Sheet was dismissed
        if oldValue == true && newValue == false {
            if case .sheetDismissed = step.endCondition {
                // Complete tutorial - the completion animation will trigger
                // and after it finishes, coordinator.isActive will become false
                coordinator.advance()
            }
        }
    }

    private func handleDoubleTapCompleted() {
        guard let step = coordinator.currentStep else { return }

        if case .doubleTapCompleted = step.endCondition {
            _ = coordinator.checkEndCondition(.doubleTapCompleted)
        }
    }

    /// Called when the user taps "Move to Another Date" from the context menu in tutorial mode.
    /// Advances past the context-menu sub-step, then collapses the bottom view and enters move mode.
    private func handleMoveDrawingRequested() {
        _ = coordinator.checkEndCondition(.moveContextMenuOptionTapped)

        // Match real app: switch to now view and collapse bottom panel first
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            mockStore.viewMode = .now
            mockStore.clearSelection()
        }

        // Enter move mode after the panel collapse animation plays
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                mockStore.enterMoveMode()
            }
        }
    }

    /// Handle selection changes during transition - prevents accidental selections before tutorial is ready
    private func handleSelectionChangeDuringTransition(from oldValue: DateItem?, to newValue: DateItem?) {
        // Only apply this safety check during the scrubbing step and before transition is complete
        guard !isTransitionComplete,
              let step = coordinator.currentStep,
              step.type == .scrubbing,
              newValue != nil,
              !isScrubbing else { return }

        // User somehow selected an entry during transition (shouldn't happen with gesture blocking,
        // but this is a safety net). Clear selection and re-scroll to today.
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                mockStore.clearSelection()
            }
            // Re-scroll to today's entry after dismissing the bottom view
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                hasScrolledToEntry = false
                scrollToTodayEntry()
            }
        }
    }

    private func handleScrubbingChange(from oldValue: Bool, to newValue: Bool) {
        guard let step = coordinator.currentStep else { return }

        // Scrubbing ended
        if oldValue == true && newValue == false {
            if case .scrubEnded = step.endCondition {
                // Small delay to let selection happen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    coordinator.advance()
                }
            }
        }
    }

    private func handleGridTap(at location: CGPoint, geometry: GeometryProxy) {
        if isScrubbing { return }
        guard let itemId = getItemId(at: location, geometry: geometry),
              let item = getItem(from: itemId) else { return }

        mockStore.selectDate(item.date)
        Haptic.play()
    }

    /// Create grid interaction callbacks for JoodleGridInteractionView
    private func createGridCallbacks(geometry: GeometryProxy) -> GridInteractionCallbacks {
        GridInteractionCallbacks(
            onScrubbingBegan: { location in
                if mockStore.isInMoveMode { return }
                highlightedId = nil
                isScrubbing = true
                coordinator.isUserScrubbing = true  // Hide highlight overlay
                mockStore.clearSelection()
                let newId = getItemId(at: location, geometry: geometry)
                if highlightedId == nil { Haptic.play(with: .medium) }
                highlightedId = newId
            },
            onScrubbingChanged: { location in
                if mockStore.isInMoveMode { return }
                let newId = getItemId(at: location, geometry: geometry)
                if newId != highlightedId { Haptic.play() }
                highlightedId = newId
            },
            onScrubbingEnded: { location in
                if mockStore.isInMoveMode { return }
                if let highlightedId, let item = getItem(from: highlightedId) {
                    mockStore.selectDate(item.date)
                }
                highlightedId = nil
                isScrubbing = false
                coordinator.isUserScrubbing = false  // Show highlight overlay again
            },
            onTap: { location in
                if isScrubbing { return }

                // Move mode: tap selects a target date — show confirmation alert (matches real app)
                if mockStore.isInMoveMode {
                    guard let itemId = getItemId(at: location, geometry: geometry),
                          let item = getItem(from: itemId)
                    else { return }

                    // Ignore taps on dates that already have a drawing (not valid targets)
                    let targetHasDrawing = mockStore.getEntry(for: item.date)?.hasDrawing ?? false
                    if targetHasDrawing { return }

                    // Ignore taps on the source date itself
                    if let sourceString = mockStore.moveSourceDateString,
                       CalendarDate.from(item.date).dateString == sourceString { return }

                    // Valid target — show confirmation alert
                    moveTutorialTargetDate = item.date
                    showMoveTutorialConfirmation = true
                    Haptic.play()
                    return
                }

                handleGridTap(at: location, geometry: geometry)
            },
            onPinchEnded: { value in
                if mockStore.isInMoveMode { return }
                handlePinchGesture(value: value)
            }
        )
    }

    private func handlePinchGesture(value: MagnificationGesture.Value) {
        let scaleThreshold: CGFloat = 0.9
        let expandThreshold: CGFloat = 1.2

        // Pinch in: switch from "now" to "year" mode
        if value < scaleThreshold && mockStore.viewMode == .now {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                mockStore.viewMode = .year
            }
        }
        // Pinch out: switch from "year" to "now" mode
        else if value > expandThreshold && mockStore.viewMode == .year {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                mockStore.viewMode = .now
            }
        }
    }

    // MARK: - Helper Methods

    private func calculateSpacing(containerWidth: CGFloat, viewMode: ViewMode) -> CGFloat {
        CalendarGridHelper.calculateSpacing(containerWidth: containerWidth, viewMode: viewMode)
    }

    /// Get item ID at a location - matches ContentView's implementation
    /// Location is relative to YearGridView (from LongPressScrubRecognizer overlay)
    private func getItemId(at location: CGPoint, geometry: GeometryProxy) -> String? {
        CalendarGridHelper.itemId(
            at: location,
            containerWidth: geometry.size.width,
            viewMode: mockStore.viewMode,
            year: mockStore.selectedYear,
            items: mockStore.itemsInYear,
            horizontalPaddingAdjustment: true
        )
    }

    private func getItem(from itemId: String) -> DateItem? {
        return mockStore.itemsInYear.first { $0.id == itemId }
    }

    private func getTodayIndex() -> Int {
        let calendar = Calendar.current
        let today = Date()
        let currentYear = calendar.component(.year, from: today)

        guard mockStore.selectedYear == currentYear,
              let startOfYear = calendar.date(from: DateComponents(year: currentYear, month: 1, day: 1)) else {
            return 0
        }

        return calendar.dateComponents([.day], from: startOfYear, to: today).day ?? 0
    }

    /// Convert mock entries to DayEntry format for YearGridView compatibility
    private func mockEntriesToDayEntries() -> [DayEntry] {
        mockStore.entries.map { mockEntry in
            DayEntry(
                body: mockEntry.body,
                createdAt: mockEntry.date,
                drawingData: mockEntry.drawingData
            )
        }
    }
}

// MARK: - Tutorial Header View (Year Only)

/// Custom header view for tutorial that only shows year selector (not date)
private struct TutorialHeaderView: View {
    @ObservedObject var mockStore: MockDataStore
    let geometry: GeometryProxy
    let highlightedItemId: String?
    let entries: [DayEntry]

    private let drawingSize: CGFloat = 52.0

    private var availableYears: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return [currentYear, currentYear + 1]
    }

    /// Get the highlighted DateItem from the mock store's items
    private var highlightedItem: DateItem? {
        guard let id = highlightedItemId else { return nil }
        return mockStore.itemsInYear.first { $0.id == id }
    }

    /// Get the entry for the highlighted item
    private var highlightedEntry: DayEntry? {
        guard let item = highlightedItem else { return nil }
        return entries.first { $0.matches(date: item.date) }
    }

    private var dotColor: Color {
        guard let highlightedItem else { return .textColor }
        let isHighlightedToday = Calendar.current.isDate(highlightedItem.date, inSameDayAs: Date())
        return isHighlightedToday ? .appAccent : .textColor
    }

    private var hasDrawing: Bool {
        guard let entry = highlightedEntry else { return false }
        return entry.drawingData != nil && !(entry.drawingData?.isEmpty ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.clear)
                .frame(height: geometry.safeAreaInsets.top)

            HStack {
                HStack(spacing: hasDrawing ? 12 : 6) {
                    // Year selector - shows only year, not date
                    Menu {
                        ForEach(availableYears, id: \.self) { year in
                            Button(String(year)) {
                                withAnimation {
                                    mockStore.selectedYear = year
                                }
                            }
                        }
                    } label: {
                        Text(String(mockStore.selectedYear))
                            .font(.appTitle(weight: .bold))
                            .foregroundColor(.textColor)
                    }
                    .menuStyle(.borderlessButton)
                    .tutorialHighlightAnchor(.yearSelector)

                    // Show highlighted entry drawing/dot when scrubbing
                    if let entry = highlightedEntry {
                        if entry.drawingData != nil && !(entry.drawingData?.isEmpty ?? false) {
                            // Create a layout placeholder that doesn't affect HStack height
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 36, height: 36)
                                .overlay(
                                    DrawingDisplayView(
                                        entry: entry,
                                        displaySize: drawingSize,
                                        dotStyle: .present,
                                        accent: true,
                                        highlighted: false,
                                        scale: 1.0,
                                        useThumbnail: true
                                    )
                                    .frame(width: drawingSize, height: drawingSize)
                                    .animation(.interactiveSpring, value: highlightedEntry)
                                )
                        } else if !entry.body.isEmpty {
                            ZStack {
                                // Dot
                                Circle()
                                    .fill(dotColor)
                                    .frame(width: 12, height: 12)

                                // Ring
                                Circle()
                                    .stroke(dotColor, lineWidth: 2)
                                    .frame(width: 18, height: 18)
                            }
                            .frame(width: 36, height: 36)
                            .animation(.interactiveSpring, value: highlightedEntry)
                        }
                    }
                }

                Spacer()

                // View mode toggle button — hidden during move mode
                if !mockStore.isInMoveMode {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            mockStore.viewMode = mockStore.viewMode == .now ? .year : .now
                        }
                    } label: {
                        Image(systemName: mockStore.viewMode == .now
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                    }
                    .circularGlassButton()
                    .tutorialHighlightAnchor(.viewModeButton, cornerRadius: 22)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 50)
        }
        .background(headerBackground)
        .ignoresSafeArea(edges: .top)
    }

    private var headerBackground: some View {
        ZStack {
            Rectangle().fill(Color.backgroundColor)

            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.black.opacity(1.0), location: 0.0),
                    .init(color: Color.black.opacity(0.0), location: 0.4),
                    .init(color: Color.black.opacity(0.0), location: 1.0),
                ]),
                startPoint: .bottom,
                endPoint: .top
            )
            .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

// MARK: - Previews

#Preview("Full Tutorial Flow") {
    let viewModel = OnboardingViewModel()
    return InteractiveTutorialView(viewModel: viewModel)
}

#Preview("Single Step - Scrubbing") {
    let viewModel = OnboardingViewModel()
    return InteractiveTutorialView(
        viewModel: viewModel,
        singleStepMode: true,
        startingStepType: .scrubbing
    )
}

#Preview("Single Step - Open Canvas") {
    let viewModel = OnboardingViewModel()
    return InteractiveTutorialView(
        viewModel: viewModel,
        singleStepMode: true,
        startingStepType: .drawAndEdit
    )
}

#Preview("Single Step - View Mode") {
    let viewModel = OnboardingViewModel()
    return InteractiveTutorialView(
        viewModel: viewModel,
        singleStepMode: true,
        startingStepType: .switchViewMode
    )
}

#Preview("Single Step - Move Drawing") {
    let viewModel = OnboardingViewModel()
    return InteractiveTutorialView(
        viewModel: viewModel,
        singleStepMode: true,
        startingStepType: .moveDrawing
    )
}
