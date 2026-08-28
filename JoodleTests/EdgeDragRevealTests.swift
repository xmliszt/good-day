//
//  EdgeDragRevealTests.swift
//  JoodleTests
//
//  Covers the pure geometry behind the temporary edge-drag zoom control
//  (JOO-147): the reveal fraction that tracks the pull, and the commit
//  threshold that decides whether a released drag stays out or retracts.
//

import CoreGraphics
import Testing
@testable import Joodle

struct EdgeDragRevealTests {

  // MARK: - revealFraction

  @Test func revealIsZeroAtTheEdge() {
    #expect(EdgeDragReveal.revealFraction(inwardTranslation: 0, pullDistance: 120) == 0)
  }

  @Test func revealTracksProportionallyWithinRange() {
    let quarter = EdgeDragReveal.revealFraction(inwardTranslation: 30, pullDistance: 120)
    let half = EdgeDragReveal.revealFraction(inwardTranslation: 60, pullDistance: 120)
    #expect(abs(quarter - 0.25) < 0.0001)
    #expect(abs(half - 0.5) < 0.0001)
  }

  @Test func revealClampsToOnePastFullPull() {
    #expect(EdgeDragReveal.revealFraction(inwardTranslation: 200, pullDistance: 120) == 1)
  }

  @Test func revealClampsToZeroWhenDraggingBackOutward() {
    #expect(EdgeDragReveal.revealFraction(inwardTranslation: -40, pullDistance: 120) == 0)
  }

  @Test func revealIsZeroForNonPositivePullDistance() {
    #expect(EdgeDragReveal.revealFraction(inwardTranslation: 50, pullDistance: 0) == 0)
    #expect(EdgeDragReveal.revealFraction(inwardTranslation: 50, pullDistance: -10) == 0)
  }

  // MARK: - shouldCommit

  @Test func commitsAtOrAboveTheThreshold() {
    #expect(EdgeDragReveal.shouldCommit(reveal: 0.5))
    #expect(EdgeDragReveal.shouldCommit(reveal: 0.9))
    #expect(EdgeDragReveal.shouldCommit(reveal: 1.0))
  }

  @Test func retractsBelowTheThreshold() {
    #expect(!EdgeDragReveal.shouldCommit(reveal: 0.49))
    #expect(!EdgeDragReveal.shouldCommit(reveal: 0.0))
  }

  @Test func honoursACustomThreshold() {
    #expect(EdgeDragReveal.shouldCommit(reveal: 0.3, threshold: 0.25))
    #expect(!EdgeDragReveal.shouldCommit(reveal: 0.3, threshold: 0.4))
  }

  // MARK: - rubberBand

  private let dimension: CGFloat = 26

  @Test func rubberBandIsZeroAtAndBeforeTheLimit() {
    #expect(EdgeDragReveal.rubberBand(distance: 0, dimension: dimension) == 0)
    #expect(EdgeDragReveal.rubberBand(distance: -50, dimension: dimension) == 0)
  }

  @Test func rubberBandIsZeroForADegenerateDimension() {
    #expect(EdgeDragReveal.rubberBand(distance: 50, dimension: 0) == 0)
  }

  /// The defining property: monotonic and never reversing. A fractional-power
  /// curve fails exactly here, turning back on itself past some input.
  @Test func rubberBandIsStrictlyMonotonic() {
    var previous = EdgeDragReveal.rubberBand(distance: 0, dimension: dimension)
    for distance in stride(from: CGFloat(1), through: 600, by: 1) {
      let current = EdgeDragReveal.rubberBand(distance: distance, dimension: dimension)
      #expect(current > previous)
      previous = current
    }
  }

  /// Asymptotic, so pulling arbitrarily hard can never run the panel away.
  @Test func rubberBandNeverReachesTheDimension() {
    #expect(EdgeDragReveal.rubberBand(distance: 10_000, dimension: dimension) < dimension)
    #expect(EdgeDragReveal.rubberBand(distance: 10_000, dimension: dimension) > dimension * 0.9)
  }

  /// The slope at the boundary is `c`, not 1 — `f'(d) = c / (1 + dc/D)^2`. Worth
  /// pinning down, because the curve is widely described as starting 1:1 and that
  /// misreading would send anyone tuning `c` in the wrong direction.
  @Test func rubberBandLeavesTheLimitAtTheConstantsSlope() {
    let overTheFirstPoint = EdgeDragReveal.rubberBand(distance: 1, dimension: dimension)
    #expect(abs(overTheFirstPoint - EdgeDragReveal.rubberBandConstant) < 0.02)
  }

  /// Resistance builds: each additional point of drag yields less movement.
  @Test func rubberBandResistanceIncreasesWithDistance() {
    let firstPoint = EdgeDragReveal.rubberBand(distance: 1, dimension: dimension)
    let nearHundred = EdgeDragReveal.rubberBand(distance: 100, dimension: dimension)
      - EdgeDragReveal.rubberBand(distance: 99, dimension: dimension)
    #expect(nearHundred < firstPoint)
  }

  @Test func aLooserConstantYieldsMoreMovement() {
    let stiff = EdgeDragReveal.rubberBand(distance: 40, dimension: dimension, c: 0.3)
    let loose = EdgeDragReveal.rubberBand(distance: 40, dimension: dimension, c: 0.8)
    #expect(loose > stiff)
  }

  // MARK: - elasticReveal

  private let panelWidth: CGFloat = 48

  @Test func elasticRevealMatchesTheLinearFractionBeforeTheLimit() {
    let linear = EdgeDragReveal.revealFraction(inwardTranslation: 60, pullDistance: 120)
    let elastic = EdgeDragReveal.elasticReveal(
      inwardTranslation: 60, pullDistance: 120, panelWidth: panelWidth)
    #expect(abs(elastic - linear) < 0.0001)
  }

  @Test func elasticRevealIsExactlyOneAtTheLimit() {
    let reveal = EdgeDragReveal.elasticReveal(
      inwardTranslation: 120, pullDistance: 120, panelWidth: panelWidth)
    #expect(abs(reveal - 1) < 0.0001)
  }

  @Test func elasticRevealGoesPastOneOnceOverpulled() {
    let reveal = EdgeDragReveal.elasticReveal(
      inwardTranslation: 180, pullDistance: 120, panelWidth: panelWidth)
    #expect(reveal > 1)
  }

  @Test func elasticRevealStaysBoundedUnderAHugePull() {
    let reveal = EdgeDragReveal.elasticReveal(
      inwardTranslation: 5_000, pullDistance: 120, panelWidth: panelWidth)
    #expect(reveal < 1 + EdgeDragReveal.overpullDimension / panelWidth)
  }

  @Test func elasticRevealIsMonotonicAcrossTheLimit() {
    var previous: CGFloat = -1
    for inward in stride(from: CGFloat(0), through: 600, by: 2) {
      let reveal = EdgeDragReveal.elasticReveal(
        inwardTranslation: inward, pullDistance: 120, panelWidth: panelWidth)
      #expect(reveal >= previous)
      previous = reveal
    }
  }

  @Test func elasticRevealFallsBackToTheClampedFractionForADegeneratePanel() {
    let reveal = EdgeDragReveal.elasticReveal(
      inwardTranslation: 300, pullDistance: 120, panelWidth: 0)
    #expect(reveal == 1)
  }
}
