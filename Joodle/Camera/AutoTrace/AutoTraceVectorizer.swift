//
//  AutoTraceVectorizer.swift
//  Joodle
//
//  Turns detected contours into Joodle stroke data.
//
//  Deliberately Vision-free: the input is plain normalized polylines, so every
//  rule that decides what the user actually ends up looking at — the coordinate
//  flip, the noise cull, the resampling, the budgets — is exercisable in a unit
//  test without a Vision request or an image.
//

import CoreGraphics
import Foundation

/// A contour handed to the vectorizer: points in Vision's normalized space
/// (0...1, origin bottom-left, y up), plus how deep in the contour hierarchy it
/// was found. Contours are closed loops; the first point is not repeated.
struct AutoTraceContour: Equatable {
  let normalizedPoints: [CGPoint]
  let depth: Int

  init(normalizedPoints: [CGPoint], depth: Int = 0) {
    self.normalizedPoints = normalizedPoints
    self.depth = depth
  }
}

enum AutoTraceVectorizer {

  /// Minimum points a stroke needs before it's worth storing. Two points is a
  /// hairline that reads as a speck at grid size; three is the smallest thing
  /// with a direction change.
  static let minimumPointsPerStroke = 3

  /// Fraction of a contour's *length* that must run along the canvas edge before
  /// it is treated as the image frame rather than as something in the photo.
  static let borderLengthFraction: CGFloat = 0.9

  /// How close to an edge counts as being on it, in canvas points.
  static let borderTolerance: CGFloat = 1.0

  /// Coordinates are snapped to the nearest `1 / coordinateDecimals` of a point
  /// before encoding. The canvas is 342pt and the smallest place a doodle is
  /// ever drawn is a 26pt grid cell (a ~13× downscale), so integer precision —
  /// a ±0.5pt error that maps to ±0.04pt on the grid — is invisible, and drops
  /// the decimal digit from every coordinate, shrinking the JSON further than
  /// any fractional rounding could (tenths and halves both still encode a
  /// decimal place).
  private static let coordinateDecimals: CGFloat = 1

  // MARK: - Entry point

  /// Converts detected contours into stroke data in canvas space.
  ///
  /// Ordering matters: cull first (cheap, removes most candidates), then rank by
  /// perimeter so the budget is spent on the largest structures, then resample
  /// only the survivors — resampling everything and discarding later would do
  /// the expensive work for contours that were never going to be kept.
  static func vectorize(
    contours: [AutoTraceContour],
    detail: AutoTraceDetail,
    canvasSize: CGFloat
  ) -> [PathData] {
    vectorize(contours: contours, config: AutoTraceConfig(detail: detail), canvasSize: canvasSize)
  }

  /// Config-driven vectorization. The preset overload above funnels into this
  /// via `AutoTraceConfig(detail:)`, so both paths share one implementation.
  static func vectorize(
    contours: [AutoTraceContour],
    config: AutoTraceConfig,
    canvasSize: CGFloat
  ) -> [PathData] {
    let minPerimeter = CGFloat(config.minPerimeterFraction) * canvasSize * 4

    // Map into canvas space and cull noise in one pass.
    let candidates: [(points: [CGPoint], perimeter: CGFloat)] =
      contours.compactMap { contour in
        guard contour.depth <= config.childDepth else { return nil }
        let points = canvasPoints(fromNormalized: contour.normalizedPoints, canvasSize: canvasSize)
        guard points.count >= 2 else { return nil }
        guard !isImageBorder(points, canvasSize: canvasSize) else { return nil }
        let loop = perimeter(of: points, closed: true)
        guard loop >= minPerimeter else { return nil }
        return (points, loop)
      }

    // Longest first, so a tight budget keeps the drawing's structure.
    let ranked = candidates.sorted { $0.perimeter > $1.perimeter }

    var strokes: [PathData] = []
    var pointBudget = config.maxPoints

    for candidate in ranked {
      guard strokes.count < config.maxStrokes else { break }
      guard pointBudget >= minimumPointsPerStroke else { break }

      var resampled = resample(
        closedLoop: candidate.points, spacing: CGFloat(config.resampleSpacing))
      guard resampled.count >= minimumPointsPerStroke else { continue }

      // Never let a single contour eat the whole remaining budget mid-shape —
      // a truncated loop reads as a broken line. Skip it and let a smaller
      // contour that fits take the slot instead.
      if resampled.count > pointBudget { continue }

      resampled = resampled.map(rounded)
      pointBudget -= resampled.count
      strokes.append(PathData(points: resampled, isDot: false))
    }

    return strokes
  }

  // MARK: - Coordinate space

