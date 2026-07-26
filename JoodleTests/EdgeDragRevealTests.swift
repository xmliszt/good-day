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
}
