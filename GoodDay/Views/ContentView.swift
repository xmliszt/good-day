//
//  ContentView.swift
//  GoodDay
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftUI
import SwiftData

struct IdentifiableDate: Identifiable, Equatable {
    let id = UUID()
    let date: Date
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(UserPreferences.self) private var userPreferences
    
    @Query private var entries: [DayEntry]
    
    @State private var selectedDate: IdentifiableDate?
    @State private var isEditMode = false
    @State private var editedText = ""
    @State private var dragLocation: CGPoint = .zero
    @State private var isDragging = false
    @State private var highlightedId: String?
    @State private var isScrollingDisabled = false
    @State private var viewMode: ViewMode = UserPreferences.shared.defaultViewMode
    
    // Touch delay detection states
    @State private var touchStartTime: Date?
    @State private var initialTouchLocation: CGPoint = .zero
    @State private var hasMovedBeforeDelay = false
    @State private var isInDelayPeriod = false
    @State private var delayTimer: Timer?
    @State private var initialTouchItemId: String?
    
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    @State private var navigateToSettings = false
    private let headerHeight: CGFloat = 100.0
    
    // Pinch gesture states
    private let scaleThreshold: CGFloat = 0.8 // Threshold for detecting significant pinch
    private let expandThreshold: CGFloat = 1.2 // Threshold for detecting significant expand
    @State private var isPinching = false
    