  /// Vision reports normalized coordinates with the origin at the bottom-left
  /// and y increasing upward; the canvas has the origin at the top-left with y
  /// increasing downward. Flip y, scale to canvas points, and clamp — a contour
  /// that grazes the image edge can round a hair outside 0...canvasSize, which
  /// would otherwise push a stroke under the canvas's clip.
  static func canvasPoints(fromNormalized points: [CGPoint], canvasSize: CGFloat) -> [CGPoint] {
    points.map { p in
      CGPoint(
        x: min(max(p.x * canvasSize, 0), canvasSize),
        y: min(max((1 - p.y) * canvasSize, 0), canvasSize)
      )
    }
  }

  /// Whether a contour is just the edge of the bitmap.
  ///
  /// Contour detection reliably reports the image boundary itself as a contour —
  /// twice, in fact, as the outer and inner lip of the frame. It is the longest
  /// thing in any frame, so left in it wins every ranking and survives every
  /// perimeter cull: a photo of a blank wall would trace as a big rectangle, and
  /// on any photo it would outrank the actual subject.
  ///
  /// Measured by how much of the contour *runs along* an edge, weighted by
  /// length, rather than by how many of its points touch one. A diamond
  /// inscribed in the frame has every vertex on an edge but no length along one,
  /// and counting points would throw it away — the vertex count of a
  /// polygon-approximated contour is far too coarse a signal to divide on.
  static func isImageBorder(_ points: [CGPoint], canvasSize: CGFloat) -> Bool {
    guard points.count >= 2, let last = points.last else { return false }

    var total: CGFloat = 0
    var alongEdge: CGFloat = 0
    var previous = last  // contours are closed loops

    for point in points {
      let length = distance(previous, point)
      if length > 0 {
        total += length
        let midpoint = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
        if isOnEdge(midpoint, canvasSize: canvasSize) { alongEdge += length }
      }
      previous = point
    }

    guard total > 0 else { return false }
    return alongEdge >= total * borderLengthFraction
  }

  private static func isOnEdge(_ point: CGPoint, canvasSize: CGFloat) -> Bool {
    point.x <= borderTolerance || point.y <= borderTolerance
      || point.x >= canvasSize - borderTolerance || point.y >= canvasSize - borderTolerance
  }

  // MARK: - Geometry

  /// Total length of a polyline. `closed` adds the segment back to the start.
  static func perimeter(of points: [CGPoint], closed: Bool) -> CGFloat {
    guard points.count >= 2 else { return 0 }
    var total: CGFloat = 0
    for i in 1..<points.count {
      total += distance(points[i - 1], points[i])
    }
    if closed, let first = points.first, let last = points.last {
      total += distance(last, first)
    }
    return total
  }

  /// Resamples a closed contour to roughly even spacing and returns it with the
  /// first point repeated at the end so the loop visibly closes when rendered as
  /// connected segments.
  static func resample(closedLoop points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
    guard let first = points.first, points.count >= 2, spacing > 0 else { return [] }
    var walked = resample(polyline: points + [first], spacing: spacing)
    guard walked.count >= 2 else { return [] }
    // Snap the tail exactly onto the head; arc-length walking can stop a
    // fraction short of the final vertex.
    walked[walked.count - 1] = first
    return walked
  }

  /// Walks a polyline emitting a point every `spacing` of arc length. The first
  /// and last vertices are always kept so the stroke starts and ends where the
  /// contour does.
  static func resample(polyline points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
    guard points.count >= 2, spacing > 0 else { return points }

    var output: [CGPoint] = [points[0]]
    // Distance already walked past the last emitted point.
    var carried: CGFloat = 0

    for i in 1..<points.count {
      let start = points[i - 1]
      let end = points[i]
      var segment = distance(start, end)
      guard segment > 0 else { continue }

      let dx = (end.x - start.x) / segment
      let dy = (end.y - start.y) / segment
      // How far into this segment the next emitted point falls.
      var cursor = spacing - carried

      while cursor <= segment {
        output.append(CGPoint(x: start.x + dx * cursor, y: start.y + dy * cursor))
        cursor += spacing
      }

      // Leftover distance rolls into the next segment so spacing stays even
      // across vertices instead of resetting at every corner.
      segment = segment - (cursor - spacing)
      carried = segment
    }

    if let last = points.last, let emitted = output.last, distance(emitted, last) > 0.001 {
      output.append(last)
    }
    return output
  }

  // MARK: - Helpers

  private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    return (dx * dx + dy * dy).squareRoot()
  }

  private static func rounded(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: (point.x * coordinateDecimals).rounded() / coordinateDecimals,
      y: (point.y * coordinateDecimals).rounded() / coordinateDecimals
    )
  }
}
