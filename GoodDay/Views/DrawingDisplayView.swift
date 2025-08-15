//
//  DrawingDisplayView.swift
//  GoodDay
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftUI

struct DrawingDisplayView: View {
    let entry: DayEntry?
    let displaySize: CGFloat
    @State private var paths: [Path] = []
    @State private var isVisible = false
    
    var body: some View {
        Canvas { context, size in
            // Scale paths to fit the displaySize (not the container size)
            let scale = displaySize / CANVAS_SIZE
            
            // Scale stroke width based on display size
            let scaledStrokeWidth = max(1.0, scale * DRAWING_LINE_WIDTH)
            
            // Center the drawing in the available canvas space
            let offsetX = (size.width - displaySize) / 2
            let offsetY = (size.height - displaySize) / 2
            
            for path in paths {
                var scaledPath = Path()
                path.forEach { element in
                    switch element {
                    case .move(to: let point):
                        scaledPath.move(to: CGPoint(
                            x: point.x * scale + offsetX, 
                            y: point.y * scale + offsetY
                        ))
                    case .line(to: let point):
                        scaledPath.addLine(to: CGPoint(
                            x: point.x * scale + offsetX, 
                            y: point.y * scale + offsetY
                        ))
                    case .quadCurve(to: let point, control: let control):
                        scaledPath.addQuadCurve(
                            to: CGPoint(
                                x: point.x * scale + offsetX, 
                                y: point.y * scale + offsetY
                            ),
                            control: CGPoint(
                                x: control.x * scale + offsetX, 
                                y: control.y * scale + offsetY
                            )
                        )
                    case .curve(to: let point, control1: let control1, control2: let control2):
                        scaledPath.addCurve(
                            to: CGPoint(
                                x: point.x * scale + offsetX, 
                                y: point.y * scale + offsetY
                            ),
                            control1: CGPoint(
                                x: control1.x * scale + offsetX, 
                                y: control1.y * scale + offsetY
                            ),
                            control2: CGPoint(
                                x: control2.x * scale + offsetX, 
                                y: control2.y * scale + offsetY
                            )
                        )
                    case .closeSubpath:
                        scaledPath.closeSubpath()
                    }
                }
                
                // Check if this is a dot (ellipse) path and render accordingly
                if isEllipsePath(scaledPath) {
                    context.fill(scaledPath, with: .color(.accent))
                } else {
                    context.stroke(
                        scaledPath, 
                        with: .color(.accent), 
                        style: StrokeStyle(
                            lineWidth: scaledStrokeWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
        }
        .scaleEffect(isVisible ? 1.0 : 0.9)
        .blur(radius: isVisible ? 0 : 5)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isVisible)
        .onAppear {
            // Reset animation state
            isVisible = false
            
            // Refresh after a short delay to ensure data is loaded
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.003) {
                loadDrawingData()
                
                // Trigger animation after data is loaded
                withAnimation {
                    isVisible = true
                }
            }
        }
        .onChange(of: entry?.drawingData) { _, _ in
            // Reset animation for new data
            isVisible = false
            loadDrawingData()
            
            // Animate in the new drawing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) {
                withAnimation {
                    isVisible = true
                }
            }
        }
    }
    
    private func isEllipsePath(_ path: Path) -> Bool {
        // Check if the path contains an ellipse by examining its characteristics
        let boundingRect = path.boundingRect
        let pathElements = extractElementsFromPath(path)
        
        // An ellipse created with addEllipse typically has multiple curve elements
        // and a relatively small, square-ish bounding box (for dots)
        if pathElements.count > 4 && 
           boundingRect.width < DRAWING_LINE_WIDTH * 2 && 
           boundingRect.height < DRAWING_LINE_WIDTH * 2 &&
           abs(boundingRect.width - boundingRect.height) < 1.0 {
            return true
        }
        
        return false
    }
    
    private func extractElementsFromPath(_ path: Path) -> [Path.Element] {
        var elements: [Path.Element] = []
        path.forEach { element in
            elements.append(element)
        }
        return elements
    }
    
    private func loadDrawingData() {
        guard let drawingData = entry?.drawingData else {
            paths = []
            return
        }
        
        do {
            let decodedPaths = try JSONDecoder().decode([PathData].self, from: drawingData)
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
        } catch {
            print("Failed to load drawing data for display: \(error)")
            paths = []
        }
    }
}



#Preview {
    DrawingDisplayView(entry: nil, displaySize: 200)
        .frame(width: 200, height: 200)
        .background(.gray.opacity(0.1))
}
