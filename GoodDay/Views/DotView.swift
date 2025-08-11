//
//  DotView.swift
//  GoodDay
//
//  Created by Li Yuxuan on 11/8/25.
//

import SwiftUI

enum DotStyle {
    case past
    case present
    case future
}

struct DotView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    // MARK: Params
    let size: CGFloat
    let highlighted: Bool
    let withEntry: Bool
    let dotStyle: DotStyle
    
    // MARK: Computed dot color
    private var dotColor: Color {
        let baseColor: Color = {
            // Override base color if it is a present dot.
            if dotStyle == .present {
                return .accent
            }
            return .textColor
        }()
        
        switch true {
        case withEntry, highlighted:
            return baseColor
        case dotStyle == .past, dotStyle == .present:
            return baseColor
        case dotStyle == .future:
            return baseColor.opacity(0.15)
        default:
            return baseColor
        }
    }
    
    // MARK: view
    var body: some View {
        ZStack {
            // Base dot that maintains layout - fixed size container
            Circle()
                .fill(Color.clear)
                .frame(width: size, height: size)
            
            // Visual dot that can scale without affecting layout
            Circle()
                .fill(dotColor)
                .frame(width: size, height: size)
                .scaleEffect(highlighted ? 2.0 : 1.0)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: highlighted)
            
            // Ring for entries - positioned absolutely
            if withEntry {
                Circle()
                    .stroke(dotColor, lineWidth: size * 0.15)
                    .frame(width: size * 1.5, height: size * 1.5)
                    .scaleEffect(highlighted ? 2.0 : 1.0)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: highlighted)
            }
        }
        // Use a fixed frame size to prevent layout changes
        .frame(width: size, height: size)
    }
}

#Preview {
    DotView(
        size: 12,
        highlighted: false,
        withEntry: false,
        dotStyle: .past
    )
    DotView(
        size: 12,
        highlighted: false,
        withEntry: true,
        dotStyle: .past
    )
    DotView(
        size: 12,
        highlighted: false,
        withEntry: false,
        dotStyle: .present
    )
    DotView(
        size: 12,
        highlighted: false,
        withEntry: true,
        dotStyle: .present
    )
}
