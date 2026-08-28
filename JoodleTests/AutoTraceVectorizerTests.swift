//
//  AutoTraceVectorizerTests.swift
//  JoodleTests
//
//  Covers the decisions that determine what the user actually ends up looking
//  at after an auto-trace: the coordinate flip out of Vision's space, the noise
//  cull, arc-length resampling, and the stroke/point budgets that keep a traced
//  doodle from bloating `drawingData`.
//
//  Deliberately Vision-free — the vectorizer takes plain polylines, so all of
//  this runs without an image or a model.
//

import CoreGraphics
import Foundation
import Testing

@testable import Joodle

struct AutoTraceVectorizerTests {

  private let canvas: CGFloat = CANVAS_SIZE

  /// A closed unit-square-ish loop inset from the image edges, big enough to
  /// survive every detail level's cull.
  private func bigLoop(inset: CGFloat = 0.1) -> AutoTraceContour {
    AutoTraceContour(
      normalizedPoints: [
        CGPoint(x: inset, y: inset),
        CGPoint(x: 1 - inset, y: inset),
        CGPoint(x: 1 - inset, y: 1 - inset),
        CGPoint(x: inset, y: 1 - inset),
      ],
      depth: 0)
  }

  // MARK: - Coordinate space

  @Test func normalizedOriginMapsToBottomLeftOfCanvas() {
    // Vision's origin is bottom-left with y up; the canvas is top-left with y
    // down. (0,0) must therefore land at the canvas's BOTTOM-left.
    let mapped = AutoTraceVectorizer.canvasPoints(
      fromNormalized: [CGPoint(x: 0, y: 0)], canvasSize: canvas)
    #expect(abs(mapped[0].x - 0) < 1e-9)
    #expect(abs(mapped[0].y - canvas) < 1e-9)
  }

  @Test func normalizedTopRightMapsToCanvasTopRight() {
    let mapped = AutoTraceVectorizer.canvasPoints(
      fromNormalized: [CGPoint(x: 1, y: 1)], canvasSize: canvas)
    #expect(abs(mapped[0].x - canvas) < 1e-9)
    #expect(abs(mapped[0].y - 0) < 1e-9)
  }

  @Test func pointsOutsideTheUnitSquareAreClamped() {
    let mapped = AutoTraceVectorizer.canvasPoints(
      fromNormalized: [CGPoint(x: -0.2, y: 1.4)], canvasSize: canvas)
    #expect(mapped[0].x >= 0)
    #expect(mapped[0].y >= 0)
    #expect(mapped[0].x <= canvas)
    #expect(mapped[0].y <= canvas)
  }

  // MARK: - Perimeter

