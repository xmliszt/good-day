//
//  FeatureTipOverlayView.swift
//  Joodle
//
//  Floating, hit-test-transparent overlay that renders the active feature tip:
//  a small bubble with a directional beak pointing at the target control. It
//  never blocks input (`.allowsHitTesting(false)`) — the user keeps full
//  control of the underlying UI. Positioning is derived from the anchor frame
//  published by `FeatureTipManager`; when a scoped tip's target is off-screen,
//  the bubble clamps to the published `fallbackEdge` and points toward it.
//

import SwiftUI

struct FeatureTipOverlayView: View {
    @ObservedObject private var manager = FeatureTipManager.shared

    /// Cached top safe-area inset. Only changes on rotation, so we capture it
    /// when the overlay size changes instead of walking the window list on every
    /// (per-scroll-frame) render.
    @State private var topInset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            if let tip = manager.activeTip, let target = resolvedTarget(tip: tip, screenSize: geo.size) {
                // Anchor frames are reported in global space, but the bubble
                // positions itself in this overlay's local space. They coincide
                // when the overlay fills the window (app root), but when it's
                // hosted inside a presented sheet the overlay's origin is offset
                // from the window — so translate the target into local space.
                let localOrigin = geo.frame(in: .global).origin
                FeatureTipBubble(
                    message: tip.message,
                    targetFrame: target.frame.offsetBy(dx: -localOrigin.x, dy: -localOrigin.y),
                    horizontalTarget: tip.horizontalTarget,
                    targetInset: tip.targetInset,
                    screenSize: geo.size
                )
                .opacity(target.opacity)
                .id(tip.id)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            // Report full-screen height so the manager can derive the fallback
            // edge from a last-known anchor frame, and refresh the cached inset.
            Color.clear
                .onAppear {
                    manager.setViewportHeight(geo.size.height)
                    topInset = Self.keyWindowTopInset
                }
                .onChange(of: geo.size.height) { _, newHeight in
                    manager.setViewportHeight(newHeight)
                    topInset = Self.keyWindowTopInset
                }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        // Crisp, bouncy entry/exit.
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: manager.activeTip?.id)
    }

    /// Resolve the bubble's target frame and opacity for the current state, or
    /// `nil` when nothing should show.
    ///
    /// - On-screen target: follow the live frame, fading out as it nears the top
    ///   safe area (there's never a reason to point a fresh tip *upward*).
    /// - Off-screen below (`.bottom`): clamp flush to the bottom edge, fully
    ///   opaque, beak pointing down.
    /// - Off-screen above (`.top`): hide — the fade already took it to zero.
    private func resolvedTarget(tip: FeatureTip, screenSize: CGSize) -> (frame: CGRect, opacity: Double)? {
        // `.anchorVisible` tips (e.g. camera) only ever show against a live
        // frame, with no edge-clamp or scroll fade.
        guard case .scoped = tip.behavior else {
            return manager.activeFrame.map { ($0, 1) }
        }

        if let frame = manager.activeFrame {
            // A lazy List/grid can register the target's frame while the cell
            // still sits entirely below the fold. Chasing that off-screen frame
            // slides the bubble out of view (a flash-then-vanish); instead clamp
            // to the bottom edge — keeping the target's x so the beak stays
            // column-aligned — until its top actually enters the viewport.
            if frame.minY >= screenSize.height {
                return (Self.bottomEdgeFrame(screenSize: screenSize, pointingAtX: frame.midX), 1)
            }
            return (frame, topFadeOpacity(targetMinY: frame.minY))
        }
        switch manager.fallbackEdge {
        case .bottom:
            return (Self.bottomEdgeFrame(screenSize: screenSize), 1)
        case .top:
            return nil
        }
    }

    /// Fade the tip out as its target scrolls up into the top safe area: fully
    /// visible until ~10pt before the safe-area boundary, fully gone once the
    /// target has scrolled past the safe-area height.
    private func topFadeOpacity(targetMinY: CGFloat) -> Double {
        let fadeStart = topInset + 10  // opacity 1 at or below this y
        let fadeEnd: CGFloat = 0  // opacity 0 once scrolled past the safe area
        guard fadeStart > fadeEnd else { return targetMinY > fadeEnd ? 1 : 0 }
        let t = (targetMinY - fadeEnd) / (fadeStart - fadeEnd)
        return Double(min(max(t, 0), 1))
    }

    /// A zero-size frame parked just past the bottom edge, so the bubble math
    /// places the bubble just inside that edge with the beak pointing down.
    /// `pointingAtX` aims the beak at a known target column; it defaults to the
    /// horizontal center when the target's position isn't known yet.
    private static func bottomEdgeFrame(screenSize: CGSize, pointingAtX x: CGFloat? = nil) -> CGRect {
        CGRect(x: x ?? screenSize.width / 2, y: screenSize.height, width: 0, height: 0)
    }

    /// Top safe-area inset of the key window (the overlay ignores the safe area,
    /// so `GeometryReader` reports none).
    private static var keyWindowTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
    }
}

// MARK: - Bubble

private struct FeatureTipBubble: View {
    let message: LocalizedStringResource
    let targetFrame: CGRect
    let horizontalTarget: FeatureTipHorizontalTarget
    /// Points the attach edge is pulled into the target — see `FeatureTip.targetInset`.
    let targetInset: CGFloat
    let screenSize: CGSize

    @State private var bubbleSize: CGSize = .zero

