//
//  MetaballButtonView.swift
//  GoodDay
//
//  Created by Li Yuxuan on 12/8/25.
//

import SwiftUI

// Enum to represent the state of the button
enum MetaballButtonMode {
    case single
    case expanded
}

struct MetaballButtonView: View {
    // External bindings for integration with HeaderView
    let viewMode: ViewMode
    let onToggleViewMode: () -> Void
    let onSettingsAction: () -> Void
    
    // Computed property to sync with viewMode
    private var buttonMode: MetaballButtonMode {
        viewMode == .year ? .expanded : .single
    }

    // Animation properties
    private let animation = Animation.interactiveSpring(response: 0.5, dampingFraction: 0.7, blendDuration: 0)
    private let buttonSize: CGFloat = 38
    private let spacing: CGFloat = 6

    var body: some View {
        ZStack {
            // The background shapes that create the metaball effect
            // We use Capsules for a perfect join and split
            ZStack {
                // This capsule is always visible and forms the right-hand button
                Capsule()
                    .frame(width: buttonSize, height: buttonSize)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                // This capsule is the one that moves
                Capsule()
                    .frame(width: buttonSize, height: buttonSize)
                    // The offset moves the button into place when expanded
                    .offset(x: buttonMode == .expanded ? -(buttonSize + spacing) : 0)
                    // It's invisible when not expanded
                    .opacity(buttonMode == .expanded ? 1 : 0)
                    .frame(maxWidth: .infinity, alignment: .trailing)

            }
            // ✨ The Magic Modifiers ✨
            .drawingGroup() // 1. Render shapes into an offscreen buffer
            .contrast(1)     // 3. Sharpen the edges with high contrast
            .foregroundStyle(.controlBackgroundColor) // Use the app's control background color
            .animation(animation, value: buttonMode) // Animate the whole effect

            // The icons, placed on top of the metaball background
            HStack(spacing: spacing) {
                // Settings Icon (Left) - only visible when expanded
                Button(action: onSettingsAction) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: buttonSize, height: buttonSize)
                        .scaleEffect(buttonMode == .expanded ? 1 : 0) // Scale in/out
                        .opacity(buttonMode == .expanded ? 1 : 0)     // Fade in/out
                        .animation(animation.delay(0.1), value: buttonMode) // Staggered animation
                }
                .disabled(buttonMode != .expanded) // Disable interaction when not visible

                // Main Toggle Icon (Right) - changes based on viewMode
                Button(action: onToggleViewMode) {
                    Image(systemName: viewMode == .now ? "calendar" : "dot.circle")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: buttonSize, height: buttonSize)
                        .animation(.easeInOut(duration: 0.2), value: viewMode) // Smooth icon transition
                }
            }
            .foregroundColor(.textColor)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: buttonSize * 2 + spacing * 3, height: buttonSize)
    }
}

#Preview {
    @Previewable @State var viewMode: ViewMode = .now
    
    MetaballButtonView(
        viewMode: viewMode,
        onToggleViewMode: {
            viewMode = viewMode == .now ? .year : .now
        },
        onSettingsAction: {
            print("Settings tapped")
        }
    )
}
