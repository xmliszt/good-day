//
//  EntryEditingSheet.swift
//  GoodDay
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftUI
import SwiftData

struct EntryEditingSheetView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    
    let date: Date
    let entries: [DayEntry]
    @Binding var isEditMode: Bool
    @Binding var editedText: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with date and edit button
            HStack {
                VStack(alignment: .leading) {
                    Text(date, style: .date)
                        .font(.headline)
                        .foregroundColor(.textColor)
                    Text(date, formatter: DateFormatter.weekday)
                        .font(.subheadline)
                        .foregroundColor(.secondaryTextColor)
                }
                
                Spacer()
                
                Button(action: toggleEditMode) {
                    Image(systemName: isEditMode ? "checkmark" : "pencil")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.textColor)
                        .frame(width: 36, height: 36)
                        .background(.controlBackgroundColor)
                        .clipShape(Circle())
                }
            }
            
            // Note content
            if isEditMode {
                ZStack(alignment: .topLeading) {
                    if editedText.isEmpty {
                        Text("Enter your note here...")
                            .foregroundColor(.textColor.opacity(0.4))
                            .padding(16) // same padding as TextEditor for alignment
                    }
                    
                    TextEditor(text: $editedText)
                        .font(.body)
                        .foregroundColor(.textColor)
                        .background(.backgroundColor)
                        .cornerRadius(8)
                        .frame(minHeight: 120)
                        .disableAutocorrection(false)
                        .autocapitalization(.sentences)
                }
            } else {
                ScrollView {
                    Text(editedText.isEmpty ? "No note for this day" : editedText)
                        .font(.body)
                        .foregroundColor(editedText.isEmpty ? .textColor.opacity(0.5) : .textColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 120, alignment: .topLeading)
                }
            }
            
            Spacer()
        }
        .padding(20)
        .background(.backgroundColor)
        .onAppear {
            // Ensure editedText is properly initialized when sheet appears
            editedText = entryForDate(date)?.body ?? ""
        }
    }
    
    // MARK: - Private Methods
    
    private func toggleEditMode() {
        if isEditMode {
            // Save the note
            saveNote()
        }
        isEditMode.toggle()
    }
    
    private func saveNote() {
        withAnimation {
            if let existingEntry = entryForDate(date) {
                // Update existing entry
                existingEntry.body = editedText
            } else if !editedText.isEmpty {
                // Create new entry only if there's content
                let newEntry = DayEntry(body: editedText, createdAt: date)
                modelContext.insert(newEntry)
            }
            
            // Save the context to persist changes
            try? modelContext.save()
        }
    }
    
    private func entryForDate(_ date: Date) -> DayEntry? {
        let calendar = Calendar.current
        return entries.first { entry in
            calendar.isDate(entry.createdAt, inSameDayAs: date)
        }
    }
    

}

extension DateFormatter {
    static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()
}
