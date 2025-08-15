//
//  DrawingCanvasView.swift
//  GoodDay
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftUI

struct DrawingCanvasView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    let date: Date
    let entry: DayEntry?
    @Binding var editedText: String
    
    @State private var currentPath = Path()
    @State private var paths: [Path] = []
    @State private var showClearConfirmation = false
    @State private var currentEntry: DayEntry?
    
    // Undo/Redo state management
    @State private var undoStack: [[Path]] = []
    @State private var redoStack: [[Path]] = []
    
    var body: some View {
        VStack(spacing: 16) {
            // Header with clear, undo/redo, and save buttons
            HStack {
                // Clear button
                Button(action: { showClearConfirmation = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.red)
                        .frame(width: 36, height: 36)
                        .background(.controlBackgroundColor)
                        .clipShape(Circle())
                }
                .disabled(paths.isEmpty && currentPath.isEmpty)
                .opacity(paths.isEmpty && currentPath.isEmpty ? 0.5 : 1.0)
                
                Spacer()
                
                // Undo/Redo buttons
                HStack(spacing: 8) {
                    // Undo button
                    Button(action: undoLastStroke) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.textColor)
                            .frame(width: 32, height: 32)
                            .background(.controlBackgroundColor)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(undoStack.isEmpty)
                    .opacity(undoStack.isEmpty ? 0.3 : 1.0)
                    
                    // Redo button
                    Button(action: redoLastStroke) {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.textColor)
                            .frame(width: 32, height: 32)
                            .background(.controlBackgroundColor)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(redoStack.isEmpty)
                    .opacity(redoStack.isEmpty ? 0.3 : 1.0)
                }
                
                Spacer()
                
                // Save button
                Button(action: saveDrawing) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.textColor)
                        .frame(width: 36, height: 36)
                        .background(.controlBackgroundColor)
                        .clipShape(Circle())
                }
            }
            
            // Drawing canvas
            VStack(spacing: 12) {
                ZStack {
                    // Canvas background
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.backgroundColor)
                        .stroke(.borderColor, lineWidth: 1.0)
                        .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
                    
                    // Drawing area
                    Canvas { context, size in
                        // Draw all completed paths
                        for path in paths {
                            context.stroke(
                                path, 
                                with: .color(.accent), 
                                style: StrokeStyle(
                                    lineWidth: DRAWING_LINE_WIDTH,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                        }
                        
                        // Draw current path being drawn
                        if !currentPath.isEmpty {
                            context.stroke(
                                currentPath, 
                                with: .color(.accent), 
                                style: StrokeStyle(
                                    lineWidth: DRAWING_LINE_WIDTH,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                        }
                    }
                    .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let point = value.location
                                
                                // Ensure the point is within canvas bounds
                                guard point.x >= 0 && point.x <= CANVAS_SIZE &&
                                      point.y >= 0 && point.y <= CANVAS_SIZE else { return }
                                
                                if currentPath.isEmpty {
                                    currentPath.move(to: point)
                                } else {
                                    currentPath.addLine(to: point)
                                }
                            }
                            .onEnded { _ in
                                if !currentPath.isEmpty {
                                    // Save current state to undo stack before making changes
                                    saveStateToUndoStack()
                                    
                                    paths.append(currentPath)
                                    currentPath = Path()
                                    
                                    // Clear redo stack when new action is performed
                                    redoStack.removeAll()
                                    
                                    // Save immediately to store
                                    saveDrawingToStore()
                                }
                            }
                    )
                }
                
                // Instructions
                Text("Draw with your finger")
                    .font(.caption)
                    .foregroundColor(.secondaryTextColor)
            }
        }
        .padding(20)
        .background(.backgroundColor)
        .onAppear {
            currentEntry = entry
            loadExistingDrawing()
        }
        .confirmationDialog("Clear Drawing", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive, action: clearDrawing)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Clear all drawing?")
        }
    }
    
    // MARK: - Private Methods
    
    private func saveStateToUndoStack() {
        // Save current paths state to undo stack
        undoStack.append(paths)
        
        // Limit undo stack size to prevent memory issues
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
    }
    
    private func undoLastStroke() {
        guard !undoStack.isEmpty else { return }
        
        // Save current state to redo stack
        redoStack.append(paths)
        
        // Restore previous state from undo stack
        paths = undoStack.removeLast()
        
        // Clear current path if user is in middle of drawing
        currentPath = Path()
        
        // Save to store
        saveDrawingToStore()
        
        // Limit redo stack size
        if redoStack.count > 50 {
            redoStack.removeFirst()
        }
    }
    
    private func redoLastStroke() {
        guard !redoStack.isEmpty else { return }
        
        // Save current state to undo stack
        saveStateToUndoStack()
        
        // Restore state from redo stack
        paths = redoStack.removeLast()
        
        // Clear current path if user is in middle of drawing
        currentPath = Path()
        
        // Save to store
        saveDrawingToStore()
    }
    
    private func loadExistingDrawing() {
        guard let data = currentEntry?.drawingData else { 
            // Initialize with empty state for new drawings
            undoStack.removeAll()
            redoStack.removeAll()
            return 
        }
        
        do {
            let decodedPaths = try JSONDecoder().decode([PathData].self, from: data)
            paths = decodedPaths.map { pathData in
                var path = Path()
                for (index, point) in pathData.points.enumerated() {
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                return path
            }
            
            // Initialize undo/redo stacks for existing drawings
            undoStack.removeAll()
            redoStack.removeAll()
            
        } catch {
            print("Failed to load drawing data: \(error)")
        }
    }
    
    private func saveDrawing() {
        saveDrawingToStore()
        dismiss()
    }
    
    private func saveDrawingToStore() {
        if let existingEntry = currentEntry {
                // Update existing entry
                if paths.isEmpty {
                    // No paths means no drawing data
                    existingEntry.drawingData = nil
                } else {
                    // Convert paths to serializable data
                    let pathsData = paths.map { path in
                        PathData(points: extractPointsFromPath(path))
                    }
                    
                    do {
                        let data = try JSONEncoder().encode(pathsData)
                        existingEntry.drawingData = data
                    } catch {
                        print("Failed to save drawing data: \(error)")
                        existingEntry.drawingData = nil
                    }
                }
            } else if !paths.isEmpty || !editedText.isEmpty {
                // Create new entry
                if paths.isEmpty {
                    // Only text content, no drawing
                    let newEntry = DayEntry(body: editedText, createdAt: date, drawingData: nil)
                    modelContext.insert(newEntry)
                    currentEntry = newEntry
                } else {
                    // Has drawing content
                    let pathsData = paths.map { path in
                        PathData(points: extractPointsFromPath(path))
                    }
                    
                    do {
                        let data = try JSONEncoder().encode(pathsData)
                        let newEntry = DayEntry(body: editedText, createdAt: date, drawingData: data)
                        modelContext.insert(newEntry)
                        currentEntry = newEntry
                    } catch {
                        print("Failed to save drawing data: \(error)")
                        let newEntry = DayEntry(body: editedText, createdAt: date, drawingData: nil)
                        modelContext.insert(newEntry)
                        currentEntry = newEntry
                    }
                }
            }
            
            // Save the context to persist changes
            try? modelContext.save()
    }
    
    private func clearDrawing() {
        // Save current state to undo stack before clearing
        if !paths.isEmpty {
            saveStateToUndoStack()
        }
        
        paths.removeAll()
        currentPath = Path()
        
        // Clear redo stack when new action is performed
        redoStack.removeAll()
        
        // Also clear from store
        if let existingEntry = currentEntry {
            existingEntry.drawingData = nil
            try? modelContext.save()
        }
    }
    
    private func extractPointsFromPath(_ path: Path) -> [CGPoint] {
        // This is a simplified approach to extract points from a path
        // In a real implementation, you might want to use a more sophisticated method
        var points: [CGPoint] = []
        
        path.forEach { element in
            switch element {
            case .move(to: let point):
                points.append(point)
            case .line(to: let point):
                points.append(point)
            case .quadCurve(to: let point, control: _):
                points.append(point)
            case .curve(to: let point, control1: _, control2: _):
                points.append(point)
            case .closeSubpath:
                break
            }
        }
        
        return points
    }
}




#Preview {
    @Previewable @State var editedText: String = ""
    
    DrawingCanvasView(
        date: Date(),
        entry: nil,
        editedText: $editedText
    )
}
