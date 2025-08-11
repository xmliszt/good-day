//
//  YearGridView.swift
//  GoodDay
//
//  Created by Li Yuxuan on 11/8/25.
//

import SwiftUI

// MARK: - Constants
let GRID_HORIZONTAL_PADDING: CGFloat = 40

enum ViewMode {
    case now
    case year
}

struct YearGridViewItem: Identifiable {
    var id: String
    var date: Date
}

struct YearGridView: View {
    
    // MARK: Params
    /// The year to display
    let year: Int
    /// The mode to display the grid in
    let viewMode: ViewMode
    /// The number of dots per row
    let dotsPerRow: Int
    /// The spacing between dots
    let dotsSpacing: CGFloat
    /// The items to display in the grid
    let items: [YearGridViewItem]
    /// The entries to display in the grid
    let entries: [DayEntry]
    /// The id of the highlighted item
    let highlightedItemId: String?
    
    // MARK: Private states
    /// The size of the dots (computed based on view mode)
    private var dotSize: CGFloat {
        switch viewMode {
        case .now:
            return 12.0
        case .year:
            return 8.0
        }
    }
    
    
    // MARK: View
    var body: some View {
        // Use a completely flat structure with manual positioning
        // This ensures every dot maintains stable identity regardless of layout changes
        let numberOfRows = (items.count + dotsPerRow - 1) / dotsPerRow
        let totalContentHeight = CGFloat(numberOfRows) * (dotSize + dotsSpacing)
        
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let containerWidth = geometry.size.width
                let totalSpacingWidth = CGFloat(dotsPerRow - 1) * dotsSpacing
                let totalDotWidth = containerWidth - totalSpacingWidth
                let itemSpacing = totalDotWidth / CGFloat(dotsPerRow)
                let startX = itemSpacing / 2
                
                ZStack(alignment: .topLeading) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let dotStyle = getDotStyle(for: item.date)
                        let hasEntry = entryForDate(item.date) != nil
                        let isHighlighted = highlightedItemId == item.id
                        let isToday = Calendar.current.isDate(item.date, inSameDayAs: Date())
                        
                        let row = index / dotsPerRow
                        let col = index % dotsPerRow
                        let xPos = startX + CGFloat(col) * (itemSpacing + dotsSpacing)
                        let yPos = CGFloat(row) * (dotSize + dotsSpacing)
                        
                        DotView(
                            size: dotSize,
                            highlighted: isHighlighted,
                            withEntry: hasEntry,
                            dotStyle: dotStyle
                        )
                        // Stable identity based on date, this is important
                        // so that every single dot is morphed between mode switch
                        // as it is considered as one
                        .id(item.id)
                        // Add special ID for today's dot for auto-scroll
                        .if(isToday) { $0.id("todayDot") }
                        // Center the dot
                        .position(x: xPos, y: yPos + dotSize/2)
                        // Add staggered animation delay based on chronological date order
                        .animation(
                            .spring(response: 0.6, dampingFraction: 0.8),
                            value: viewMode
                        )
                        .animation(
                            .spring(response: 0.6, dampingFraction: 0.8),
                            value: dotsSpacing
                        )
                        .animation(
                            .spring(response: 0.6, dampingFraction: 0.8),
                            value: dotsPerRow
                        )
                        .animation(
                            .spring(response: 0.6, dampingFraction: 0.8)
                            .delay(Double(index) * 0.003),
                            value: dotSize)
                    }
                }
            }
            .frame(height: totalContentHeight) // Define explicit height for scrolling
            .padding(.horizontal, GRID_HORIZONTAL_PADDING)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
    
    // MARK: Functions
    /// Get the style of the dot for a given date
    private func getDotStyle(for date: Date) -> DotStyle {
        if isPastDay(for: date) {
            return .past
        } else if isToday(for: date) {
            return .present
        }
        return .future
    }
    
    /// Find the entry for a given date
    private func entryForDate(_ date: Date) -> DayEntry? {
        let calendar = Calendar.current
        return entries.first { entry in
            calendar.isDate(entry.createdAt, inSameDayAs: date)
        }
    }
    
    /// Check if a given date is today's date
    private func isToday(for date: Date) -> Bool {
        let calendar = Calendar.current
        return calendar.isDate(date, inSameDayAs: Date())
    }
    
    /// Check if a given date is in the past (before today)
    private func isPastDay(for date: Date) -> Bool {
        let calendar = Calendar.current
        return date < calendar.startOfDay(for: Date())
    }
}

// MARK: - Extensions
extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

#Preview {
    let calendar = Calendar.current
    let currentYear = calendar.component(.year, from: Date())
    
    // Generate sample items for the year
    let startOfYear = calendar.date(from: DateComponents(year: currentYear, month: 1, day: 1))!
    let daysInYear = calendar.dateInterval(of: .year, for: Date())!.duration / (24 * 60 * 60)
    let sampleItems = (0..<Int(daysInYear)).map { dayOffset in
        let date = calendar.date(byAdding: .day, value: dayOffset, to: startOfYear)!
        return YearGridViewItem(
            id: "\(Int(date.timeIntervalSince1970))",
            date: date
        )
    }
    
    ScrollView {
        VStack {
            YearGridView(
                year: currentYear,
                viewMode: .now,
                dotsPerRow: 7,
                dotsSpacing: 25,
                items: sampleItems,
                entries: [],
                highlightedItemId: nil
            )
            YearGridView(
                year: currentYear,
                viewMode: .year,
                dotsPerRow: 25,
                dotsSpacing: 8,
                items: sampleItems,
                entries: [],
                highlightedItemId: nil
            )
        }
    }
}
