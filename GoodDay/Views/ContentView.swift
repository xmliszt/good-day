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
    
    @Query private var entries: [DayEntry]
    
    @State private var selectedDate: IdentifiableDate?
    @State private var isEditMode = false
    @State private var editedText = ""
    @State private var dragLocation: CGPoint = .zero
    @State private var isDragging = false
    @State private var highlightedId: String?
    @State private var isScrollingDisabled = false
    @State private var viewMode: ViewMode = .now // Default to "now" mode
    
    // Touch delay detection states
    @State private var touchStartTime: Date?
    @State private var initialTouchLocation: CGPoint = .zero
    @State private var hasMovedBeforeDelay = false
    @State private var isInDelayPeriod = false
    @State private var delayTimer: Timer?
    @State private var initialTouchItemId: String?
    
    private let currentYear = Calendar.current.component(.year, from: Date())
    private let headerHeight: CGFloat = 100.0
    
    // MARK: Computed
    /// Flattened array of items to be displayed in the year grid.
    private var itemsInYear: [YearGridViewItem] {
        let calendar = Calendar.current
        let startOfYear = calendar.date(from: DateComponents(year: currentYear, month: 1, day: 1))!
        let daysCount = daysInYear
        
        return (0..<daysCount).map { dayOffset in
            let date = calendar.date(byAdding: .day, value: dayOffset, to: startOfYear)!
            return YearGridViewItem(
                id: "\(Int(date.timeIntervalSince1970))",
                date: date
            )
        }
    }
    
    /// Size of the dot based on view mode.
    private var dotSize: CGFloat {
        switch viewMode {
        case .now:
            return 12.0 // Standard size for now mode
        case .year:
            return 8.0 // Smaller size for year mode
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            
            // Calculate spacing for the grid based on geometry values
            let dotsPerRow = calculateDotsPerRow(for: geometry)
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
                            year: currentYear,
                            viewMode: viewMode,
                            dotsPerRow: dotsPerRow,
                            dotsSpacing: itemsSpacing,
                            items: itemsInYear,
                            entries: entries,
                            highlightedItemId: highlightedId
                        )
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        handleDragChanged(value: value, geometry: geometry)
                                    }
                                    .onEnded { value in
                                        handleDragEnded(value: value, geometry: geometry)
                                    }
                            )
                    }
                    .scrollDisabled(isScrollingDisabled)
                    .background(.backgroundColor)
                    // When view mode change, scroll to today's dot
                    .onChange(of: viewMode) {
                        scrollToTodayCenter(scrollProxy: scrollProxy, geometry: geometry)
                    }
                    // Initial scroll to today's dot for both modes
                    .onAppear {
                        scrollToTodayCenter(scrollProxy: scrollProxy, geometry: geometry)
                    }
                    // When device orientation changes, scroll to today's dot
                    .onRotate {_ in 
                        scrollToTodayCenter(scrollProxy: scrollProxy, geometry: geometry)
                    }
                }
                
                // Floating header with blur backdrop
                HeaderView(
                    geometry: geometry,
                    highlightedId: highlightedId,
                    currentYear: currentYear,
                    viewMode: viewMode,
                    onToggleViewMode: toggleViewMode
                )
            }
            .background(.backgroundColor)
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
    }
    


    /// Number of days in the current year
    private var daysInYear: Int {
        let calendar = Calendar.current
        let startOfYear = calendar.date(from: DateComponents(year: currentYear, month: 1, day: 1))!
        let startOfNextYear = calendar.date(from: DateComponents(year: currentYear + 1, month: 1, day: 1))!
        return calendar.dateComponents([.day], from: startOfYear, to: startOfNextYear).day!
    }
    
    /// Calculate spacing between dots based on view mode
    private func calculateSpacing(for geometry: GeometryProxy, viewMode: ViewMode) -> CGFloat {
        let dotsPerRow = calculateDotsPerRow(for: geometry)
        
        // Ensure we have at least one space between dots
        guard dotsPerRow > 1 else { return 0 }
        
        let gridWidth = geometry.size.width
        let totalDotsWidth = dotSize * CGFloat(dotsPerRow)
        let availableSpace = gridWidth - totalDotsWidth
        let spacing = availableSpace / CGFloat(dotsPerRow - 1)
        
        // Apply minimum spacing based on view mode
        let minimumSpacing: CGFloat = viewMode == .now ? 4 : 2
        return max(minimumSpacing, spacing)
    }
    
    // MARK: User interactions
    private func handleDragChanged(value: DragGesture.Value, geometry: GeometryProxy) {
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
            if newHighlightedId != highlightedId {
                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                impactFeedback.impactOccurred()
            }
            
            // Update highlightedId
            highlightedId = newHighlightedId
        }
    }
    
    private func handleDragEnded(value: DragGesture.Value, geometry: GeometryProxy) {
        // Check if this was a tap (no movement and very short duration)
        let wasTap = !hasMovedBeforeDelay && 
                     !isScrollingDisabled && 
                     (touchStartTime.map { Date().timeIntervalSince($0) < 0.2 } ?? false)
        
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
        if let itemId = getItemId(at: value.location, for: geometry) {
            guard let item = itemsInYear.first(where: { $0.id == itemId }) else {
                fatalError("Unable to find item at location: \(value.location)")
            }
            selectDate(item.date)
        }
    }
    
    // MARK: Utils
    /// Number of dots per row in the grid
    private func calculateDotsPerRow(for geometry: GeometryProxy) -> Int {
        switch viewMode {
        case .now:
            return 7
        case .year:
            let gridWidth = geometry.size.width
            let dotSize: CGFloat = 8 // Fixed dot size for year mode
            let minSpacing: CGFloat = 16 // Minimum spacing between dots in year mode
            
            // Calculate maximum number of dots that can fit in a row with safety margin
            // Subtract some width to ensure dots don't overflow
            let safeGridWidth = gridWidth * 0.95 // 5% safety margin
            let maxDotsPerRow = Int((safeGridWidth + minSpacing) / (dotSize + minSpacing))
            
            // Ensure we have at least 7 dots per row (minimum)
            return max(7, min(maxDotsPerRow, 25)) // Cap at 25 dots per row for readability and to prevent overflow
        }
    }
    
    /// Get the item id for a particular CGPoint location inside the given geometry
    private func getItemId(at location: CGPoint, for geometry: GeometryProxy) -> String? {
        let gridWidth = geometry.size.width
        
        // Use the appropriate dots per row and spacing based on view mode
        let dotsPerRow = calculateDotsPerRow(for: geometry)
        let spacing = calculateSpacing(for: geometry, viewMode: viewMode)
        
        // Account for horizontal padding (matches YearGridView.padding(.horizontal, GRID_HORIZONTAL_PADDING))
        let adjustedX = location.x - GRID_HORIZONTAL_PADDING
        let adjustedY = location.y
        
        // Use the same positioning logic as YearGridView
        let containerWidth = gridWidth - (2 * GRID_HORIZONTAL_PADDING) // Account for both sides of padding
        let totalSpacingWidth = CGFloat(dotsPerRow - 1) * spacing
        let totalDotWidth = containerWidth - totalSpacingWidth
        let itemSpacing = totalDotWidth / CGFloat(dotsPerRow)
        let startX = itemSpacing / 2
        
        // Calculate row based on vertical position
        let rowHeight = dotSize + spacing
        let row = max(0, Int(floor(adjustedY / rowHeight)))
        
        // Calculate column based on horizontal position using YearGridView's logic
        // Find the closest column by checking distance to each column's center
        var closestCol = 0
        var minDistance = CGFloat.greatestFiniteMagnitude
        
        for col in 0..<dotsPerRow {
            let xPos = startX + CGFloat(col) * (itemSpacing + spacing)
            let distance = abs(adjustedX - xPos)
            if distance < minDistance {
                minDistance = distance
                closestCol = col
            }
        }
        
        // Ensure we don't go out of bounds
        let col = max(0, min(dotsPerRow - 1, closestCol))
        let itemIndex = row * dotsPerRow + col
        
        // Ensure we don't exceed the items array bounds
        guard itemIndex < itemsInYear.count else { return nil }
        
        let item = itemsInYear[itemIndex]
        return item.id
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
    
    private func toggleViewMode() {
        // Use a spring animation for morphing effect
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.1)) {
            viewMode = viewMode == .now ? .year : .now
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
                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                impactFeedback.impactOccurred()
            }
        }
    }
    
    private func cancelDelayTimer() {
        delayTimer?.invalidate()
        delayTimer = nil
    }
    
    // MARK: Layout Calculations
    /// Scrolls to center today's dot with animation
    private func scrollToTodayCenter(scrollProxy: ScrollViewProxy, geometry: GeometryProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let todayId = getTodayItemId()
            withAnimation(.easeInOut) {
                // Calculate proper scroll position to center dot on visible screen
                let anchor = calculateScrollAnchor(for: todayId, geometry: geometry)
                scrollProxy.scrollTo(todayId, anchor: anchor)
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
    
    /// Get the item ID for today's date
    private func getTodayItemId() -> String {
        let today = Date()
        let calendar = Calendar.current
        
        guard let todayItem = itemsInYear.first(where: { calendar.isDate($0.date, inSameDayAs: today) }) else {
            // Fallback to first item if today is not found
            return itemsInYear.first?.id ?? ""
        }
        
        return todayItem.id
    }
    
    /// Calculate the proper scroll anchor to center a dot on the visible screen
    /// This is because our grid view does not have virtualization, because we want to 
    /// morph every single dot between view modes. Therefore, the grid view has height
    /// that is the sum of all dots' height, which could be longer than the screen height.
    /// Therefore, we need to calculate the scroll anchor to center the dot on the visible screen.
    private func calculateScrollAnchor(for itemId: String, geometry: GeometryProxy) -> UnitPoint {
        // Find the item index
        guard let item = itemsInYear.first(where: { $0.id == itemId }),
              let itemIndex = itemsInYear.firstIndex(where: { $0.id == item.id }) else {
            return .center
        }
        
        // Calculate grid layout parameters
        let dotsPerRow = calculateDotsPerRow(for: geometry)
        let spacing = calculateSpacing(for: geometry, viewMode: viewMode)
        
        // Calculate dot position within the content
        let row = itemIndex / dotsPerRow
        let dotYPosition = CGFloat(row) * (dotSize + spacing) + 20 // Add top padding
        
        // Calculate total content height
        let numberOfRows = (itemsInYear.count + dotsPerRow - 1) / dotsPerRow
        let totalContentHeight = CGFloat(numberOfRows) * (dotSize + spacing)
        
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

// MARK: - Device Rotation Detection
/// Custom view modifier to track device rotation and call our action
struct DeviceRotationViewModifier: ViewModifier {
    let action: (UIDeviceOrientation) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear()
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                action(UIDevice.current.orientation)
            }
    }
}

/// View extension to make the rotation detection modifier easier to use
extension View {
    func onRotate(perform action: @escaping (UIDeviceOrientation) -> Void) -> some View {
        self.modifier(DeviceRotationViewModifier(action: action))
    }
}

#Preview {
    ContentView()
        .modelContainer(for: DayEntry.self, inMemory: true)
}
