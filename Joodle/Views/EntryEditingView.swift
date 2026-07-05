//
//  EntryEditingView.swift
//  Joodle
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftData
import SwiftUI
import Combine

struct EntryEditingView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.modelContext) private var modelContext
  @Environment(\.locale) private var locale

  private let date: Date?
  private let selectedEntry: DayEntry?
  private let onOpenDrawingCanvas: ((Int) -> Void)?
  private let onFocusChange: ((Bool) -> Void)?
  private let mockStore: MockDataStore?
  private let tutorialMode: Bool
  private let showReminderSheetBinding: Binding<Bool>?
  /// Called when the user taps the note area to begin editing. Provides initial text and a save
  /// handler. The parent is responsible for presenting NoteEditingPopupView so it can be overlaid
  /// on the full screen for a proper blur effect.
  private let onNoteEditRequested: ((String, @escaping (String) -> Void) -> Void)?
  /// Called when EntryEditingView wants to proactively close the note-editing popup (e.g. on date
  /// change). The parent should dismiss NoteEditingPopupView in response.
  private let onNoteEditDismissed: (() -> Void)?
  /// Called when user taps the date label to initiate a drawing move.
  /// Only fires when the current entry has a drawing. Carries the index of the
  /// doodle to move.
  private let onMoveDrawingRequested: ((Int) -> Void)?
  /// When true, tapping the drawing display does NOT open the drawing canvas.
  /// Used during the moveDrawing tutorial step so the user must use the context menu.
  private let disableDrawingTap: Bool

  init(
    date: Date?,
    entry: DayEntry? = nil,
    onOpenDrawingCanvas: ((Int) -> Void)? = nil,
    onFocusChange: ((Bool) -> Void)? = nil,
    mockStore: MockDataStore? = nil,
    tutorialMode: Bool = false,
    showReminderSheetBinding: Binding<Bool>? = nil,
    onNoteEditRequested: ((String, @escaping (String) -> Void) -> Void)? = nil,
    onNoteEditDismissed: (() -> Void)? = nil,
    onMoveDrawingRequested: ((Int) -> Void)? = nil,
    disableDrawingTap: Bool = false
  ) {
    self.date = date
    self.selectedEntry = entry
    self.onOpenDrawingCanvas = onOpenDrawingCanvas
    self.onFocusChange = onFocusChange
    self.mockStore = mockStore
    self.tutorialMode = tutorialMode
    self.showReminderSheetBinding = showReminderSheetBinding
    self.onNoteEditRequested = onNoteEditRequested
    self.onNoteEditDismissed = onNoteEditDismissed
    self.onMoveDrawingRequested = onMoveDrawingRequested
    self.disableDrawingTap = disableDrawingTap
    _textContent = State(initialValue: entry?.body ?? "")
    _entry = State(initialValue: entry)
  }

  @State private var showDeleteConfirmation = false
  @State private var currentTime = Date()
  @State private var isTimerActive = false
  @State private var textContent: String = ""
  @State private var isEditingNote: Bool = false
  @State private var entry: DayEntry?
  /// Currently displayed page in the doodle carousel. Equals `doodleCount` when
  /// the trailing "+" placeholder page is showing.
  @State private var carouselIndex: Int = 0
  @State private var showButtons = true
  @State private var showShareSheet = false
  @State private var _showReminderSheetInternal = false
  @StateObject private var reminderManager = ReminderManager.shared

  /// Track the view's top Y position in global coordinate space for dynamic drawing sizing
  @State private var topYPosition: CGFloat = 0
  /// Track the screen height for calculating split ratio
  @State private var screenHeight: CGFloat = 0
  /// Track the container width for calculating max drawing size
  @State private var containerWidth: CGFloat = 0

  /// Calculate dynamic drawing size based on the view's top Y position
  /// At 0.5 split (top Y at ~50% of screen), use 160x160
  /// At 0.15 split (top Y at ~15% of screen), use full width
  private var drawingDisplaySize: CGFloat {
    let minDrawingSize: CGFloat = 160
    // `containerWidth` is measured outside the 20pt content padding, so
    // `containerWidth - 40` is already the paged carousel's page width. A card
    // that wide touches its neighbours with no gap, so keep the largest card a
    // little shy of full width to give adjacent doodles breathing room.
    let padding: CGFloat = 40 // cancels the 20pt-per-side content padding
    let carouselGap: CGFloat = 44 // keeps the max card shy of full width
    let maxDrawingSize = max(minDrawingSize, containerWidth - padding - carouselGap)

    guard screenHeight > 0 else { return 160 }

    // Use absolute Y position thresholds instead of ratio
    // This accounts for safe area insets and drag handle offset
    // Compact threshold: when top Y is around half screen height (~420pt on iPhone)
    // Expanded threshold: must be >= topYPosition at 0.15 split (safeAreaTop + 0.15*containerHeight + dragHandle ≈ 180-205pt depending on device)
    let compactYThreshold: CGFloat = screenHeight * 0.48
    let expandedYThreshold: CGFloat = screenHeight * 0.26

    if topYPosition >= compactYThreshold {
      return minDrawingSize
    } else if topYPosition <= expandedYThreshold {
      return maxDrawingSize
    } else {
      // Linear interpolation between 160 and maxDrawingSize
      // As topYPosition goes from compactYThreshold to expandedYThreshold, progress goes from 0 to 1
      let progress = (compactYThreshold - topYPosition) / (compactYThreshold - expandedYThreshold)
      return minDrawingSize + (maxDrawingSize - minDrawingSize) * progress
    }
  }

  /// Computed property that uses binding if provided, otherwise uses internal state
  private var showReminderSheet: Bool {
    get {
      showReminderSheetBinding?.wrappedValue ?? _showReminderSheetInternal
    }
  }

  private func setShowReminderSheet(_ value: Bool) {
    if let binding = showReminderSheetBinding {
      binding.wrappedValue = value
    } else {
      _showReminderSheetInternal = value
    }
  }

  /// Whether we're in mock/tutorial mode
  private var isMockMode: Bool {
    mockStore != nil
  }

  /// Get mock entry for current date
  private var mockEntry: MockDayEntry? {
    guard let mockStore = mockStore, let date = date else { return nil }
    return mockStore.getEntry(for: date)
  }

  /// Drawing data to display - from mock or real entry
  private var displayDrawingData: Data? {
    if isMockMode {
      return mockEntry?.drawingData
    }
    return entry?.drawingData
  }

  /// Whether the current entry has a drawing that can be moved
  private var hasDrawing: Bool {
    if isMockMode {
      return mockEntry?.drawingData != nil && !(mockEntry?.drawingData?.isEmpty ?? true)
    }
    return entry?.drawingData != nil && !(entry?.drawingData?.isEmpty ?? true)
  }

  /// Whether there's an entry with content
  private var hasEntryContent: Bool {
    if isMockMode {
      return mockEntry?.hasContent ?? false
    }
    return entry != nil && (!entry!.body.isEmpty || entry!.drawingData != nil)
  }

  private var isToday: Bool {
    guard let date else { return false }
    return Calendar.current.isDateInToday(date)
  }

  private var isFuture: Bool {
    guard let date else { return false }
    return date > Date()
  }

  private var weekdayLabel: String {
    guard let date else { return "" }
    if isToday { return String(localized: "Today") }
    // Format to weekday (e.g. Monday, Tuesday)
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.calendar = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("EEEE")
    return formatter.string(from: date)
  }

  /// Show count down text for future entry with body
  private var countdownText: String? {
    guard let date else { return nil }
    guard isFuture else { return nil }

    // In mock mode, check mock entry
    if isMockMode {
      guard mockEntry != nil && (mockEntry!.hasContent) else { return nil }
    } else {
      // Guard: only show countdown if at least there is body text, or drawing.
      guard entry != nil && (!entry!.body.isEmpty || entry!.drawingData != nil) else { return nil }
    }

    return CountdownHelper.countdownText(from: currentTime, to: date, locale: locale)
  }

  /// Check if reminder exists for current date
  private var hasReminder: Bool {
    guard let date else { return false }
    // Use CalendarDate for timezone-agnostic date string
    let dateString = CalendarDate.from(date).dateString
    if isMockMode {
      return mockStore?.hasReminder(for: dateString) ?? false
    }
    return reminderManager.getReminder(for: dateString) != nil
  }

  private var selectedEntrySignature: String {
    guard let entry = selectedEntry else { return "nil" }
    return "\(entry.dateString)::\(entry.body)::\(entry.drawingData?.hashValue ?? 0)"
  }

  private func setEditingNotePresented(_ value: Bool) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      isEditingNote = value
    }
    if value {
      onNoteEditRequested?(textContent) { text in
        textContent = text
        guard let date else { return }
        if isMockMode {
          saveMockNote(text: text, for: date)
        } else {
          saveNote(text: text, for: date)
        }
        setEditingNotePresented(false)
      }
    } else {
      onNoteEditDismissed?()
    }
  }

  /// The slot the header pencil edits: the currently viewed carousel page,
  /// clamped so it never exceeds the "new slot" index (`doodleCount`).
  private var headerEditIndex: Int {
    let count = entry?.doodleCount ?? 0
    return min(max(0, carouselIndex), count)
  }

  /// Horizontal paged carousel of the day's doodles plus a trailing "+"
  /// placeholder page (shown whenever the day can still add a doodle). On an
  /// empty day the placeholder is the only page — the default entry point.
  @ViewBuilder
  private var doodleCarousel: some View {
    let doodles = entry?.doodles ?? []
    let canAdd = entry?.canAddDoodle ?? true
    let placeholderIndex = doodles.count
    let pageCount = doodles.count + (canAdd ? 1 : 0)

    VStack(spacing: 12) {
      TabView(selection: $carouselIndex) {
        ForEach(Array(doodles.enumerated()), id: \.element.id) { index, doodle in
          DoodleCardView(
            entry: entry,
            doodle: doodle,
            isPlaceholder: false,
            size: drawingDisplaySize,
            onTap: { onOpenDrawingCanvas?(index) }
          )
          .contextMenu {
            Button {
              onOpenDrawingCanvas?(index)
            } label: {
              Label("Edit Doodle", systemImage: "pencil")
            }
            Button {
              onMoveDrawingRequested?(index)
            } label: {
              Label("Move to Another Date", systemImage: "arrow.up.right.square")
            }
            Button(role: .destructive) {
              deleteDoodle(at: index)
            } label: {
              Label(String(localized: "Delete Doodle"), systemImage: "trash")
            }
          }
          .frame(maxWidth: .infinity)
          .tag(index)
        }

        if canAdd {
          DoodleCardView(
            entry: entry,
            doodle: nil,
            isPlaceholder: true,
            size: drawingDisplaySize,
            onTap: { onOpenDrawingCanvas?(placeholderIndex) }
          )
          .frame(maxWidth: .infinity)
          .tag(placeholderIndex)
        }
      }
      .frame(height: drawingDisplaySize)
      .tabViewStyle(.page(indexDisplayMode: .never))
      .animation(.springFkingSatifying, value: drawingDisplaySize)

      // Page indicator: a dot per doodle, a "+" for the placeholder page.
      if pageCount > 1 {
        HStack(spacing: 6) {
          ForEach(0..<pageCount, id: \.self) { index in
            let isPlaceholderDot = canAdd && index == placeholderIndex
            Group {
              if isPlaceholderDot {
                Image(systemName: "plus")
                  .font(.system(size: 7, weight: .bold))
                  .frame(width: 7, height: 7)
              } else {
                Circle()
                  .frame(width: 6, height: 6)
              }
            }
            .foregroundColor(index == carouselIndex ? .appAccent : .secondaryTextColor.opacity(0.3))
          }
        }
        .animation(.easeInOut(duration: 0.2), value: carouselIndex)
        .animation(.easeInOut(duration: 0.2), value: pageCount)
      }
    }
    .frame(maxWidth: .infinity)
  }

  var body: some View {
    ZStack {
      VStack(alignment: .leading, spacing: 0) {
        // Spacer for header
        Rectangle()
          .fill(.clear)
          .frame(maxWidth: .infinity, maxHeight: 28)

        // Note content
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            // Drawing content
            if isMockMode {
              // Tutorial/mock mode keeps its single mock card (no carousel).
              if let drawingData = displayDrawingData, !drawingData.isEmpty {
                VStack(alignment: .center, spacing: 8) {
                  // In mock mode, create a temporary DayEntry for display
                  let tempEntry = DayEntry(
                    body: mockEntry?.body ?? "",
                    createdAt: date ?? Date(),
                    drawingData: drawingData
                  )
                  DrawingDisplayView(
                    entry: tempEntry,
                    displaySize: drawingDisplaySize,
                    animateDrawing: true
                  )
                  .frame(width: drawingDisplaySize, height: drawingDisplaySize)
                  .background(.appSurface)
                  .clipShape(RoundedRectangle(cornerRadius: 20))
                  .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20))
                  .animation(.springFkingSatifying, value: drawingDisplaySize)
                  .onTapGesture {
                    guard !disableDrawingTap else { return }
                    onOpenDrawingCanvas?(0)
                  }
                  .contextMenu {
                    // In tutorial view, only show the move option
                    Button {
                      onMoveDrawingRequested?(0)
                    } label: {
                      Label(String(localized: "Move to Another Date"), systemImage: "arrow.up.right.square")
                    }
                  }
                  .tutorialHighlightAnchor("entryDrawing", isEnabled: tutorialMode)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
              }
            } else {
              doodleCarousel
            }

            // Note text display — tappable to open the editing popup
            Button {
              setEditingNotePresented(true)
            } label: {
              ZStack(alignment: .topLeading) {
                Text(textContent.isEmpty ? " " : textContent)
                  .font(.appBody())
                  .lineSpacing(4)
                  .foregroundColor(.textColor)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.vertical, 12)
                if textContent.isEmpty {
                  Text("Tap to write a note...")
                    .font(.appBody())
                    .foregroundColor(.textColor.opacity(0.3))
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(NoteDisplayButtonStyle())
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          // Offset the header part
          .padding(.vertical, 32)
        }
        .scrollDismissesKeyboard(.never)
      }
      .padding(20)
      .background(
        GeometryReader { geometry in
          Color.backgroundColor
            .onAppear {
              let frame = geometry.frame(in: .global)
              topYPosition = frame.minY
              screenHeight = UIScreen.main.bounds.height
              containerWidth = frame.width
            }
            .onChange(of: geometry.frame(in: .global)) { _, newFrame in
              let newY = newFrame.minY
              let newWidth = newFrame.width
              guard newY != topYPosition || newWidth != containerWidth else { return }
              topYPosition = newY
              containerWidth = newWidth
            }
        }
      )
      .onAppear {
        // Load entry first
        guard let date else { return }

        if isMockMode {
          // Load from mock store
          textContent = mockStore?.getEntry(for: date)?.body ?? ""
        } else {
          refreshEntryState(for: date, preserveUserInput: false)
        }
        // Then start timer
        startTimerIfNeeded()
      }
      .onChange(of: date ?? nil) { oldValue, newValue in
        // Save old content first if any
        if !textContent.isEmpty, let oldDate = oldValue {
          if isMockMode {
            saveMockNote(text: textContent, for: oldDate)
          } else {
            saveNote(text: textContent, for: oldDate)
          }
        }

        // Close popup if open
        setEditingNotePresented(false)

        // Update entry if got new date
        if let newDate = newValue {
          if isMockMode {
            // Load from mock store
            textContent = mockStore?.getEntry(for: newDate)?.body ?? ""
          } else {
            refreshEntryState(for: newDate, preserveUserInput: false)
          }
        }
      }
      .onChange(of: selectedEntrySignature) { _, _ in
        // Skip in mock mode
        guard !isMockMode else { return }
        guard let date else { return }
        refreshEntryState(for: date, preserveUserInput: isEditingNote)
      }
      .onChange(of: entry) { _, _ in
        // Skip in mock mode
        guard !isMockMode else { return }

        // A new entry (typically a date change) opens the carousel on whichever
        // doodle the grid is currently cross-fading to — computed from the same
        // time-deterministic formula the grid cell uses — so tapping a day shows
        // the doodle the user was looking at, not always the first.
        carouselIndex = DoodleCarouselCell.displayedIndex(count: entry?.doodleCount ?? 0)

        // Restart timer when entry changes (loaded or modified)
        startTimerIfNeeded()
      }
      .onChange(of: isEditingNote) { _, newValue in
        onFocusChange?(newValue)

        // When editing begins, hide header buttons immediately
        if newValue {
          showButtons = false
        }
        // When editing ends, delay button appearance for smooth transition
        else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeIn(duration: 0.25)) {
              showButtons = true
            }
          }
        }
      }
      .onDisappear {
        stopTimer()
      }
      /// Timer for countdown updates (no longer needed since we show "Tomorrow" for <= 1 day)
      .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
        // Only update if timer is active and we still need updates
        // Note: needsRealTimeUpdates now returns false, so this is effectively disabled
        guard isTimerActive && needsRealTimeUpdates else { return }
        currentTime = Date()
      }
      .confirmationDialog("Delete Note", isPresented: $showDeleteConfirmation) {
        Button("Delete", role: .destructive, action: deleteEntry)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Delete this note? This cannot be undone.")
      }
      .sheet(isPresented: $showShareSheet) {
        ShareCardSelectorView(entry: entry, date: date ?? Date())
      }
      .sheet(isPresented: showReminderSheetBinding ?? $_showReminderSheetInternal) {
        if let date {
          ReminderSheet(
            dateString: CalendarDate.from(date).dateString,
            entryBody: isMockMode ? mockEntry?.body : entry?.body,
            mockStore: mockStore
          )
          .presentationDetents([.height(280)])
          .presentationDragIndicator(.visible)
        }
      }

      // Header with date and edit button
      VStack {
        ZStack {
          // Anchor ZStack to a fixed height so the center date label never
          // shifts vertically when left/right buttons appear or disappear.
          Color.clear.frame(height: 44)

          // Left side - Share button
          HStack {
            if #available(iOS 26.0, *) {
              GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                  // Share button
                  // - only show when:
                  //   - not in mock mode
                  //   - and not editing
                  //   - and should show buttons
                  //   - and has entry content
                  if !isMockMode && !isEditingNote && showButtons && hasEntryContent {
                    Button {
                      showShareSheet = true
                    } label: {
                      Image(systemName: "square.and.arrow.up")
                    }
                    .circularGlassButton()
                    .transition(.opacity)
                  }

                  // Reminder Button
                  // - only show when:
                  //   - entry is today or future
                  //   - and not editing
                  //   - and should show buttons
                  if (isToday || isFuture) && !isEditingNote && showButtons {
                    Button {
                      setShowReminderSheet(true)
                    } label: {
                      if hasReminder {
                        Image(systemName: "alarm.waves.left.and.right.fill")
                          .symbolEffect(.wiggle.byLayer, options: .nonRepeating)
                      } else {
                        Image(systemName: "alarm")
                      }
                    }
                    .circularGlassButton(tintColor: hasReminder ? .appAccent : nil)
                    .applyIf(tutorialMode && isFuture) { view in
                      // Only register bellIcon anchor for future dates (addReminder tutorial needs this)
                      // This prevents capturing wrong frames during transitions from non-future entries
                      view.tutorialHighlightAnchor(.bellIcon, cornerRadius: 22)
                    }
                    .transition(.opacity)
                  }

                }
              }
              .animation(.springFkingSatifying, value: isEditingNote)
              .animation(.springFkingSatifying, value: hasEntryContent)
            } else {
              HStack(spacing: 8) {
                // Share button
                // - only show when:
                //   - not in mock mode
                //   - and not editing
                //   - and should show buttons
                //   - and has entry content
                if !isMockMode && !isEditingNote && showButtons && hasEntryContent {
                  Button {
                    // Track share card opened
                    let hasDrawing = displayDrawingData != nil && !displayDrawingData!.isEmpty
                    let hasText = !textContent.isEmpty
                    AnalyticsManager.shared.trackShareCardOpened(hasDrawing: hasDrawing, hasText: hasText)
                    showShareSheet = true
                  } label: {
                    Image(systemName: "square.and.arrow.up")
                  }
                  .circularGlassButton()
                  .transition(.opacity)
                }

                // Reminder Button
                // - only show when:
                //   - entry is today or future
                //   - and not editing
                //   - and should show buttons
                if (isToday || isFuture) && !isEditingNote && showButtons {
                  Button {
                    setShowReminderSheet(true)
                  } label: {
                    if hasReminder {
                      if #available(iOS 18.0, *) {
                        Image(systemName: "alarm.waves.left.and.right.fill")
                          .symbolEffect(.wiggle.byLayer, options: .nonRepeating)
                      } else {
                        // Fallback on earlier versions
                        Image(systemName: "alarm.waves.left.and.right.fill")
                      }
                    } else {
                      Image(systemName: "alarm")
                    }
                  }
                  .circularGlassButton(tintColor: hasReminder ? .appAccent : nil)
                  .applyIf(tutorialMode && isFuture) { view in
                    // Only register bellIcon anchor for future dates (addReminder tutorial needs this)
                    // This prevents capturing wrong frames during transitions from non-future entries
                    view.tutorialHighlightAnchor(.bellIcon, cornerRadius: 22)
                  }
                  .transition(.opacity)
                }

              }
              .animation(.springFkingSatifying, value: isEditingNote)
              .animation(.springFkingSatifying, value: hasEntryContent)
          }
          Spacer()
        }

        // Center - Date and weekday/countdown
        VStack(alignment: .center) {
          if let date {
            Text(CalendarDate.from(date).displayStringWithoutYear)
              .font(.appHeadline())
              .foregroundColor(.textColor)
          }
          HStack(spacing: 8) {
            if let countdown = countdownText {
              Text(countdown)
                .font(.appSubheadline())
                .foregroundColor(.appAccent.opacity(0.7))
            } else {
              Text(weekdayLabel)
                .font(.appSubheadline())
                .foregroundColor(isToday ? .appAccent : .secondaryTextColor)
            }
          }
        }

        // Right side - Delete, Drawing buttons
        HStack {
          Spacer()
          if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
              HStack(spacing: 8) {
                // Delete entry button - only in real mode
                if hasEntryContent && !isEditingNote && showButtons && !isMockMode {
                  Button {
                    showDeleteConfirmation = true
                  } label: {
                    Image(systemName: "trash")
                  }
                  .circularGlassButton(tintColor: .red)
                  .transition(.opacity)
                }

                // Drawing canvas button
                if !isEditingNote && showButtons {
                  Button {
                    self.onOpenDrawingCanvas?(headerEditIndex)
                  } label: {
                    Image(systemName: "scribble.variable")
                  }
                  .circularGlassButton()
                  .applyIf(tutorialMode) { view in
                    view.tutorialHighlightAnchor(.paintButton, cornerRadius: 22)
                  }
                  .transition(.opacity)
                }
              }
            }
            .animation(.springFkingSatifying, value: isEditingNote)
            .animation(.springFkingSatifying, value: hasEntryContent)
          } else {
            // Fallback on earlier versions
            HStack(spacing: 8) {
              // Delete entry button - only in real mode
              if hasEntryContent && !isEditingNote && showButtons && !isMockMode {
                Button {
                  showDeleteConfirmation = true
                } label: {
                  Image(systemName: "trash")
                }
                .circularGlassButton(tintColor: .red)
                .transition(.opacity)
              }

              // Drawing canvas button
              if !isEditingNote && showButtons {
                Button {
                  self.onOpenDrawingCanvas?(headerEditIndex)
                } label: {
                  Image(systemName: "scribble.variable")
                }
                .circularGlassButton()
                .applyIf(tutorialMode) { view in
                  view.tutorialHighlightAnchor(.paintButton, cornerRadius: 22)
                }
                .transition(.opacity)
              }
            }
            .animation(.springFkingSatifying, value: isEditingNote)
            .animation(.springFkingSatifying, value: hasEntryContent)
          }
        }
      }
      .frame(height: 60, alignment: .top)
      .background(
        ZStack {
          Rectangle().fill(.backgroundColor)  // blur layer

          LinearGradient(
            gradient: Gradient(stops: [
              .init(color: Color.black.opacity(1.0), location: 0.0),
              .init(color: Color.black.opacity(0.0), location: 0.4),
              .init(color: Color.black.opacity(0.0), location: 1.0),
            ]),
            startPoint: .bottom,
            endPoint: .top
          )
          .blendMode(.destinationOut)  // punch transparency into the blur
        }
          .compositingGroup()  // required for destinationOut to work
      )

      Spacer()
    }
    .padding(20)
    }
    .animation(.easeInOut(duration: 0.2), value: isEditingNote)
    .postHogScreenView("Entry Editing")
  }