    private let maxWidth: CGFloat = 240
    private let gap: CGFloat = 10          // distance between target edge and beak tip
    private let edgePadding: CGFloat = 16  // keep bubble this far from screen edges
    private let beakWidth: CGFloat = 18
    private let beakHeight: CGFloat = 9
    private let cornerRadius: CGFloat = 16
    /// Points the beak is pushed back under the pill so the two read as one
    /// shape: butted edge-to-edge they leave a hairline antialiasing seam.
    private let beakOverlap: CGFloat = 1
    /// Roughly half a UISwitch's width — used to aim the beak at the switch when
    /// the target is a whole toggle row rather than the control itself.
    private let trailingInset: CGFloat = 26

    /// The x the beak should point at within the target.
    private var pointX: CGFloat {
        switch horizontalTarget {
        case .center:   return targetFrame.midX
        case .trailing: return targetFrame.maxX - trailingInset
        }
    }

    /// Place below the target when there's more room below; otherwise above.
    private var placeBelow: Bool {
        let spaceAbove = targetFrame.minY
        let spaceBelow = screenSize.height - targetFrame.maxY
        return spaceBelow >= spaceAbove
    }

    /// Horizontal center of the bubble, clamped to stay on screen.
    private var bubbleCenterX: CGFloat {
        let half = bubbleSize.width / 2
        let minX = edgePadding + half
        let maxX = screenSize.width - edgePadding - half
        guard minX <= maxX else { return screenSize.width / 2 }
        return min(max(pointX, minX), maxX)
    }

    /// The y the beak tip aims at: the target's near edge, pulled `targetInset`
    /// into the frame (never past its middle).
    private var pointY: CGFloat {
        let inset = min(max(targetInset, 0), targetFrame.height / 2)
        return placeBelow ? targetFrame.maxY - inset : targetFrame.minY + inset
    }

    /// Vertical center of the whole bubble+beak stack. When the target is past a
    /// screen edge (off-screen), this sits the bubble flush against that edge —
    /// intentionally ignoring the safe area so it reads as "blocked by the edge".
    private var bubbleCenterY: CGFloat {
        // `bubbleSize` is the measured pill *and* beak (the whole VStack), so the
        // beak must not be added again here — doing so parked every bubble a beak
        // further from its target than `gap` says.
        let half = bubbleSize.height / 2
        return placeBelow ? pointY + gap + half : pointY - gap - half
    }

    /// Beak horizontal offset from the bubble center so it keeps pointing at the
    /// target even when the bubble is clamped to a screen edge. Bounded so the
    /// beak's whole base stays on the pill's straight edge — pushed into a
    /// rounded corner, the curve cuts away from the base and the beak reads as a
    /// detached triangle.
    private var beakOffsetX: CGFloat {
        let raw = pointX - bubbleCenterX
        let limit = max(0, bubbleSize.width / 2 - cornerRadius - beakWidth / 2)
        return min(max(raw, -limit), limit)
    }

    var body: some View {
        // Negative spacing tucks the beak's base under the pill so the seam
        // between two identically-filled shapes never shows.
        VStack(spacing: -beakOverlap) {
            if placeBelow {
                beak(pointingUp: true)
            }

            Text(message)
                .font(.appBody())
                .foregroundColor(.appAccentContrast)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: maxWidth)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.appAccent)
                )

            if !placeBelow {
                beak(pointingUp: false)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { bubbleSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in bubbleSize = newSize }
            }
        )
        .position(x: bubbleCenterX, y: bubbleCenterY)
    }

    private func beak(pointingUp: Bool) -> some View {
        BeakTriangle()
            .fill(Color.appAccent)
            .frame(width: beakWidth, height: beakHeight)
            .rotationEffect(.degrees(pointingUp ? 0 : 180))
            .offset(x: beakOffsetX)
    }
}

// MARK: - Beak Shape

/// Upward-pointing triangle; rotated 180° for downward beaks. Adapted from the
/// referenced tooltip gist.
private struct BeakTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))   // tip
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) // bottom-right
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)) // bottom-left
        path.closeSubpath()
        return path
    }
}

// MARK: - Previews

#Preview("Feature Tip - Below target") {
    ZStack {
        Color.backgroundColor.ignoresSafeArea()
        Circle()
            .fill(Color.appAccent)
            .frame(width: 44, height: 44)
            .position(x: 340, y: 120)

        FeatureTipBubble(
            message: "Take a photo as reference",
            targetFrame: CGRect(x: 318, y: 98, width: 44, height: 44),
            horizontalTarget: .center,
            targetInset: 0,
            screenSize: CGSize(width: 393, height: 852)
        )
    }
}

#Preview("Feature Tip - Screen-edge target") {
    // The zoom ruler: a tall target hugging the screen edge, so the beak is
    // pushed as far right as the pill's straight edge allows and the attach point
    // is inset past the ruler's empty flare.
    ZStack {
        Color.backgroundColor.ignoresSafeArea()
        RoundedRectangle(cornerRadius: 20)
            .fill(Color.black)
            .frame(width: 48, height: 275)
            .position(x: 369, y: 634)

        FeatureTipBubble(
            message: "Try dragging to zoom",
            targetFrame: CGRect(x: 345, y: 497, width: 48, height: 275),
            horizontalTarget: .center,
            targetInset: 40,
            screenSize: CGSize(width: 393, height: 852)
        )
    }
}

#Preview("Feature Tip - Clamped to bottom edge") {
    ZStack {
        Color.backgroundColor.ignoresSafeArea()

        FeatureTipBubble(
            message: "Make your doodles wiggle",
            targetFrame: CGRect(x: 196, y: 852, width: 0, height: 0),
            horizontalTarget: .center,
            targetInset: 0,
            screenSize: CGSize(width: 393, height: 852)
        )
    }
}
