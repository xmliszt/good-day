//
//  EdgeMorphGeometryTests.swift
//  JoodleTests
//
//  Covers the silhouette geometry behind the edge panel's droplet-like
//  emergence: the protrusion that tracks the reveal, and the flare span and
//  Bézier tangents that re-form so the contour always meets the screen edge
//  tangentially instead of being sliced mid-curve.
//

import CoreGraphics
import Testing
@testable import Joodle

struct EdgeMorphGeometryTests {

  private let width: CGFloat = 48
  private let height: CGFloat = 275
  private let flareHeight: CGFloat = 64

  // MARK: - protrusion

  @Test func protrusionIsZeroWhenFullyTuckedAway() {
    #expect(EdgeMorphGeometry.protrusion(reveal: 0, width: width) == 0)
  }

  @Test func protrusionIsTheFullWidthWhenFullyOut() {
    #expect(EdgeMorphGeometry.protrusion(reveal: 1, width: width) == width)
  }

  @Test func protrusionTracksRevealProportionally() {
    #expect(abs(EdgeMorphGeometry.protrusion(reveal: 0.25, width: width) - 12) < 0.0001)
    #expect(abs(EdgeMorphGeometry.protrusion(reveal: 0.5, width: width) - 24) < 0.0001)
  }

  @Test func protrusionClampsANegativeReveal() {
    #expect(EdgeMorphGeometry.protrusion(reveal: -0.5, width: width) == 0)
  }

  /// Above 1 is an elastic overpull, not an error: it has to keep growing so the
  /// panel stretches inward off the edge.
  @Test func protrusionGrowsPastFullForAnOverpull() {
    #expect(EdgeMorphGeometry.protrusion(reveal: 1.5, width: width) > width)
    #expect(abs(EdgeMorphGeometry.protrusion(reveal: 1.5, width: width) - width * 1.5) < 0.0001)
  }

  /// An overpull must stretch the panel *only* — not also re-loosen the neck or
  /// distort the height, which would read as the shape coming apart.
  @Test func overpullLeavesEverythingButProtrusionAtItsFullValue() {
    let visibleAtFull = EdgeMorphGeometry.visibleHeight(reveal: 1, height: height)
    let visibleOver = EdgeMorphGeometry.visibleHeight(reveal: 1.6, height: height)
    #expect(abs(visibleOver - visibleAtFull) < 0.0001)

    let spanAtFull = EdgeMorphGeometry.flareSpan(
      reveal: 1, flareHeight: flareHeight, height: height)
    let spanOver = EdgeMorphGeometry.flareSpan(
      reveal: 1.6, flareHeight: flareHeight, height: height)
    #expect(abs(spanOver - spanAtFull) < 0.0001)

    #expect(abs(EdgeMorphGeometry.flareHandle(reveal: 1.6)
      - EdgeMorphGeometry.flareHandle(reveal: 1)) < 0.0001)
  }

  // MARK: - visibleHeight

  @Test func visibleHeightIsTheFullFrameWhenFullyOut() {
    #expect(abs(EdgeMorphGeometry.visibleHeight(reveal: 1, height: height) - height) < 0.0001)
  }

  @Test func visibleHeightGrowsWithReveal() {
    let tucked = EdgeMorphGeometry.visibleHeight(reveal: 0, height: height)
    let half = EdgeMorphGeometry.visibleHeight(reveal: 0.5, height: height)
    let out = EdgeMorphGeometry.visibleHeight(reveal: 1, height: height)
    #expect(tucked < half)
    #expect(half < out)
  }

  @Test func visibleHeightStaysPositiveEvenFullyTucked() {
    #expect(EdgeMorphGeometry.visibleHeight(reveal: 0, height: height) > 0)
  }

  @Test func visibleHeightClampsOutOfRangeReveals() {
    #expect(abs(EdgeMorphGeometry.visibleHeight(reveal: 2, height: height) - height) < 0.0001)
    let below = EdgeMorphGeometry.visibleHeight(reveal: -1, height: height)
    let atZero = EdgeMorphGeometry.visibleHeight(reveal: 0, height: height)
    #expect(abs(below - atZero) < 0.0001)
  }

  /// The droplet read depends on the flare cap biting against the *reduced*
  /// height: at low reveal the two flares should consume nearly all of it,
  /// leaving a lens rather than a slab with a straight face.
  @Test func flaresLeaveNoStraightFaceWhileBarelyEmerged() {
    let visible = EdgeMorphGeometry.visibleHeight(reveal: 0, height: height)
    let span = EdgeMorphGeometry.flareSpan(reveal: 0, flareHeight: flareHeight, height: visible)
    let straightFace = visible - 2 * span
    #expect(straightFace < visible * 0.1)
  }

  /// …and by full emergence the straight face is most of the panel, so the ruler
  /// has a flat run to sit against.
  @Test func flaresLeaveAStraightFaceWhenFullyOut() {
    let visible = EdgeMorphGeometry.visibleHeight(reveal: 1, height: height)
    let span = EdgeMorphGeometry.flareSpan(reveal: 1, flareHeight: flareHeight, height: visible)
    let straightFace = visible - 2 * span
    #expect(straightFace > visible * 0.4)
  }

  // MARK: - flareSpan

  @Test func flareSpanIsTheDesignedHeightWhenFullyOut() {
    let span = EdgeMorphGeometry.flareSpan(reveal: 1, flareHeight: flareHeight, height: height)
    #expect(abs(span - flareHeight) < 0.0001)
  }

  /// The cling: a barely-emerged panel spreads its neck further along the edge,
  /// which is what reads as surface tension rather than a mechanical scale.
  @Test func flareSpanRunsLongerAsThePanelRetreats() {
    let out = EdgeMorphGeometry.flareSpan(reveal: 1, flareHeight: flareHeight, height: height)
    let half = EdgeMorphGeometry.flareSpan(reveal: 0.5, flareHeight: flareHeight, height: height)
    let tucked = EdgeMorphGeometry.flareSpan(reveal: 0, flareHeight: flareHeight, height: height)
    #expect(half > out)
    #expect(tucked > half)
  }

  /// Top and bottom flares must never cross, or the silhouette self-intersects.
  @Test func flareSpanNeverExceedsHalfThePanelHeight() {
    for reveal in stride(from: CGFloat(0), through: 1, by: 0.05) {
      let span = EdgeMorphGeometry.flareSpan(reveal: reveal, flareHeight: flareHeight, height: height)
      #expect(span <= height / 2 - 1)
    }
  }

  @Test func flareSpanStaysNonNegativeForADegeneratePanel() {
    let span = EdgeMorphGeometry.flareSpan(reveal: 0.5, flareHeight: flareHeight, height: 1)
    #expect(span >= 0)
  }

  // MARK: - flareHandle

  @Test func flareHandleIsTheBaseValueWhenFullyOut() {
    let handle = EdgeMorphGeometry.flareHandle(reveal: 1)
    #expect(abs(handle - EdgeMorphGeometry.baseFlareHandle) < 0.0001)
  }

  @Test func flareHandleLengthensAsThePanelRetreats() {
    #expect(EdgeMorphGeometry.flareHandle(reveal: 0) > EdgeMorphGeometry.flareHandle(reveal: 1))
  }

  /// Past 1.0 the tangents would run beyond the flare's own span and the curve
  /// would fold back on itself.
  @Test func flareHandleStaysWithinASingleSpan() {
    for reveal in stride(from: CGFloat(0), through: 1, by: 0.05) {
      let handle = EdgeMorphGeometry.flareHandle(reveal: reveal)
      #expect(handle > 0)
      #expect(handle < 1)
    }
  }
}