// MARK: - Private Methods

private func refreshEntryState(for date: Date, preserveUserInput: Bool) {
  let resolvedEntry: DayEntry?
  if let selectedEntry, selectedEntry.matches(date: date) {
    resolvedEntry = selectedEntry
  } else {
    resolvedEntry = fetchEntry(for: date)
  }
  entry = resolvedEntry
  if !preserveUserInput {
    textContent = resolvedEntry?.body ?? ""
  }
}

private func fetchEntry(for date: Date) -> DayEntry? {
  let targetDateString = CalendarDate.from(date).dateString
  let predicate = #Predicate<DayEntry> { entry in
    entry.dateString == targetDateString
  }
  let descriptor = FetchDescriptor<DayEntry>(predicate: predicate)
  guard let results = try? modelContext.fetch(descriptor) else { return nil }
  return results.first(where: { ($0.drawingData != nil && !$0.drawingData!.isEmpty) || !$0.body.isEmpty }) ?? results.first
}

/// Start the timer if needed
/// Note: Timer is no longer needed since we show "Tomorrow" for <= 1 day
/// instead of hours/minutes/seconds countdown
private func startTimerIfNeeded() {
  // Skip in mock mode
  guard !isMockMode else { return }

  // No real-time updates needed since we show "Tomorrow" for sub-day countdowns
  guard isFuture && needsRealTimeUpdates else { return }
  currentTime = Date()
  isTimerActive = true
}

