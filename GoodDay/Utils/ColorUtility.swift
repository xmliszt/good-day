//
//  ColorUtility.swift
//  GoodDay
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftUI

/// ShapeStyle extension providing consistent dynamic colors across the app
extension ShapeStyle where Self == Color {
    /// Primary background color that adapts to light/dark mode
    static var backgroundColor: Color {
        Color(UIColor.systemBackground)
    }
    
    /// Primary text color that adapts to light/dark mode
    static var textColor: Color {
        Color(UIColor.label)
    }
    
    /// Secondary text color with reduced opacity
    static var secondaryTextColor: Color {
        Color(UIColor.secondaryLabel)
    }
    
    /// Background color for interactive controls
    static var controlBackgroundColor: Color {
        Color(UIColor.tertiarySystemFill)
    }
    
    /// Border color for UI elements
    static var borderColor: Color {
        Color(UIColor.separator)
    }
}
