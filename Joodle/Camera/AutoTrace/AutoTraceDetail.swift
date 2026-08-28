//
//  AutoTraceDetail.swift
//  Joodle
//
//  Tuning presets for the auto-trace pipeline. "Detail" is not one knob — each
//  level bundles the six parameters that have to move together for the result to
//  stay coherent: push contour detection harder and you must also loosen the
//  noise cull, tighten the simplification and raise the stroke budget, or the
//  extra contours are found and then immediately thrown away.
//
//  Three discrete stops rather than a continuous slider: every change costs a
//  full re-trace (a few hundred ms), so a continuous control would invite
//  scrubbing through work it can't keep up with.
//

import Foundation

enum AutoTraceDetail: Int, CaseIterable, Identifiable, Equatable {
  case simple = 0
  case balanced = 1
  case detailed = 2

  var id: Int { rawValue }

  /// The level a fresh trace starts at.
  static let `default`: AutoTraceDetail = .balanced

  // MARK: - Vision tuning

  /// Contrast boost applied by `VNDetectContoursRequest` before it looks for
  /// edges. Higher values collapse soft gradients into nothing, leaving only
  /// strong outlines — which is exactly what "simple" wants.
  var contrastAdjustment: Float {
    switch self {
    case .simple: return 3.0
    case .balanced: return 2.0
    case .detailed: return 1.4
    }
  }

  /// How deep into `VNContour.childContours` the walk descends. Child contours
  /// are the holes and interior detail inside an outline (the eyes inside a
  /// face); depth 0 keeps silhouettes only.
  var childDepth: Int {
    switch self {
    case .simple: return 0
    case .balanced: return 1
    case .detailed: return 2
    }
  }

  // MARK: - Simplification

  /// Epsilon handed to `VNContour.polygonApproximation(epsilon:)`, in Vision's
  /// normalized (0...1) space. Larger = blunter corners, fewer vertices.
  var polygonEpsilon: Float {
    switch self {
    case .simple: return 0.006
    case .balanced: return 0.003
    case .detailed: return 0.0015
    }
  }

  /// Spacing, in canvas points, that surviving contours are resampled to.
  /// `DoodleRendererView` draws straight segments between stored points and does
  /// no smoothing, so the only thing standing between a curve and a visibly
  /// faceted polygon is how close together we put the points.
  var resampleSpacing: CGFloat {
    switch self {
    case .simple: return 4.0
    case .balanced: return 2.5
    case .detailed: return 1.8
    }
  }

  // MARK: - Culling and budgets

  /// Minimum contour perimeter to keep, as a fraction of the canvas perimeter
  /// (`4 * CANVAS_SIZE`). Below this a contour is sensor noise or a texture
  /// speck, not a line someone would have drawn.
  var minPerimeterFraction: CGFloat {
    switch self {
    case .simple: return 0.06
    case .balanced: return 0.025
    case .detailed: return 0.012
    }
  }

  /// Hard ceiling on emitted strokes. Contours are ranked by perimeter and the
  /// longest ones win, so the budget spends itself on structure rather than on
  /// whichever specks Vision happened to return first.
  var maxStrokes: Int {
    switch self {
    case .simple: return 40
    case .balanced: return 120
    case .detailed: return 200
    }
  }

  /// Hard ceiling on total emitted points across all strokes. This is the
  /// number that keeps `DayEntry.drawingData` — which is JSON, and is mirrored
  /// into the widget app group — from bloating: roughly 13 bytes per point once
  /// coordinates are rounded, so 3800 points is about 49KB.
  var maxPoints: Int {
    switch self {
    case .simple: return 900
    case .balanced: return 2500
    case .detailed: return 3800
    }
  }

  // MARK: - Stepping

  /// Next level up, clamped at `.detailed`.
  var increased: AutoTraceDetail {
    AutoTraceDetail(rawValue: min(rawValue + 1, AutoTraceDetail.detailed.rawValue)) ?? self
  }

  /// Next level down, clamped at `.simple`.
  var decreased: AutoTraceDetail {
    AutoTraceDetail(rawValue: max(rawValue - 1, AutoTraceDetail.simple.rawValue)) ?? self
  }
}