/// Stop the timer
private func stopTimer() {
  isTimerActive = false
}

/// Check if we need real-time updates for the countdown text
/// Returns false since we show "Tomorrow" for <= 1 day (no hours/minutes/seconds)
private var needsRealTimeUpdates: Bool {
  guard let date else { return false }
  return CountdownHelper.needsRealTimeUpdates(from: Date(), to: date)
}

/// Delete a single doodle at `index` from the current day, cleaning up the
/// entry entirely if the day is then empty (no doodles and no note).
private func deleteDoodle(at index: Int) {
  guard !isMockMode, let entry else { return }
  guard entry.doodles.indices.contains(index) else { return }

  entry.removeDoodle(at: index)

  if entry.doodleCount == 0 && entry.body.isEmpty {
    entry.deleteAllForSameDate(in: modelContext)
    self.entry = nil
  } else {
    try? modelContext.save()
  }

  // Keep the carousel index within the new page range.
  let remaining = self.entry?.doodleCount ?? 0
  let canAdd = self.entry?.canAddDoodle ?? true
  let newPageCount = remaining + (canAdd ? 1 : 0)
  if carouselIndex >= newPageCount {
    carouselIndex = max(0, newPageCount - 1)
  }

  WidgetHelper.shared.scheduleWidgetDataUpdate(in: modelContext)
  Haptic.play()
}

