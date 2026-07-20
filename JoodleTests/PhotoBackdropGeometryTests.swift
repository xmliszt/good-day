//
//  PhotoBackdropGeometryTests.swift
//  JoodleTests
//
//  Unit tests for the tracing-reference photo transform geometry: the
//  auto-cover zoom that keeps a rotated photo covering the square canvas, and
//  the zoom/rotation-dependent translation bound.
//

import Foundation
import SwiftUI
import Testing

@testable import Joodle

struct PhotoBackdropGeometryTests {

  // MARK: - coverZoom

  @Test func coverZoomIsOneAtCardinalAngles() {
    for degrees in [0.0, 90, 180, -90, 360] {
      let cover = PhotoBackdropGeometry.coverZoom(rotation: .degrees(degrees))
      #expect(abs(cover - 1) < 1e-9)
    }
  }

  @Test func coverZoomPeaksAtDiagonal() {
    let cover = PhotoBackdropGeometry.coverZoom(rotation: .degrees(45))
    #expect(abs(cover - sqrt(2)) < 1e-9)
  }

  @Test func coverZoomIsSymmetricInSign() {
    let positive = PhotoBackdropGeometry.coverZoom(rotation: .degrees(30))
    let negative = PhotoBackdropGeometry.coverZoom(rotation: .degrees(-30))
    #expect(abs(positive - negative) < 1e-9)
    #expect(positive > 1)
  }

  // MARK: - effectiveZoom

  @Test func effectiveZoomBoostsOnlyBelowCover() {
    // At 1x zoom a 30°-rotated photo must be boosted up to the cover zoom.
    let boosted = PhotoBackdropGeometry.effectiveZoom(zoom: 1, rotation: .degrees(30))
    let cover = PhotoBackdropGeometry.coverZoom(rotation: .degrees(30))
    #expect(abs(boosted - cover) < 1e-9)

    // Above the cover zoom the user's zoom passes through untouched.
    let unboosted = PhotoBackdropGeometry.effectiveZoom(zoom: 3, rotation: .degrees(30))
    #expect(abs(unboosted - 3) < 1e-9)
  }

  // MARK: - translationRange

  @Test func noTravelAtUnitZoomWithoutRotation() {
    let range = PhotoBackdropGeometry.translationRange(zoom: 1, rotation: .zero)
    #expect(abs(range) < 1e-9)
  }

  @Test func noTravelAtUnitZoomWhileRotated() {
    // The auto-cover boost makes the photo only just cover, so there is still
    // no room to translate at 1x zoom regardless of rotation.
    for degrees in [10.0, 30, 45, -60] {
      let range = PhotoBackdropGeometry.translationRange(zoom: 1, rotation: .degrees(degrees))
      #expect(abs(range) < 1e-9)
    }
  }

  @Test func rangeMatchesOverflowAtZeroRotation() {
    // Unrotated, the photo overflows the canvas by (zoom - 1) canvas sizes in
    // total, half of it available on each side.
    let range = PhotoBackdropGeometry.translationRange(zoom: 2, rotation: .zero, canvasSize: 342)
    #expect(abs(range - 171) < 1e-9)
  }

  @Test func rangeShrinksWithRotationAtFixedZoom() {
    let straight = PhotoBackdropGeometry.translationRange(zoom: 2, rotation: .zero)
    let rotated = PhotoBackdropGeometry.translationRange(zoom: 2, rotation: .degrees(30))
    let diagonal = PhotoBackdropGeometry.translationRange(zoom: 2, rotation: .degrees(45))
    #expect(rotated < straight)
    #expect(diagonal < rotated)
    #expect(diagonal > 0)
  }

  @Test func rangeIsNeverNegative() {
    let range = PhotoBackdropGeometry.translationRange(zoom: 0.5, rotation: .degrees(45))
    #expect(range >= 0)
  }
}
