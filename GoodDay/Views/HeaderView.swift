//
//  HeaderView.swift
//  GoodDay
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftUI

struct HeaderView: View {
    let geometry: GeometryProxy
    let highlightedItem: YearGridViewItem?
    @Binding var selectedYear: Int
    let viewMode: ViewMode
    let onToggleViewMode: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Extend to top edge of device
            Rectangle()
                .fill(Color.clear)
                .frame(height: geometry.safeAreaInsets.top)
            
            // Header content
            HStack {
                YearSelectorView(
                    highlightedItem: highlightedItem,
                    selectedYear: $selectedYear
                )
                
                Spacer()
                
                // View mode toggle button
                Button(action: onToggleViewMode) {
                    Image(systemName: viewMode == .now ? "calendar" : "dot.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.textColor)
                        .frame(width: 36, height: 36)
                        .background(.controlBackgroundColor)
                        .clipShape(Circle())
                }
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
    
    GeometryReader { geometry in
        HeaderView(
            geometry: geometry,
            highlightedItem: YearGridViewItem(id: "test", date: Date()),
            selectedYear: $selectedYear,
            viewMode: .now,
            onToggleViewMode: {}
        )
    }
    .frame(height: 200)
    .modelContainer(for: DayEntry.self, inMemory: true)
}