private func deleteEntry() {
  // Skip in mock mode
  guard !isMockMode else { return }

  guard let entry else { return }

  // Remove any associated reminder
  if let date = date {
    // Use CalendarDate for timezone-agnostic date string
    let dateString = CalendarDate.from(date).dateString
    reminderManager.removeReminder(for: dateString)
  }

  // Delete ALL entries for this date (handles duplicates)
  entry.deleteAllForSameDate(in: modelContext)
  textContent = ""
  self.entry = nil
}

/// Save note to mock store (tutorial mode)
func saveMockNote(text: String, for date: Date) {
  guard let mockStore = mockStore else { return }

  // Get existing entry or create new one
  if var existingEntry = mockStore.getEntry(for: date) {
    existingEntry.body = text
    mockStore.updateEntry(existingEntry)
  } else {
    let newEntry = MockDayEntry(date: date, body: text, drawingData: nil)
    mockStore.addEntry(newEntry)
  }
}

func saveNote(text: String, for date: Date) {
  // Skip in mock mode
  guard !isMockMode else { return }

  // If text is empty and no existing entry, don't create an empty entry
  if text.isEmpty && entry == nil {
    return
  }

  // If we have an existing entry, update it
  if let existingEntry = entry {
    // Skip save if text hasn't changed - avoids unnecessary widget sync and main thread work
    let hasDrawing = existingEntry.drawingData != nil && !existingEntry.drawingData!.isEmpty
    if existingEntry.body == text {
      return
    }

    existingEntry.body = text

    // If entry is now empty (no text and no drawing), delete it entirely
    if text.isEmpty && !hasDrawing {
      existingEntry.deleteAllForSameDate(in: modelContext)
      self.entry = nil

      // Sync deletion to widgets
      WidgetHelper.shared.scheduleWidgetDataUpdate(in: modelContext)
      return
    }

    try? modelContext.save()

    // Sync updated text to widgets
    WidgetHelper.shared.scheduleWidgetDataUpdate(in: modelContext)
    return
  }

  // We have text to save - use findOrCreate to get the single entry for this date
  let entryToUpdate = DayEntry.findOrCreate(for: date, in: modelContext)
  entryToUpdate.body = text
  self.entry = entryToUpdate

  // Save the context to persist changes
  try? modelContext.save()

  // Sync new text entry to widgets
  WidgetHelper.shared.scheduleWidgetDataUpdate(in: modelContext)
}
}

