//
//  View.swift
//  Joodle
//
//  Created by Li Yuxuan on 14/8/25.
//

import SwiftUI

// MARK: - Circular Glass Button Style
struct CircularGlassButtonStyle: ViewModifier {
  let tintColor: Color?
  /// Optional backing color. On iOS 26 it tints the glass itself (so the color
  /// is part of the glass layer and morphs with a `GlassEffectContainer`
  /// metaball, rather than sitting as a static fill the morph stretches over);
  /// on earlier systems it replaces the default `.appSurface` fill.
  let backgroundColor: Color?

  /// Subtle dim applied while the button is disabled, so an unavailable action
  /// reads as inactive without fully hiding the glass.
  private static let disabledDimOpacity: Double = 0.4

  /// Set by an enclosing `.disabled(...)`. Drives the disabled dim so callers
  /// don't each hand-roll an opacity for the inactive state.
  @Environment(\.isEnabled) private var isEnabled

  func body(content: Content) -> some View {
    styledContent(content)
      .opacity(isEnabled ? 1.0 : Self.disabledDimOpacity)
      .animation(.easeInOut(duration: 0.2), value: isEnabled)
  }

  @ViewBuilder
  private func styledContent(_ content: Content) -> some View {
    if #available(iOS 26, *) {
      // iOS 26+: Use native glass background effect with circular shape. A
      // `backgroundColor` (e.g. black for the auto-trace button) tints the glass
      // itself so the color lives in the glass layer and morphs with a
      // `GlassEffectContainer` metaball — a solid fill behind the glass would
      // stay put while the morph stretched over it.
      content
        .font(.appFont(size: 18))
        .foregroundStyle(tintColor ?? Color.primary)
        .frame(width: 40, height: 40)
        .padding(2)
        .glassEffect(glassEffect(tintedWith: backgroundColor))
        .clipShape(Circle())
    } else {
      // Pre-iOS 26: Use custom circular background style
      // Note: Using stable foregroundStyle instead of conditional modifier
      // to prevent view identity issues that cause flickering during animations
      // Also using drawingGroup() to render in a separate layer, preventing
      // flickering when parent view animates (e.g., split view sliding up)
      content
        .font(.appFont(size: 18))
        .foregroundStyle(tintColor ?? Color.primary)
        .frame(width: 40, height: 40)
        .background(backgroundColor ?? .appSurface)
        .clipShape(Circle())
        .drawingGroup()
    }
  }

  @available(iOS 26, *)
  private func glassEffect(tintedWith color: Color?) -> Glass {
    let base = Glass.regular.interactive()
    return color.map { base.tint($0) } ?? base
  }
}

// MARK: - Pill Glass Background

/// Capsule-shaped Liquid Glass backing, matching `CircularGlassButtonStyle` but
/// sized to wrap a multi-icon pill (e.g. the clear + eraser pair on the canvas).
struct PillGlassBackground: ViewModifier {
  @Environment(\.isEnabled) private var isEnabled

  func body(content: Content) -> some View {
    Group {
      if #available(iOS 26, *) {
        content
          .glassEffect(.regular.interactive(), in: Capsule())
      } else {
        content
          .background(.appSurface)
          .clipShape(Capsule())
          .drawingGroup()
      }
    }
    .opacity(isEnabled ? 1.0 : 0.4)
    .animation(.easeInOut(duration: 0.2), value: isEnabled)
  }
}

// MARK: - Device Rotation Detection
/// Custom view modifier to track device rotation and call our action
struct DeviceRotationViewModifier: ViewModifier {
  let action: (UIDeviceOrientation) -> Void

  func body(content: Content) -> some View {
    content
      .onAppear()
      .onReceive(
        NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
      ) { _ in
        action(UIDevice.current.orientation)
      }
  }
}

// MARK: - Shake Detection
/// Custom view modifier to detect shake gestures
struct ShakeDetectionViewModifier: ViewModifier {
  let action: () -> Void

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
        action()
      }
  }
}

extension View {
  func onRotate(perform action: @escaping (UIDeviceOrientation) -> Void) -> some View {
    self.modifier(DeviceRotationViewModifier(action: action))
  }

  func onShake(perform action: @escaping () -> Void) -> some View {
    self.modifier(ShakeDetectionViewModifier(action: action))
  }

  @ViewBuilder
  func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
    if condition {
      transform(self)
    } else {
      self
    }
  }

  func circularGlassButton(tintColor: Color? = nil, backgroundColor: Color? = nil) -> some View {
    self.modifier(CircularGlassButtonStyle(tintColor: tintColor, backgroundColor: backgroundColor))
  }

  /// Disables the iOS 26 liquid glass effect by using a blur background style. No-op on earlier versions.
  @ViewBuilder
  func disableLiquidGlass() -> some View {
    if #available(iOS 26.0, *) {
      self.presentationBackground(Color.appBackground)
    } else {
      self
    }
  }
}
