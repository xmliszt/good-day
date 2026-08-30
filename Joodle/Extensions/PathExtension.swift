//
//  PathExtension.swift
//  Joodle
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftUI

extension Path {
  /// Extracts points from the path for serialization
  func extractPoints() -> [CGPoint] {
    // For dots (small ellipses), store the center point
    let boundingRect = self.boundingRect

    // Check if it's a dot (small circle created by tap)
    // We use DRAWING_LINE_WIDTH as a heuristic since dots are created with this diameter
    if boundingRect.width <= DRAWING_LINE_WIDTH && boundingRect.height <= DRAWING_LINE_WIDTH {
      let center = CGPoint(
        x: boundingRect.midX,
        y: boundingRect.midY
      )
      return [center]
    }

    // For regular paths, extract all points
    var points: [CGPoint] = []

    self.forEach { element in
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

// MARK: - Stroke Hit Testing (eraser)

/// Shortest distance from `point` to the segment `a`–`b`.
private func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
  let dx = b.x - a.x
  let dy = b.y - a.y
  if dx == 0 && dy == 0 {
    return hypot(point.x - a.x, point.y - a.y)
  }
  let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / (dx * dx + dy * dy)))
  let projX = a.x + t * dx
  let projY = a.y + t * dy
  return hypot(point.x - projX, point.y - projY)
}

/// Whether `point` lands within `radius` of the stroke described by `points`.
/// A dot (or single point) is a hit when the point is within `radius` of its
/// center; a polyline when it's within `radius` of any segment.
func strokeIsHit(point: CGPoint, points: [CGPoint], isDot: Bool, radius: CGFloat) -> Bool {
  guard let first = points.first else { return false }
  if isDot || points.count == 1 {
    return hypot(point.x - first.x, point.y - first.y) <= radius
  }
  for i in 1..<points.count {
    if distance(from: point, toSegment: points[i - 1], points[i]) <= radius {
      return true
    }
  }
  return false
}
