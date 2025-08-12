//
//  YearSelectorView.swift
//  GoodDay
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftUI
import SwiftData

struct YearSelectorView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [DayEntry]
    
    let highlightedItem: YearGridViewItem?
    @Binding var selectedYear: Int
    
    private var availableYears: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        
        // Find the earliest entry year
        let earliestYear: Int
        if let firstEntry = entries.sorted(by: { $0.createdAt < $1.createdAt }).first {
            earliestYear = Calendar.current.component(.year, from: firstEntry.createdAt)
        } else {
            // If no entries exist, start from current year
            earliestYear = currentYear
        }
        
        // Create range from earliest year to current year + 1
        let endYear = currentYear + 1
        return Array(earliestYear...endYear)
    }
    
    private var headerText: String {
        guard let highlightedItem else { return String(selectedYear) }
        let isHighlightedToday = Calendar.current.isDate(highlightedItem.date, inSameDayAs: Date())
        return isHighlightedToday ? "Today": getFormattedDate(highlightedItem.date)
    }
    
    private var headerColor: Color {
        guard let highlightedItem else { return .textColor }
        let isHighlightedToday = Calendar.current.isDate(highlightedItem.date, inSameDayAs: Date())
        return isHighlightedToday ? .accent: .textColor
    }
    
    var body: some View {
        Menu {
            ForEach(availableYears, id: \.self) { year in
                Button(String(year)) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        selectedYear = year
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(headerText)
                    .font(.largeTitle)
                    .fontWeight(.heavy)
                    .foregroundColor(headerColor)
            }
        }
        .menuStyle(BorderlessButtonMenuStyle())
    }
    
    // MARK: - Helper Methods
    private func getFormattedDate(_ date: Date) -> String {
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

#Preview("With Sample Data") {
    @Previewable @State var selectedYear = 2024
    
    let container = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: DayEntry.self, configurations: config)
        
        // Add sample entries spanning multiple years
        container.mainContext.insert(DayEntry(body: "Started my journal in 2022!", createdAt: Calendar.current.date(from: DateComponents(year: 2022, month: 3, day: 15))!))
        container.mainContext.insert(DayEntry(body: "Great day in 2023", createdAt: Calendar.current.date(from: DateComponents(year: 2023, month: 6, day: 20))!))
        container.mainContext.insert(DayEntry(body: "Another entry in 2023", createdAt: Calendar.current.date(from: DateComponents(year: 2023, month: 8, day: 10))!))
        container.mainContext.insert(DayEntry(body: "Current year entry", createdAt: Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 5))!))
        
        return container
    }()
    
    YearSelectorView(
        highlightedItem: nil,
        selectedYear: $selectedYear
    )
    .modelContainer(container)
    .padding()
}

#Preview("Empty State") {
    @Previewable @State var selectedYear = 2024
    
    YearSelectorView(
        highlightedItem: nil,
        selectedYear: $selectedYear
    )
    .modelContainer(for: DayEntry.self, inMemory: true)
    .padding()
}
