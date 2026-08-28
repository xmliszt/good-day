//
//  AutoTraceEngineSmokeTests.swift
//  JoodleTests
//
//  End-to-end smoke test of the real Vision pipeline against synthetic images.
//
//  Scope is deliberately narrow. Whether a trace of a real photo *looks good* is
//  not assertable — it depends on the subject, the lighting and a model whose
//  output isn't contractually stable — so these tests only pin the things that
//  must hold for any input: a high-contrast shape produces strokes, those
//  strokes land in canvas space, a blank frame produces none, and the budgets
//  survive the trip through Vision.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Joodle

struct AutoTraceEngineSmokeTests {

  /// A black disc centred on white — the least ambiguous thing a contour
  /// detector can be handed.
  private func discImage(side: CGFloat = 600, radius: CGFloat = 180) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
      .image { context in
        context.cgContext.setFillColor(UIColor.white.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.cgContext.setFillColor(UIColor.black.cgColor)
        context.cgContext.fillEllipse(
          in: CGRect(
            x: side / 2 - radius, y: side / 2 - radius, width: radius * 2, height: radius * 2))
      }
  }

  private func blankImage(side: CGFloat = 600) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
      .image { context in
        context.cgContext.setFillColor(UIColor.white.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: side, height: side))
      }
  }

  private func trace(
    _ image: UIImage, detail: AutoTraceDetail = .balanced, zoom: CGFloat = 1,
    degrees: Double = 0, offset: CGSize = .zero
  ) async -> AutoTraceOutcome {
    await AutoTraceEngine.trace(
      AutoTraceRequest(
        image: image, zoom: zoom, rotation: .degrees(degrees), offset: offset, detail: detail))
  }

  // MARK: - Flattening

  @Test func flatteningProducesASquareBitmap() {
    let flattened = AutoTraceFlattener.flatten(
      image: discImage(), zoom: 1, rotation: .zero, offset: .zero)
    guard let flattened else {
      Issue.record("expected a flattened bitmap")
      return
    }
    #expect(flattened.width == Int(AutoTraceFlattener.renderSide))
    #expect(flattened.height == Int(AutoTraceFlattener.renderSide))
  }

  // MARK: - Contour pipeline

  @Test func aHighContrastShapeProducesStrokes() async {
    let outcome = await trace(discImage())
    #expect(!outcome.strokes.isEmpty)
  }

  @Test func tracedStrokesLandInsideTheCanvas() async {
    let outcome = await trace(discImage())
    for stroke in outcome.strokes {
      for point in stroke.points {
        #expect(point.x >= 0 && point.x <= CANVAS_SIZE)
        #expect(point.y >= 0 && point.y <= CANVAS_SIZE)
      }
    }
  }

  @Test func aCentredDiscTracesToRoughlyTheMiddleOfTheCanvas() async {
    // Guards the y-flip: get the coordinate space wrong and a centred subject
    // still lands centred, but get the flip AND an offset wrong and this moves.
    // Combined with the offset case below, it pins orientation.
    let outcome = await trace(discImage())
    guard let longest = outcome.strokes.max(by: { $0.points.count < $1.points.count }) else {
      Issue.record("expected at least one stroke")
      return
    }
    let xs = longest.points.map(\.x)
    let ys = longest.points.map(\.y)
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
    else { return }
    let midX = (minX + maxX) / 2
    let midY = (minY + maxY) / 2
    #expect(abs(midX - CANVAS_SIZE / 2) < CANVAS_SIZE * 0.15)
    #expect(abs(midY - CANVAS_SIZE / 2) < CANVAS_SIZE * 0.15)
  }

  @Test func movingThePhotoDownMovesTheTraceDown() async {
    // The reference photo's offset is in canvas (y-down) space, so a positive
    // height must push the traced subject toward the bottom of the canvas. This
    // is the assertion that actually catches a flipped y.
    let centred = await trace(discImage())
    let shifted = await trace(discImage(), offset: CGSize(width: 0, height: 60))

    func midY(_ outcome: AutoTraceOutcome) -> CGFloat? {
      guard let longest = outcome.strokes.max(by: { $0.points.count < $1.points.count })
      else { return nil }
      let ys = longest.points.map(\.y)
      guard let lo = ys.min(), let hi = ys.max() else { return nil }
      return (lo + hi) / 2
    }

    guard let before = midY(centred), let after = midY(shifted) else {
      Issue.record("expected strokes from both traces")
      return
    }
    #expect(after > before)
  }

  @Test func aBlankFrameProducesNothingWorthDrawing() async {
    let outcome = await trace(blankImage(), detail: .simple)
    #expect(outcome.strokes.isEmpty)
  }

  // MARK: - Budgets survive the real pipeline

  @Test func budgetsHoldForEveryLevel() async {
    for detail in AutoTraceDetail.allCases {
      let outcome = await trace(discImage(), detail: detail)
      #expect(outcome.strokes.count <= detail.maxStrokes)
      let total = outcome.strokes.reduce(0) { $0 + $1.points.count }
      #expect(total <= detail.maxPoints)
    }
  }

  // MARK: - Round trip

  @Test func tracedStrokesSurviveTheDrawingDataRoundTrip() async throws {
    // The whole point of emitting `PathData` is that a trace is indistinguishable
    // from a finger-drawn doodle downstream — same encode, same decode, same
    // widget payload.
    let outcome = await trace(discImage())
    #expect(!outcome.strokes.isEmpty)

    let encoded = try JSONEncoder().encode(outcome.strokes)
    let decoded = try JSONDecoder().decode([PathData].self, from: encoded)

    #expect(decoded.count == outcome.strokes.count)
    for (original, roundTripped) in zip(outcome.strokes, decoded) {
      #expect(original.points.count == roundTripped.points.count)
      #expect(original.isDot == roundTripped.isDot)
    }
  }

  @Test func aTracedStrokeBuildsANonEmptyPath() async {
    let outcome = await trace(discImage())
    guard let stroke = outcome.strokes.first else {
      Issue.record("expected at least one stroke")
      return
    }
    #expect(!stroke.makePath().isEmpty)
  }
}
