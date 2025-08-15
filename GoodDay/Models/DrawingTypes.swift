//
//  DrawingTypes.swift
//  GoodDay
//
//  Created by Li Yuxuan on 10/8/25.
//

import Foundation
import SwiftUI

let CANVAS_SIZE: CGFloat = 300
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


