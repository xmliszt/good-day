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
}