  @Test func openPerimeterExcludesTheClosingSegment() {
    let square = [
      CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
      CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10),
    ]
    #expect(abs(AutoTraceVectorizer.perimeter(of: square, closed: false) - 30) < 1e-9)
    #expect(abs(AutoTraceVectorizer.perimeter(of: square, closed: true) - 40) < 1e-9)
  }

  @Test func perimeterOfDegenerateInputIsZero() {
    #expect(AutoTraceVectorizer.perimeter(of: [], closed: true) == 0)
    #expect(AutoTraceVectorizer.perimeter(of: [CGPoint(x: 3, y: 4)], closed: true) == 0)
  }

  // MARK: - Resampling

  @Test func resamplingSpacesPointsEvenlyAlongTheLine() {
    let line = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
    let resampled = AutoTraceVectorizer.resample(polyline: line, spacing: 2)
    #expect(resampled.count == 6)  // 0, 2, 4, 6, 8, 10
    for i in 1..<resampled.count {
      #expect(abs((resampled[i].x - resampled[i - 1].x) - 2) < 1e-6)
    }
  }

  @Test func resamplingKeepsSpacingEvenAcrossACorner() {
    // Two 3-long legs at a right angle. If leftover distance were dropped at the
    // vertex instead of carried, the point after the corner would sit 2 from the
    // corner rather than 1.
    let bent = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 0), CGPoint(x: 3, y: 3)]
    let resampled = AutoTraceVectorizer.resample(polyline: bent, spacing: 2)
    for i in 1..<resampled.count {
      let dx = resampled[i].x - resampled[i - 1].x
      let dy = resampled[i].y - resampled[i - 1].y
      let step = (dx * dx + dy * dy).squareRoot()
      // The final partial step to the endpoint is allowed to be short.
      if i < resampled.count - 1 {
        #expect(step <= 2 + 1e-6)
      }
    }
    #expect(resampled.last.map { abs($0.x - 3) < 1e-6 && abs($0.y - 3) < 1e-6 } == true)
  }

  @Test func closedLoopResamplingReturnsToItsStart() {
    let loop = [
      CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0),
      CGPoint(x: 20, y: 20), CGPoint(x: 0, y: 20),
    ]
    let resampled = AutoTraceVectorizer.resample(closedLoop: loop, spacing: 3)
    guard let first = resampled.first, let last = resampled.last else {
      Issue.record("expected a resampled loop")
      return
    }
    #expect(abs(first.x - last.x) < 1e-9)
    #expect(abs(first.y - last.y) < 1e-9)
  }

  @Test func resamplingRejectsNonPositiveSpacing() {
    let line = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
    #expect(AutoTraceVectorizer.resample(closedLoop: line, spacing: 0).isEmpty)
  }

  // MARK: - Culling

  @Test func specksBelowTheMinimumPerimeterAreDropped() {
    // A 0.001-wide loop: far under even `.detailed`'s 1.2% of canvas perimeter.
    let speck = AutoTraceContour(
      normalizedPoints: [
        CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.501, y: 0.5), CGPoint(x: 0.501, y: 0.501),
      ], depth: 0)
    let strokes = AutoTraceVectorizer.vectorize(
      contours: [speck], detail: .detailed, canvasSize: canvas)
    #expect(strokes.isEmpty)
  }

  @Test func contoursDeeperThanTheLevelAllowsAreDropped() {
    let deep = AutoTraceContour(normalizedPoints: bigLoop().normalizedPoints, depth: 2)
    // `.simple` keeps top-level contours only.
    #expect(
      AutoTraceVectorizer.vectorize(contours: [deep], detail: .simple, canvasSize: canvas).isEmpty)
    // `.detailed` descends two levels, so the same contour survives.
    #expect(
      !AutoTraceVectorizer.vectorize(contours: [deep], detail: .detailed, canvasSize: canvas)
        .isEmpty)
  }

  @Test func theImageFrameItselfIsNotATrace() {
    // Contour detection reports the bitmap's own boundary as a contour. It's the
    // longest thing in any frame, so left in it wins every ranking — a photo of a
    // blank wall would trace as a big rectangle.
    let frame = AutoTraceContour(
      normalizedPoints: [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
      ], depth: 0)
    let strokes = AutoTraceVectorizer.vectorize(
      contours: [frame], detail: .detailed, canvasSize: canvas)
    #expect(strokes.isEmpty)
  }

  @Test func borderDetectionIsByPositionNotBySize() {
    // A subject that fills the frame and touches the edges must survive — only
    // contours that run *along* the border are the border.
    let big = AutoTraceVectorizer.canvasPoints(
      fromNormalized: [
        CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5),
        CGPoint(x: 0.5, y: 1),
      ], canvasSize: canvas)
    #expect(!AutoTraceVectorizer.isImageBorder(big, canvasSize: canvas))

    let frame = AutoTraceVectorizer.canvasPoints(
      fromNormalized: [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
      ], canvasSize: canvas)
    #expect(AutoTraceVectorizer.isImageBorder(frame, canvasSize: canvas))
  }

  @Test func borderDetectionIgnoresEmptyInput() {
    #expect(!AutoTraceVectorizer.isImageBorder([], canvasSize: canvas))
  }

  @Test func emptyInputProducesNoStrokes() {
    #expect(AutoTraceVectorizer.vectorize(contours: [], detail: .balanced, canvasSize: canvas).isEmpty)
  }

  // MARK: - Budgets

  @Test func strokeCountNeverExceedsTheLevelsBudget() {
    let many = (0..<400).map { _ in bigLoop(inset: 0.05) }
    for detail in AutoTraceDetail.allCases {
      let strokes = AutoTraceVectorizer.vectorize(
        contours: many, detail: detail, canvasSize: canvas)
      #expect(strokes.count <= detail.maxStrokes)
    }
  }

  @Test func totalPointCountNeverExceedsTheLevelsBudget() {
    let many = (0..<400).map { _ in bigLoop(inset: 0.05) }
    for detail in AutoTraceDetail.allCases {
      let strokes = AutoTraceVectorizer.vectorize(
        contours: many, detail: detail, canvasSize: canvas)
      let total = strokes.reduce(0) { $0 + $1.points.count }
      #expect(total <= detail.maxPoints)
    }
  }

  @Test func longestContoursWinTheBudget() {
    // One big loop and many small-but-legal ones, with a budget that can't hold
    // them all: the big one must survive.
    let big = bigLoop(inset: 0.02)
    let smalls = (0..<200).map { _ in bigLoop(inset: 0.44) }
    let strokes = AutoTraceVectorizer.vectorize(
      contours: smalls + [big], detail: .simple, canvasSize: canvas)
    let longest = strokes.map { AutoTraceVectorizer.perimeter(of: $0.points, closed: false) }.max()
    let smallPerimeter = AutoTraceVectorizer.perimeter(
      of: AutoTraceVectorizer.canvasPoints(
        fromNormalized: bigLoop(inset: 0.44).normalizedPoints, canvasSize: canvas),
      closed: true)
    #expect((longest ?? 0) > smallPerimeter)
  }

  // MARK: - Output shape

  @Test func tracedStrokesAreNeverDots() {
    let strokes = AutoTraceVectorizer.vectorize(
      contours: [bigLoop()], detail: .balanced, canvasSize: canvas)
    #expect(!strokes.isEmpty)
    #expect(strokes.allSatisfy { !$0.isDot })
  }

  @Test func everyStrokeHasEnoughPointsToDraw() {
    let strokes = AutoTraceVectorizer.vectorize(
      contours: [bigLoop()], detail: .balanced, canvasSize: canvas)
    #expect(
      strokes.allSatisfy { $0.points.count >= AutoTraceVectorizer.minimumPointsPerStroke })
  }

  @Test func everyPointLandsInsideTheCanvas() {
    let strokes = AutoTraceVectorizer.vectorize(
      contours: [bigLoop(inset: 0)], detail: .detailed, canvasSize: canvas)
    for stroke in strokes {
      for point in stroke.points {
        #expect(point.x >= 0 && point.x <= canvas)
        #expect(point.y >= 0 && point.y <= canvas)
      }
    }
  }

  @Test func coordinatesAreRoundedToTenths() {
    let strokes = AutoTraceVectorizer.vectorize(
      contours: [bigLoop(inset: 0.137)], detail: .balanced, canvasSize: canvas)
    for stroke in strokes {
      for point in stroke.points {
        #expect(abs(point.x * 10 - (point.x * 10).rounded()) < 1e-6)
        #expect(abs(point.y * 10 - (point.y * 10).rounded()) < 1e-6)
      }
    }
  }

  // MARK: - Levels

  @Test func higherDetailNeverProducesFewerPointsOnTheSameInput() {
    // The point of the ruler: nudging it up must actually buy more drawing.
    let contours = (0..<60).map { i in
      AutoTraceContour(normalizedPoints: bigLoop(inset: 0.02 + CGFloat(i) * 0.005).normalizedPoints,
        depth: 0)
    }
    let counts = AutoTraceDetail.allCases.map { detail in
      AutoTraceVectorizer.vectorize(contours: contours, detail: detail, canvasSize: canvas)
        .reduce(0) { $0 + $1.points.count }
    }
    #expect(counts[0] <= counts[1])
    #expect(counts[1] <= counts[2])
  }

  @Test func levelSteppingClampsAtBothEnds() {
    #expect(AutoTraceDetail.simple.decreased == .simple)
    #expect(AutoTraceDetail.detailed.increased == .detailed)
    #expect(AutoTraceDetail.simple.increased == .balanced)
    #expect(AutoTraceDetail.detailed.decreased == .balanced)
  }
}
