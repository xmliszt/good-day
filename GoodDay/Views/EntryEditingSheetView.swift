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
    @State private var currentTime = Date()
    @State private var isTimerActive = false
    
    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }
    
    private var isFuture: Bool {
        date > Date()
    }
    
    private var weekdayLabel: String {
        if isToday { return "Today" }
        // Format to weekday (e.g. Monday, Tuesday)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
    
    /// Show count down text for future entry with body
    private var countdownText: String? {
        guard isFuture else { return nil }
        guard entry != nil && !entry!.body.isEmpty else { return nil }
        
        let calendar = Calendar.current
        let now = currentTime
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now, to: date)
        
        guard let years = components.year,
              let months = components.month,
              let days = components.day,
              let hours = components.hour,
              let minutes = components.minute,
              let seconds = components.second else { return nil }
        
        // More than a year: show year + month + day
        if years > 0 {
            var parts: [String] = []
            
            if years == 1 {
                parts.append("1 year")
            } else {
                parts.append("\(years) years")
            }
            
            if months > 0 {
                if months == 1 {
                    parts.append("1 month")
                } else {
                    parts.append("\(months) months")
                }
            }
            
            if days > 0 {
                if days == 1 {
                    parts.append("1 day")
                } else {
                    parts.append("\(days) days")
                }
            }
            
            return "in " + parts.joined(separator: ", ")
        }
        
        // More than a month but less than a year: show month + day
        if months > 0 {
            var parts: [String] = []
            
            if months == 1 {
                parts.append("1 month")
            } else {
                parts.append("\(months) months")
            }
            
            if days > 0 {
                if days == 1 {
                    parts.append("1 day")
                } else {
                    parts.append("\(days) days")
                }
            }
            
            return "in " + parts.joined(separator: ", ")
        }
        
        // More than 1 day: show days only
        if days > 1 {
            return "in \(days) days"
        }
        
        if days == 1 {
            return "in 1 day"
        }
        
        // Same day or next day with less than 24 hours: show hours, minutes, seconds
        if days == 0 && (hours > 0 || minutes > 0 || seconds > 0) {
            var parts: [String] = []

            if hours > 0 {
                if hours == 1 {
                    parts.append("1h")
                } else {
                    parts.append("\(hours)h")
                }
            }
            
            if minutes > 0 {
                if minutes == 1 {
                    parts.append("1m")
                } else {
                    parts.append("\(minutes)m")
                }
            }
            
            // More than 1 hour, as we only update time per minute,
            // we show only minutes
            if hours >= 1 {
                return "in " + parts.joined(separator: " ")
            }
            
            if seconds > 0 {
                if seconds == 1 {
                    parts.append("1s")
                } else {
                    parts.append("\(seconds)s")
                }
            }
            
            if parts.isEmpty {
                return "now"
            }
            
            return "in " + parts.joined(separator: " ")
        }
        
        return nil
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with date and edit button
            HStack {
                VStack(alignment: .leading) {
                    Text(date, style: .date)
                        .font(.headline)
                        .foregroundColor(.textColor)
                    HStack(spacing: 8) {
                        Text(weekdayLabel)
                            .font(.subheadline)
                            .foregroundColor(isToday ? .accent : .secondaryTextColor)
                        
                        if let countdown = countdownText {
                            Text(countdown)
                                .font(.subheadline)
                                .foregroundColor(.accent.opacity(0.7))
                        }
                    }
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
            startTimerIfNeeded()
        }
        .onDisappear {
            stopTimer()
        }
        /// On receive timer interval, update the current time if we still need updates
        .onReceive(Timer.publish(every: timerInterval, on: .main, in: .common).autoconnect()) { _ in
            // Only update if timer is active and we still need updates
            if isTimerActive && needsRealTimeUpdates {
                currentTime = Date()
            }
        }
        .confirmationDialog("Delete Note", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: deleteEntry)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Delete this note?")
        }
    }
    
    // MARK: - Private Methods
    /// Start the timer if needed
    private func startTimerIfNeeded() {
        // Only activate timer if we have a future entry with content and it's within 24 hours
        isTimerActive = isFuture && 
                       entry != nil && 
                       !entry!.body.isEmpty && 
                       needsRealTimeUpdates
        
        if isTimerActive { currentTime = Date() }
    }
    
    /// Stop the timer
    private func stopTimer() {
        isTimerActive = false
    }
    
    /// Check if we need real-time updates for the countdown text
    /// If it's within 24 hours, we need real-time updates
    /// If it's more than 24 hours, we don't need real-time updates
    private var needsRealTimeUpdates: Bool {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.day, .hour], from: now, to: date)
        
        // Need real-time updates if it's within 24 hours
        return (components.day ?? 0) <= 1 && (components.hour ?? 0) <= 24
    }
    
    /// Calculate the timer interval based on the date
    /// If it's more than 1 day, we don't need real-time updates
    /// If it's more than 1 hour, we update every minute
    /// If it's more than 1 minute, we update every second
    /// If it's less than 1 minute, we update every second for precise countdown
    private var timerInterval: TimeInterval {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.day, .hour, .minute], from: now, to: date)
        
        let days = components.day ?? 0
        let hours = components.hour ?? 0
        let minutes = components.minute ?? 0
        
        // More than 1 day: no timer needed (handled by needsRealTimeUpdates)
        if days > 1 { return 60.0 }
        
        // More than 1 hour: update every minute
        if hours > 1 { return 60.0 }
        
        // More than 1 minute: update every second
        if minutes > 1 { return 1.0 }
        
        // Less than 1 minute: update every second for precise countdown
        return 1.0
    }
    
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
