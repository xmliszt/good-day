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
    @Environment(\.dismiss) private var dismiss
    
    let date: Date
    let entry: DayEntry?
    @Binding var isEditMode: Bool
    @Binding var editedText: String
    @FocusState private var isTextEditorFocused: Bool
    @State private var showDeleteConfirmation = false
    
    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }
    
    private var weekdayLabel: String {
        if isToday { return "Today" }
        // Format to weekday (e.g. Monday, Tuesday)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with date and edit button
            HStack {
                VStack(alignment: .leading) {
                    Text(date, style: .date)
                        .font(.headline)
                        .foregroundColor(.textColor)
                    Text(weekdayLabel)
                        .font(.subheadline)
                        .foregroundColor(isToday ? .accent : .secondaryTextColor)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    // Delete entry button
                    if let entry = entry, !entry.body.isEmpty && !isEditMode {
                        Button(action: { showDeleteConfirmation = true }) {
                            Image(systemName: "trash")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.red)
                                .frame(width: 36, height: 36)
                                .background(.controlBackgroundColor)
                                .clipShape(Circle())
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                    
                    // Toggle edit button
                    Button(action: toggleEditMode) {
                        Image(systemName: isEditMode ? "checkmark" : "pencil")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.textColor)
                            .frame(width: 36, height: 36)
                            .background(.controlBackgroundColor)
                            .clipShape(Circle())
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isEditMode)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: entry?.body.isEmpty ?? true)
            }
            
            // Note content
            if isEditMode {
                TextEditor(text: $editedText)
                    .font(.body)
                    .foregroundColor(.textColor)
                    .background(.backgroundColor)
                    .frame(minHeight: 120)
                    .disableAutocorrection(false)
                    .autocapitalization(.sentences)
                    .focused($isTextEditorFocused)
                    // Alignment nudges to match the text view
                    .padding(.top, -8)
                    .padding(.horizontal, -5)
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
            editedText = entry?.body ?? ""
        }
        .confirmationDialog("Delete Note", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: deleteEntry)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Delete this note?")
        }
    }
    
    // MARK: - Private Methods
    private func toggleEditMode() {
        if isEditMode {
            // Save the note
            saveNote()
            isTextEditorFocused = false

            // Dismiss the sheet
            DispatchQueue.main.async {
                
            }
        } else {
            // Auto-focus the text editor when entering edit mode
            isTextEditorFocused = true
        }
        isEditMode.toggle()
    }
    
    private func deleteEntry() {
        guard let entry else { return }

        // Clear the entry's body
        entry.body = ""
        editedText = ""
        
        // Save the context to persist changes
        try? modelContext.save()
        
        // Dismiss the sheet
        dismiss()
    }
    
    private func saveNote() {
        withAnimation {
            if let entry {
                // Update existing entry
                entry.body = editedText
            } else if !editedText.isEmpty {
                // Create new entry only if there's content
                let newEntry = DayEntry(body: editedText, createdAt: date)
                modelContext.insert(newEntry)
            }
            
            // Save the context to persist changes
            try? modelContext.save()
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

#Preview {
    @Previewable @State var isEditMode = false
    @Previewable @State var editedText: String = ""
    
    VStack {
        EntryEditingSheetView(
            date: Date(),
            entry: DayEntry(body: "", createdAt: Date()),
            isEditMode: $isEditMode,
            editedText: $editedText
        )
    }
}
