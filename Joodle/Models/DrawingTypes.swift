//
//  DrawingTypes.swift
//  Joodle
//
//  Created by Li Yuxuan on 10/8/25.
//

import Foundation
import SwiftUI

let CANVAS_SIZE: CGFloat = 342
/// Previous canvas size before the 342 migration, used for centering legacy drawings
let LEGACY_CANVAS_SIZE: CGFloat = 300
let DRAWING_LINE_WIDTH: CGFloat = 5.0

// MARK: - Drawing Data Types

struct PathData: Codable {
  let points: [CGPoint]
  let isDot: Bool

  init(points: [CGPoint], isDot: Bool = false) {
    self.points = points
    self.isDot = isDot
  }

  // Custom decoder for backward compatibility
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    points = try container.decode([CGPoint].self, forKey: .points)
    // Default to false if isDot is not present (backward compatibility)
    isDot = try container.decodeIfPresent(Bool.self, forKey: .isDot) ?? false
  }

  private enum CodingKeys: String, CodingKey {
    case points
    case isDot
  }
}

extension PathData {
  /// Rebuilds the drawable `Path` this stroke encodes — a dot becomes an
  /// ellipse of the stroke width, anything else a polyline. Mirrors the decode
  /// in `DrawingPathCache`, for callers that produce strokes in memory rather
  /// than loading them from `drawingData`.
  func makePath() -> Path {
    var path = Path()
    // A lone point is a dot whether or not the flag says so — that's how the
    // stored format has always been read back.
    let isSingleDot = isDot || points.count == 1

    if isSingleDot, let center = points.first {
      let radius = DRAWING_LINE_WIDTH / 2
      path.addEllipse(
        in: CGRect(
          x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
      return path
    }

    for (index, point) in points.enumerated() {
      if index == 0 {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }
    return path
  }
}