    // MARK: Computed
    /// Flattened array of items to be displayed in the year grid.
    private var itemsInYear: [YearGridViewItem] {
        let calendar = Calendar.current
        let startOfYear = calendar.date(from: DateComponents(year: selectedYear, month: 1, day: 1))!
        let daysCount = daysInYear
        
        return (0..<daysCount).map { dayOffset in
            let date = calendar.date(byAdding: .day, value: dayOffset, to: startOfYear)!
            return YearGridViewItem(
                id: "\(Int(date.timeIntervalSince1970))",
                date: date
            )
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            
            // Calculate spacing for the grid based on geometry values
            let itemsSpacing = calculateSpacing(for: geometry, viewMode: viewMode)
            
            ZStack(alignment: .top) {
                // Full-screen scrollable year grid
                ScrollViewReader { scrollProxy in
                    ScrollView(showsIndicators: false) {
                        // Add spacer at top to account for header overlay
                        Spacer()
                            .frame(height: headerHeight)
                            .id("topSpacer")
                        
                        YearGridView(
                            year: selectedYear,
                            viewMode: viewMode,
                            dotsSpacing: itemsSpacing,
                            items: itemsInYear,
                            entries: entries,
                            highlightedItemId: highlightedId
                        )
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { handleDragChanged(value: $0, geometry: geometry) }
                                    .onEnded { handleDragEnded(value: $0, geometry: geometry) }
                            )
                            .simultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { handlePinchChanged(value: $0) }
                                    .onEnded { handlePinchEnded(value: $0) }
                            )
                    }
                    .scrollDisabled(isScrollingDisabled || isPinching)
                    .background(.backgroundColor)
                    // When view mode change, scroll to today's dot
                    .onChange(of: viewMode) {
                        scrollToRelevantDate(scrollProxy: scrollProxy, geometry: geometry)
                    }
                    // When year changes, scroll to relevant date
                    .onChange(of: selectedYear) {
                        scrollToRelevantDate(scrollProxy: scrollProxy, geometry: geometry)
                    }
                    // Initial scroll to today's dot for both modes
                    .onAppear {
                        scrollToRelevantDate(scrollProxy: scrollProxy, geometry: geometry)
                    }
                    // When device orientation changes, scroll to today's dot
                    .onRotate {_ in 
                        scrollToRelevantDate(scrollProxy: scrollProxy, geometry: geometry)
                    }
                }
                
                // Floating header with blur backdrop
                HeaderView(
                    highlightedEntry: highlightedId != nil ? (entries.first(where: { $0.createdAt == getItem(from: highlightedId!)?.date})) : nil,
                    geometry: geometry,
                    highlightedItem: highlightedId != nil ? getItem(from: highlightedId!) : nil,
                    selectedYear: $selectedYear,
                    viewMode: viewMode,
                    onToggleViewMode: toggleViewMode,
                    onSettingsAction: {
                        navigateToSettings = true
                    }
                )
            }
            .background(.backgroundColor)
            .onShake {
                handleShakeGesture()
            }
        }
        .sheet(item: $selectedDate) { date in
            let entry = entries.first(where: { $0.createdAt == date.date})
            EntryEditingSheetView(
                date: date.date,
                entry: entry,
                isEditMode: $isEditMode,
                editedText: $editedText
            )
            .presentationDetents([.fraction(0.5)])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $navigateToSettings) {
            SettingsView()
                .environment(userPreferences)
        }
    }
    


    /// Number of days in the selected year
    private var daysInYear: Int {
        let calendar = Calendar.current
        let startOfYear = calendar.date(from: DateComponents(year: selectedYear, month: 1, day: 1))!
        let startOfNextYear = calendar.date(from: DateComponents(year: selectedYear + 1, month: 1, day: 1))!
        return calendar.dateComponents([.day], from: startOfYear, to: startOfNextYear).day!
    }
    
    /// Calculate spacing between dots based on view mode
    private func calculateSpacing(for geometry: GeometryProxy, viewMode: ViewMode) -> CGFloat {
        let gridWidth = geometry.size.width - (2 * GRID_HORIZONTAL_PADDING)
        let totalDotsWidth = viewMode.dotSize * CGFloat(viewMode.dotsPerRow)
        let availableSpace = gridWidth - totalDotsWidth
        let spacing = availableSpace / CGFloat(viewMode.dotsPerRow - 1)
        
        // Apply minimum spacing based on view mode
        let minimumSpacing: CGFloat = viewMode == .now ? 4 : 2
        return max(minimumSpacing, spacing)
    }
    
    // MARK: User interactions
    private func handleDragChanged(value: DragGesture.Value, geometry: GeometryProxy) {
        // Don't process drag gestures while pinching
        if isPinching { return }
        
        dragLocation = value.location
        
        // Check if this is the start of a drag gesture
        if !isDragging {
            isDragging = true
            touchStartTime = Date()
            initialTouchLocation = value.location
            hasMovedBeforeDelay = false
            isInDelayPeriod = true
            // Store the initial item ID for later use in timer
            initialTouchItemId = getItemId(at: value.location, for: geometry)
            // Ensure scrolling is enabled at the start
            isScrollingDisabled = false
            
            // Start the delay timer
            startDelayTimer()
        } else {
            // Check if user has moved significantly during the delay period
            if isInDelayPeriod {
                let movementThreshold: CGFloat = 5 // pixels - very small threshold for quick response
                let distanceMoved = sqrt(
                    pow(value.location.x - initialTouchLocation.x, 2) + 
                    pow(value.location.y - initialTouchLocation.y, 2)
                )
                
                if distanceMoved > movementThreshold {
                    hasMovedBeforeDelay = true
                    cancelDelayTimer()
                    isInDelayPeriod = false
                    // Allow normal scrolling by ensuring scroll is enabled
                    isScrollingDisabled = false
                    highlightedId = nil
                }
            }
        }
        
        // Only highlight dots if scrolling is disabled (after delay without movement)
        if isScrollingDisabled && !isInDelayPeriod {
            let newHighlightedId = getItemId(at: value.location, for: geometry)
            
            // Haptic feedback when selection changes between dots
            // Only feedback when the highlighted id changes
            if newHighlightedId != highlightedId { Haptic.play() }
            
            // Update highlightedId
            highlightedId = newHighlightedId
        }
    }
    
    private func handleDragEnded(value: DragGesture.Value, geometry: GeometryProxy) {
        // Don't process drag gestures while pinching
        if isPinching { return }
        
        // Check if this was a tap (no movement and very short duration)
        let wasTap = !hasMovedBeforeDelay && 
                     !isScrollingDisabled && 
                     (touchStartTime.map { Date().timeIntervalSince($0) < 0.2 } ?? false)

        // Select date
        if let highlightedId, let item = getItem(from: highlightedId) {
            selectDate(item.date)
        }
        
        // Clean up all touch-related state
        cancelDelayTimer()
        isDragging = false
        isScrollingDisabled = false
        highlightedId = nil
        isInDelayPeriod = false
        hasMovedBeforeDelay = false
        touchStartTime = nil
        initialTouchItemId = nil
        
        // If it was a tap, handle date selection
        if !wasTap { return }
        guard let itemId = getItemId(at: value.location, for: geometry) else { return }
        guard let item = getItem(from: itemId) else { return }
        
        selectDate(item.date)
        
        // Haptic feedback
        Haptic.play()
    }
    
    private func handlePinchChanged(value: MagnificationGesture.Value) {
        if isPinching { return }

        isPinching = true

        // Clean up any ongoing drag gesture state when pinch begins
        highlightedId = nil
        isScrollingDisabled = false
        cancelDelayTimer()
        isInDelayPeriod = false
        hasMovedBeforeDelay = false
        isDragging = false
    }
    
    private func handlePinchEnded(value: MagnificationGesture.Value) {
        isPinching = false
        highlightedId = nil
        isScrollingDisabled = false
        
        // Pinch in: switch from "now" to "year" mode
        if value < scaleThreshold && viewMode == .now {
            toggleViewMode(to: .year)
        }
        // Pinch out: switch from "year" to "now" mode
        else if value > expandThreshold && viewMode == .year {
            toggleViewMode(to: .now)
        }
    }
    
    
    // MARK: Utils
    /// Get the item id for a particular CGPoint location inside the given geometry
    private func getItemId(at location: CGPoint, for geometry: GeometryProxy) -> String? {
        let gridWidth = geometry.size.width
        
        // Use the appropriate dots per row and spacing based on view mode
        let spacing = calculateSpacing(for: geometry, viewMode: viewMode)
        
        // Adjust location for grid coordinates
        let adjustedLocation = adjustTouchLocationForGrid(location)
        let adjustedX = adjustedLocation.x
        let adjustedY = adjustedLocation.y + spacing / 2
        
        // Use the same positioning logic as YearGridView
        let containerWidth = gridWidth - (2 * GRID_HORIZONTAL_PADDING) // Account for both sides of padding
        let totalSpacingWidth = CGFloat(viewMode.dotsPerRow - 1) * spacing
        let totalDotWidth = containerWidth - totalSpacingWidth
        let itemSpacing = totalDotWidth / CGFloat(viewMode.dotsPerRow)
        let startX = itemSpacing / 2
        
        // Calculate row based on vertical position
        let rowHeight = viewMode.dotSize + spacing
        let row = max(0, Int(floor(adjustedY / rowHeight)))
        
        // Calculate column based on horizontal position using YearGridView's logic
        // Find the closest column by checking distance to each column's center
        var closestCol = 0
        var minDistance = CGFloat.greatestFiniteMagnitude
        
        for col in 0..<viewMode.dotsPerRow {
            let xPos = startX + CGFloat(col) * (itemSpacing + spacing)
            let distance = abs(adjustedX - xPos)
            if distance < minDistance {
                minDistance = distance
                closestCol = col
            }
        }
        
        // Ensure we don't go out of bounds
        let col = max(0, min(viewMode.dotsPerRow - 1, closestCol))
        let itemIndex = row * viewMode.dotsPerRow + col
        
        // Ensure we don't exceed the items array bounds
        guard itemIndex < itemsInYear.count else { return nil }
        
        let item = itemsInYear[itemIndex]
        return item.id
    }
    
    private func getItem(from itemId: String) -> YearGridViewItem? {
        return itemsInYear.first { $0.id == itemId }
    }
    
    private func selectDate(_ date: Date) {
        // Set all state synchronously
        selectedDate = IdentifiableDate(date: date)
        isEditMode = false
        // Initialize editedText with the entry content for the selected date
        editedText = (entries.first { entry in
            Calendar.current.isDate(entry.createdAt, inSameDayAs: date)
        })?.body ?? ""
    }
    
    /// Toggle the view mode between current modes
    private func toggleViewMode() {
        // Use a spring animation for morphing effect
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.1)) {
            viewMode = viewMode == .now ? .year : .now
        }
    }
    
    /// Toggle the view mode to a specific mode
    private func toggleViewMode(to newViewMode: ViewMode) {
        // Use a spring animation for morphing effect
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.1)) {
            viewMode = newViewMode
            // Save the new view mode as the user's preference
            userPreferences.defaultViewMode = newViewMode
        }
    }
    
    // MARK: - Shake Gesture Handler
    private func handleShakeGesture() {
        let currentYear = Calendar.current.component(.year, from: Date())
        
        // Haptic feedback for shake action
        Haptic.play(with: .medium)
        
        // Set to current year and scroll to today
        withAnimation(.spring(response: 0.8, dampingFraction: 0.7, blendDuration: 0.1)) {
            selectedYear = currentYear
            viewMode = .now // Switch to "now" mode for better visibility
        }
    }
    
    // MARK: - Touch Delay Timer Methods
    private func startDelayTimer() {
        // Cancel any existing timer
        cancelDelayTimer()
        
        // Start a new timer for 0.1 second delay
        delayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [self] _ in
            // Timer fired - user hasn't moved significantly within 0.1 second
            if !hasMovedBeforeDelay && isInDelayPeriod {
                // Enable dot highlighting mode
                isScrollingDisabled = true
                isInDelayPeriod = false
                
                // Set initial highlighted dot to stored initial touch item
                if let initialId = initialTouchItemId {
                    highlightedId = initialId
                }
                
                // Provide haptic feedback to indicate mode switch
                Haptic.play(with: .medium)
            }
        }
    }
    
    private func cancelDelayTimer() {
        delayTimer?.invalidate()
        delayTimer = nil
    }
    
    // MARK: Layout Calculations
    /// Scrolls to center the most relevant date (today if in selected year, otherwise first day of year)
    private func scrollToRelevantDate(scrollProxy: ScrollViewProxy, geometry: GeometryProxy) {
        // Only auto-scroll if the preference is enabled
        guard userPreferences.autoScrollToToday else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let currentYear = Calendar.current.component(.year, from: Date())
            
            withAnimation(.easeInOut) {
                if selectedYear != currentYear {
                    // For non-current years, scroll to the top spacer to show first row properly
                    scrollProxy.scrollTo("topSpacer", anchor: .top)
                } else {
                    // For current year, scroll to today with proper centering
                    let targetId = getRelevantDateId()
                    let anchor = calculateScrollAnchor(for: targetId, geometry: geometry)
                    scrollProxy.scrollTo(targetId, anchor: anchor)
                }
            }
        }
    }
    
    private func getDateFromId(_ id: String) -> Date {
        guard let item = itemsInYear.first(where: { $0.id == id }) else {
            fatalError("Invalid item ID: \(id)")
        }
        return item.date
    }
    
    private func getFormattedDate(_ date: Date) -> String {
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    
    /// Get the item ID for the most relevant date (today if in selected year, otherwise first day of year)
    private func getRelevantDateId() -> String {
        let today = Date()
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: today)
        
        // If we're viewing the current year, try to scroll to today
        if selectedYear == currentYear {
            if let todayItem = itemsInYear.first(where: { calendar.isDate($0.date, inSameDayAs: today) }) {
                return todayItem.id
            }
        }
        
        // Otherwise, scroll to the first day of the selected year
        return itemsInYear.first?.id ?? ""
    }
    
    /// Calculate the proper scroll anchor to center a dot on the visible screen
    /// This is because our grid view does not have virtualization, because we want to 
    /// morph every single dot between view modes. Therefore, the grid view has height
    /// that is the sum of all dots' height, which could be longer than the screen height.
    /// Therefore, we need to calculate the scroll anchor to center the dot on the visible screen.
    /// Adjusts the touch location from the parent coordinate system to the grid's coordinate system
    private func adjustTouchLocationForGrid(_ location: CGPoint) -> CGPoint {
        // Adjust for the header height and horizontal padding
        return CGPoint(
            x: location.x - GRID_HORIZONTAL_PADDING,
            y: location.y
        )
    }
    
    private func calculateScrollAnchor(for itemId: String, geometry: GeometryProxy) -> UnitPoint {
        // Find the item index
        guard let item = itemsInYear.first(where: { $0.id == itemId }),
              let itemIndex = itemsInYear.firstIndex(where: { $0.id == item.id }) else {
            return .top
        }
        
        // Calculate proper anchor to center the dot on screen (only used for current year)
        let spacing = calculateSpacing(for: geometry, viewMode: viewMode)
        
        // Calculate dot position within the content
        let row = itemIndex / viewMode.dotsPerRow
        let dotYPosition = CGFloat(row) * (viewMode.dotSize + spacing) + 20 // Add top padding
        
        // Calculate total content height
        let numberOfRows = (itemsInYear.count + viewMode.dotsPerRow - 1) / viewMode.dotsPerRow
        let totalContentHeight = CGFloat(numberOfRows) * (viewMode.dotSize + spacing)
        
        // Calculate visible screen area (excluding header)
        let visibleScreenHeight = geometry.size.height - headerHeight
        let screenCenter = visibleScreenHeight / 2
        
        // Calculate what percentage down the content the dot should be to appear in screen center
        let targetScrollPosition = dotYPosition - screenCenter + headerHeight
        let scrollPercentage = max(0, min(1, targetScrollPosition / (totalContentHeight - visibleScreenHeight)))
        
        // Return anchor point that will center the dot on visible screen
        return UnitPoint(x: 0.5, y: scrollPercentage)
    }
    

}

#Preview {
    ContentView()
        .modelContainer(for: DayEntry.self, inMemory: true)
}