// MARK: - DoodleCardView

/// A single full-size doodle card. Renders a drawing when `isPlaceholder` is
/// false, otherwise a centered "tap to add a doodle" guide. Both states share
/// the same chrome (surface background, rounded clip, dynamic size) so the
/// placeholder is visually the same card as a filled one.
private struct DoodleCardView: View {
  let entry: DayEntry?
  let doodle: Doodle?
  let isPlaceholder: Bool
  let size: CGFloat
  let onTap: () -> Void

  var body: some View {
    Group {
      if isPlaceholder {
        VStack(spacing: 10) {
          Image(systemName: "plus")
            .font(.system(size: 28, weight: .light))
            .foregroundColor(.secondaryTextColor)
          Text("Tap to add a doodle")
            .font(.appSubheadline())
            .foregroundColor(.secondaryTextColor)
        }
        .frame(width: size, height: size)
      } else {
        DrawingDisplayView(
          entry: entry,
          doodle: doodle,
          displaySize: size,
          animateDrawing: true
        )
        .frame(width: size, height: size)
      }
    }
    .frame(width: size, height: size)
    .background(.appSurface)
    .clipShape(RoundedRectangle(cornerRadius: 20))
    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20))
    .animation(.springFkingSatifying, value: size)
    .onTapGesture { onTap() }
  }
}

// MARK: - NoteDisplayButtonStyle

private struct NoteDisplayButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.4 : 1.0)
      .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
  }
}

// MARK: - Previews

#Preview("Real Mode") {
  EntryEditingView(
    date: Date(),
    onOpenDrawingCanvas: { index in print("Open canvas at \(index)") },
    onFocusChange: nil
  )
  .modelContainer(for: DayEntry.self, inMemory: true)
}
