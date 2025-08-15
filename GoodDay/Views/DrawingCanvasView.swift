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
    @State private var isDrawing = false
    
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
                            // Check if this path contains an ellipse (dot)
                            if isEllipsePath(path) {
                                // Fill ellipse paths (dots)
                                context.fill(path, with: .color(.accent))
                            } else {
                                // Stroke line paths
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
                        }
                        
                        // Draw current path being drawn
                        if !currentPath.isEmpty {
                            if isEllipsePath(currentPath) {
                                // Fill ellipse paths (dots)
                                context.fill(currentPath, with: .color(.accent))
                            } else {
                                // Stroke line paths
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
                    }
                    .frame(width: CANVAS_SIZE, height: CANVAS_SIZE)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let point = value.location
                                let isInBounds = point.x >= 0 && point.x <= CANVAS_SIZE &&
                                               point.y >= 0 && point.y <= CANVAS_SIZE
                                
                                if isInBounds {
                                    // Point is within bounds
                                    if !isDrawing {
                                        // Starting a new stroke
                                        isDrawing = true
                                        currentPath.move(to: point)
                                    } else {
                                        // Continue current stroke
                                        currentPath.addLine(to: point)
                                    }
                                } else {
                                    // Point is out of bounds
                                    if isDrawing && !currentPath.isEmpty {
                                        // Commit the current stroke when going out of bounds
                                        commitCurrentStroke()
                                    }
                                }
                            }
                            .onEnded { value in
                                if isDrawing && !currentPath.isEmpty {
                                    let point = value.location
                                    let startLocation = value.startLocation
                                    let distance = sqrt(pow(point.x - startLocation.x, 2) + pow(point.y - startLocation.y, 2))
                                    
                                    // Check if this was a single tap within bounds
                                    if distance < 3.0 && 
                                       point.x >= 0 && point.x <= CANVAS_SIZE &&
                                       point.y >= 0 && point.y <= CANVAS_SIZE {
                                        // Create a small circle for the dot
                                        currentPath = Path()
                                        let dotRadius = DRAWING_LINE_WIDTH / 2
                                        currentPath.addEllipse(in: CGRect(
                                            x: point.x - dotRadius,
                                            y: point.y - dotRadius,
                                            width: dotRadius * 2,
                                            height: dotRadius * 2
                                        ))
                                    }
                                    
                                    // Commit the final stroke
                                    commitCurrentStroke()
                                }
                                
                                // Reset drawing state
                                isDrawing = false
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
    
    private func commitCurrentStroke() {
        guard !currentPath.isEmpty else { return }
        
        // Save current state to undo stack before making changes
        saveStateToUndoStack()
        
        // Add the current path to completed paths
        paths.append(currentPath)
        currentPath = Path()
        
        // Clear redo stack when new action is performed
        redoStack.removeAll()
        
        // Save immediately to store
        saveDrawingToStore()
        
        // Reset drawing state
        isDrawing = false
    }
    
    private func isEllipsePath(_ path: Path) -> Bool {
        // Check if the path contains an ellipse element
        var hasEllipse = false
        path.forEach { element in
            switch element {
            case .move, .line, .quadCurve, .curve, .closeSubpath:
                break
            }
        }
        
        // Since SwiftUI Path doesn't expose ellipse elements directly,
        // we'll use a heuristic: if the path has very few elements and was created
        // from addEllipse, it's likely an ellipse. For our use case, we can track
        // this differently by checking the path's bounding box and element count.
        let boundingRect = path.boundingRect
        let pathElements = extractElementsFromPath(path)
        
        // An ellipse created with addEllipse typically has multiple curve elements
        // and a relatively small, square-ish bounding box (for dots)
        if pathElements.count > 4 && 
           boundingRect.width < DRAWING_LINE_WIDTH * 2 && 
           boundingRect.height < DRAWING_LINE_WIDTH * 2 &&
           abs(boundingRect.width - boundingRect.height) < 1.0 {
            hasEllipse = true
        }
        
        return hasEllipse
    }
    
    private func extractElementsFromPath(_ path: Path) -> [Path.Element] {
        var elements: [Path.Element] = []
        path.forEach { element in
            elements.append(element)
        }
        return elements
    }
    
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
        isDrawing = false
        
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
        isDrawing = false
        
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
                if pathData.isDot && pathData.points.count >= 1 {
                    // Recreate dot as ellipse
                    let center = pathData.points[0]
                    let dotRadius = DRAWING_LINE_WIDTH / 2
                    path.addEllipse(in: CGRect(
                        x: center.x - dotRadius,
                        y: center.y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    ))
                } else {
                    // Recreate line path
                    for (index, point) in pathData.points.enumerated() {
                        if index == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
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
                        PathData(points: extractPointsFromPath(path), isDot: isEllipsePath(path))
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
                        PathData(points: extractPointsFromPath(path), isDot: isEllipsePath(path))
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
        isDrawing = false
        
        // Clear redo stack when new action is performed
        redoStack.removeAll()
        
        // Also clear from store
        if let existingEntry = currentEntry {
            existingEntry.drawingData = nil
            try? modelContext.save()
        }
    }
    
    private func extractPointsFromPath(_ path: Path) -> [CGPoint] {
        // Check if this is a dot (ellipse) path
        if isEllipsePath(path) {
            // For dots, store the center point
            let boundingRect = path.boundingRect
            let center = CGPoint(
                x: boundingRect.midX,
                y: boundingRect.midY
            )
            return [center]
        }
        
        // For regular paths, extract all points
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
