//
//  YearGridView.swift
//  GoodDay
//
//  Created by Li Yuxuan on 11/8/25.
//

import SwiftUI

// MARK: - Constants
let GRID_HORIZONTAL_PADDING: CGFloat = 40

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
    /// The spacing between dots
    let dotsSpacing: CGFloat
    /// The items to display in the grid
    let items: [YearGridViewItem]
    /// The entries to display in the grid
    let entries: [DayEntry]
    /// The id of the highlighted item
    let highlightedItemId: String?
    
    
    // MARK: View
    var body: some View {
        // Use a completely flat structure with manual positioning
        // This ensures every dot maintains stable identity regardless of layout changes
        let numberOfRows = (items.count + viewMode.dotsPerRow - 1) / viewMode.dotsPerRow
        let totalContentHeight = CGFloat(numberOfRows) * (viewMode.dotSize + dotsSpacing)
        
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let containerWidth = geometry.size.width
                let totalSpacingWidth = CGFloat(viewMode.dotsPerRow - 1) * dotsSpacing
                let totalDotWidth = containerWidth - totalSpacingWidth
                let itemSpacing = totalDotWidth / CGFloat(viewMode.dotsPerRow)
                let startX = itemSpacing / 2
                
                ZStack(alignment: .topLeading) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let dotStyle = getDotStyle(for: item.date)
                        let entry = entryForDate(item.date)
                        let hasEntry = entry != nil && entry!.body.isEmpty == false
                        let hasDrawing = entry?.drawingData != nil && !(entry?.drawingData?.isEmpty ?? true)
                        let isHighlighted = highlightedItemId == item.id
                        let isToday = Calendar.current.isDate(item.date, inSameDayAs: Date())
                        
                        let row = index / viewMode.dotsPerRow
                        let col = index % viewMode.dotsPerRow
                        let xPos = startX + CGFloat(col) * (itemSpacing + dotsSpacing)
                        let yPos = CGFloat(row) * (viewMode.dotSize + dotsSpacing)
                    
                        Group {
                            if hasDrawing {
                                // Show drawing instead of dot with specific frame sizes
                                DrawingDisplayView(entry: entry, displaySize: viewMode.drawingSize)
                                    .frame(width: viewMode.drawingSize, height: viewMode.drawingSize)
                                    .scaleEffect(isHighlighted ? 2.0 : 1.0)
                                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isHighlighted)
                            } else {
                                // Show regular dot
                                DotView(
                                    size: viewMode.dotSize,
                                    highlighted: isHighlighted,
                                    withEntry: hasEntry,
                                    dotStyle: dotStyle
                                )
                            }
                        }
                        // Stable identity based on date, this is important
                        // so that every single dot is morphed between mode switch
                        // as it is considered as one
                        .id(item.id)
                        // Add special ID for today's dot for auto-scroll
                        .if(isToday) { $0.id("todayDot") }
                        // Center the dot
                        .position(x: xPos, y: yPos + viewMode.dotSize/2)
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
                            value: viewMode.dotsPerRow
                        )
                        .animation(
                            .spring(response: 0.6, dampingFraction: 0.8),
                            value: viewMode.dotSize)
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
                dotsSpacing: 25,
                items: sampleItems,
                entries: [],
                highlightedItemId: nil
            )
            YearGridView(
                year: currentYear,
                viewMode: .year,
                dotsSpacing: 8,
                items: sampleItems,
                entries: [],
                highlightedItemId: nil
            )
        }
    }
}
