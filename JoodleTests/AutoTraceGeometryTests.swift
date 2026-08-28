//
//  AutoTraceGeometryTests.swift
//  JoodleTests
//
//  Covers `PhotoBackdropGeometry.backdropTransform` — the map auto-trace uses to
//  rasterize the reference photo exactly as the canvas is showing it. If this
//  drifts from `SharedCanvasView`'s modifier chain, traces silently stop lining
//  up with the photo, so the cases below pin the chain's semantics: scale and
//  rotation about the canvas centre, offset in screen space, applied in that
//  order.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Joodle

struct AutoTraceGeometryTests {

  private let canvas: CGFloat = CANVAS_SIZE
  private var centre: CGPoint { CGPoint(x: canvas / 2, y: canvas / 2) }

  private func transform(zoom: CGFloat, degrees: Double, offset: CGSize) -> CGAffineTransform {
    PhotoBackdropGeometry.backdropTransform(
      zoom: zoom, rotation: .degrees(degrees), offset: offset, canvasSize: canvas)
  }

  private func expectClose(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 1e-6) {
    #expect(abs(a.x - b.x) < tolerance)
    #expect(abs(a.y - b.y) < tolerance)
  }

  // MARK: - Identity

  @Test func restingTransformIsIdentity() {
    let t = transform(zoom: 1, degrees: 0, offset: .zero)
    expectClose(CGPoint(x: 0, y: 0).applying(t), CGPoint(x: 0, y: 0))
    expectClose(CGPoint(x: canvas, y: canvas).applying(t), CGPoint(x: canvas, y: canvas))
  }

  // MARK: - Scale

  @Test func zoomScalesAboutTheCanvasCentre() {
    let t = transform(zoom: 2, degrees: 0, offset: .zero)
    // The centre is the fixed point of a pure scale.
    expectClose(centre.applying(t), centre)
    // A corner moves outward by the zoom factor.
    expectClose(
      CGPoint(x: 0, y: 0).applying(t),
      CGPoint(x: centre.x - canvas, y: centre.y - canvas))
  }

  @Test func rotationBoostsScaleJustEnoughToKeepTheCanvasCovered() {
    // At 45° a 1× photo would expose the corners, so the render scale is lifted
    // to √2 — the same `effectiveZoom` the canvas uses.
    let t = transform(zoom: 1, degrees: 45, offset: .zero)
    let scale = (t.a * t.a + t.b * t.b).squareRoot()
    #expect(abs(scale - 2.0.squareRoot()) < 1e-6)
  }

  // MARK: - Rotation

  @Test func rotationTurnsAboutTheCanvasCentre() {
    let t = transform(zoom: 1, degrees: 90, offset: .zero)
    expectClose(centre.applying(t), centre)
  }

  @Test func rotationMatchesSwiftUIsClockwiseConvention() {
    // In the canvas's y-down space a positive angle reads clockwise, so a point
    // directly above the centre swings to the centre's right.
    // Use 90° where the cover boost is exactly 1, keeping the maths exact.
    let t = transform(zoom: 1, degrees: 90, offset: .zero)
    let above = CGPoint(x: centre.x, y: centre.y - 50)
    expectClose(above.applying(t), CGPoint(x: centre.x + 50, y: centre.y))
  }

  // MARK: - Offset

  @Test func offsetTranslatesInScreenSpace() {
    let t = transform(zoom: 1, degrees: 0, offset: CGSize(width: 20, height: -12))
    expectClose(centre.applying(t), CGPoint(x: centre.x + 20, y: centre.y - 12))
  }

  @Test func offsetIsAppliedAfterRotationNotBeforeIt() {
    // This is the ordering that `.scaleEffect → .rotationEffect → .offset`
    // implies. If offset were rotated too, the centre would land somewhere else
    // entirely at 90°.
    let t = transform(zoom: 1, degrees: 90, offset: CGSize(width: 30, height: 0))
    expectClose(centre.applying(t), CGPoint(x: centre.x + 30, y: centre.y))
  }

  @Test func offsetIsNotScaledByZoom() {
    let t = transform(zoom: 3, degrees: 0, offset: CGSize(width: 10, height: 10))
    expectClose(centre.applying(t), CGPoint(x: centre.x + 10, y: centre.y + 10))
  }

  // MARK: - Composition

  @Test func combinedTransformIsInvertible() {
    let t = transform(zoom: 2.4, degrees: 33, offset: CGSize(width: -18, height: 7))
    let point = CGPoint(x: 91, y: 240)
    expectClose(point.applying(t).applying(t.inverted()), point, tolerance: 1e-4)
  }

  @Test func transformAgreesWithEffectiveZoomForItsScale() {
    for degrees in [0.0, 17, 45, 90, 133] {
      for zoom in [1.0, 1.6, 3.0] {
        let t = transform(zoom: zoom, degrees: degrees, offset: .zero)
        let scale = (t.a * t.a + t.b * t.b).squareRoot()
        let expected = PhotoBackdropGeometry.effectiveZoom(
          zoom: zoom, rotation: .degrees(degrees))
        #expect(abs(scale - expected) < 1e-6)
      }
    }
  }
}
