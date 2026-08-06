//
//  MoveDrawingOverlayView.swift
//  Joodle
//

import Combine
import SwiftUI

// MARK: - Gradient layers

/// Animated mesh gradient with accent-based colors (iOS 18+)
@available(iOS 18.0, *)
private struct AccentMeshGradient: View {
  let maskTimer: Float

  var body: some View {
    MeshGradient(width: 3, height: 3, points: [
      .init(0, 0), .init(0.5, 0), .init(1, 0),
      [sinInRange(-0.8...(-0.2), offset: 0.439, timeScale: 0.342, t: maskTimer), sinInRange(0.3...0.7, offset: 3.42, timeScale: 0.984, t: maskTimer)],
      [sinInRange(0.1...0.8, offset: 0.239, timeScale: 0.084, t: maskTimer), sinInRange(0.2...0.8, offset: 5.21, timeScale: 0.242, t: maskTimer)],
      [sinInRange(1.0...1.5, offset: 0.939, timeScale: 0.084, t: maskTimer), sinInRange(0.4...0.8, offset: 0.25, timeScale: 0.642, t: maskTimer)],
      [sinInRange(-0.8...0.0, offset: 1.439, timeScale: 0.442, t: maskTimer), sinInRange(1.4...1.9, offset: 3.42, timeScale: 0.984, t: maskTimer)],
      [sinInRange(0.3...0.6, offset: 0.339, timeScale: 0.784, t: maskTimer), sinInRange(1.0...1.2, offset: 1.22, timeScale: 0.772, t: maskTimer)],
      [sinInRange(1.0...1.5, offset: 0.939, timeScale: 0.056, t: maskTimer), sinInRange(1.3...1.7, offset: 0.47, timeScale: 0.342, t: maskTimer)],
    ], colors: [
      .appAccent.hueRotated(by: 40),
      .appAccent.hueRotated(by: 30),
      .appAccent.hueRotated(by: 20),
      .appAccent.hueRotated(by: 10),
      .appAccent,
      .appAccent.hueRotated(by: -10),
      .appAccent.hueRotated(by: -20),
      .appAccent.hueRotated(by: -30),
      .appAccent.hueRotated(by: -40)
    ])
    .ignoresSafeArea()
  }

  private func sinInRange(_ range: ClosedRange<Float>, offset: Float, timeScale: Float, t: Float) -> Float {
    let amplitude = (range.upperBound - range.lowerBound) / 2
    let midPoint = (range.upperBound + range.lowerBound) / 2
    return midPoint + amplitude * sin(timeScale * t + offset)
  }
}

/// Rotating angular gradient fallback for iOS 17
private struct AccentAngularGradientLayer: View {
  var body: some View {
    AngularGradient(
      colors: [
        .appAccent.hueRotated(by: 40),
        .appAccent.hueRotated(by: 30),
        .appAccent.hueRotated(by: 20),
        .appAccent.hueRotated(by: 10),
        .appAccent,
        .appAccent.hueRotated(by: -10),
        .appAccent.hueRotated(by: -20),
        .appAccent.hueRotated(by: -30),
        .appAccent.hueRotated(by: -40)
      ],
      center: .center,
      startAngle: .degrees(0),
      endAngle: .degrees(360)
    )
    .ignoresSafeArea()
  }
}

// MARK: - Animated Gradient Border

struct MoveDrawingGradientBorder: View {
  @State private var t: Float = 0
  private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let cornerRadius = UIDevice.screenCornerRadius
      let diagonal = hypot(size.width, size.height)

      ZStack {
        // Gradient layer masked to the border band — matches prototype's MeshGradient-through-mask approach
        gradientLayer
          // Render into a diagonal-sized surface so rotation never exposes empty corners.
          .frame(width: diagonal + cornerRadius * 2, height: diagonal + cornerRadius * 2)
          .rotationEffect(.degrees(Double(t) * 30), anchor: .center)
          .frame(width: size.width, height: size.height)
          .mask {
            Canvas { context, canvasSize in
              // Ring = outer shape minus inner inset shape (even-odd fill).
              var ring = Path()
              let canvasRect = CGRect(origin: .zero, size: canvasSize)

              ring.addPath(
                Path(
                  roundedRect: canvasRect.insetBy(dx: -10, dy: -10),
                  cornerRadius: 0
                )
              )

              ring.addPath(
                Path(
                  roundedRect: canvasRect.insetBy(dx: 10, dy: 10),
                  cornerRadius: max(cornerRadius, 0)
                )
              )

              context.fill(ring, with: .color(.white), style: FillStyle(eoFill: true))
            }
          }
          .blur(radius: 10) // soft outer glow bleeding from the ring
      }
      .frame(width: size.width, height: size.height)
    }
    .ignoresSafeArea()
    .onReceive(ticker) { _ in
      t += 0.04
    }
  }

  @ViewBuilder
  private var gradientLayer: some View {
    if #available(iOS 18.0, *) {
      AccentMeshGradient(maskTimer: t)
    } else {
      AccentAngularGradientLayer()
    }
  }
}

// MARK: - Floating Bottom Instruction Bar

struct MoveDrawingBottomBar: View {
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: 16) {
      Text(String(localized: "Tap any date to move your doodle there"))
        .font(.appSubheadline())
        .foregroundColor(.textColor)
        .lineLimit(1)
        .minimumScaleFactor(0.8)

      Button {
        onCancel()
      } label: {
        Text(String(localized: "Cancel"))
          .font(.appSubheadline(weight: .semibold))
          .foregroundColor(.appAccent)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(
      Capsule()
        .fill(.ultraThinMaterial)
    )
  }
}

// MARK: - Previews

#Preview("Gradient Border") {
  ZStack {
    Color.appBackground.ignoresSafeArea()
    MoveDrawingGradientBorder()
  }
}

#Preview("Full Move Mode") {
  ZStack {
    Color.black.ignoresSafeArea()
    MoveDrawingGradientBorder()
    VStack {
      Spacer()
      MoveDrawingBottomBar(onCancel: {})
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
    }
  }
}
