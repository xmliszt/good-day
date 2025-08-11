//
//  HeaderView.swift
//  GoodDay
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftUI

struct HeaderView: View {
    let geometry: GeometryProxy
    let highlightedId: String?
    let currentYear: Int
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
                Text(highlightedId != nil ? getFormattedDate(getDateFromId(highlightedId!)) : String(currentYear))
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.textColor)
                
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
    
    // MARK: - Helper Methods
    private func getDateFromId(_ id: String) -> Date {
        // Convert timestamp ID back to date
        let timeInterval = TimeInterval(Int(id) ?? 0)
        return Date(timeIntervalSince1970: timeInterval)
    }
    
    private func getFormattedDate(_ date: Date) -> String {
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

#Preview {
    GeometryReader { geometry in
        HeaderView(
            geometry: geometry,
            highlightedId: nil,
            currentYear: 2024,
            viewMode: .now,
            onToggleViewMode: {}
        )
    }
    .frame(height: 200)
}
