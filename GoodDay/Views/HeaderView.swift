//
//  HeaderView.swift
//  GoodDay
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftUI

struct HeaderView: View {
    let highlightedEntry: DayEntry?
    let geometry: GeometryProxy
    let highlightedItem: YearGridViewItem?
    @Binding var selectedYear: Int
    let viewMode: ViewMode
    let onToggleViewMode: () -> Void
    let onSettingsAction: () -> Void
    
    private let drawingSize: CGFloat = 52.0
    
    private var dotColor: Color {
        guard let highlightedItem else { return .textColor }
        let isHighlightedToday = Calendar.current.isDate(highlightedItem.date, inSameDayAs: Date())
        return isHighlightedToday ? .accent : .textColor
    }
    
    private var hasDrawing: Bool {
        guard let entry = highlightedEntry else { return false }
        return entry.drawingData != nil && !(entry.drawingData?.isEmpty ?? false)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Extend to top edge of device
            Rectangle()
                .fill(Color.clear)
                .frame(height: geometry.safeAreaInsets.top)
            
            // Header content
            HStack {
                HStack (spacing: hasDrawing ? 12 : 6) {
                    YearSelectorView(
                        highlightedItem: highlightedItem,
                        selectedYear: $selectedYear
                    )
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    
                    if let entry = highlightedEntry {
                        if entry.drawingData != nil && !(entry.drawingData?.isEmpty ?? false) {
                            // Create a layout placeholder that doesn't affect HStack height
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 36, height: 36) // Small layout footprint
                                .overlay(
                                    DrawingDisplayView(entry: entry, displaySize: drawingSize)
                                        .frame(width: drawingSize, height: drawingSize)
                                        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: highlightedEntry)
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
                            .frame(width: 36, height: 36) // Match the layout footprint
                            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: highlightedEntry)
                        }
                    }
                }
                
                Spacer()
  
                // Metaball morphing buttons
                MetaballButtonView(
                    viewMode: viewMode,
                    onToggleViewMode: onToggleViewMode,
                    onSettingsAction: onSettingsAction
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 50)
        }
        .background(
            ZStack {
                Rectangle().fill(.backgroundColor) // blur layer
                
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.black.opacity(1.0), location: 0.0),
                        .init(color: Color.black.opacity(0.0), location: 0.4),
                        .init(color: Color.black.opacity(0.0), location: 1.0)
                    ]),
                    startPoint: .bottom,
                    endPoint: .top
                )
                .blendMode(.destinationOut) // punch transparency into the blur
            }
                .compositingGroup() // required for destinationOut to work
        )
        .ignoresSafeArea(edges: .top)
    }

}

#Preview {
    @Previewable @State var selectedYear = 2024
    @Previewable @State var viewMode: ViewMode = .now
    
    GeometryReader { geometry in
        HeaderView(
            highlightedEntry: nil,
            geometry: geometry,
            highlightedItem: YearGridViewItem(id: "test", date: Date()),
            selectedYear: $selectedYear,
            viewMode: viewMode,
            onToggleViewMode: { viewMode = viewMode == .now ? .year : .now },
            onSettingsAction: {}
        )
    }
    .frame(height: 200)
    .modelContainer(for: DayEntry.self, inMemory: true)
}
