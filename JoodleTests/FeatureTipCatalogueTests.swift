//
//  FeatureTipCatalogueTests.swift
//  JoodleTests
//
//  Invariants the camera / reference-photo gesture tips rely on. Every one of
//  those controls is on screen at the same time, so ordering and grouping in the
//  catalogue — not view code — is what makes the bubbles walk the user through
//  them one at a time.
//

import Foundation
import Testing

@testable import Joodle

struct FeatureTipCatalogueTests {

  /// The reference-photo controls, in the order the tips must surface.
  private let photoSequence = [
    "featureTip.photoZoom.ruler",
    "featureTip.photoEdgeZoom.leading",
    "featureTip.photoEdgeZoom.trailing",
    "featureTip.photoRotation.drag",
    "featureTip.photoRotation.reset",
    "featureTip.photoTranslation.drag",
    "featureTip.photoTranslation.recenter",
  ]

  private func tip(_ id: String) -> FeatureTip? {
    FeatureTipDefinitions.all.first { $0.id == id }
  }

  // MARK: - Identity

  @Test func tipIDsAreUnique() {
    let ids = FeatureTipDefinitions.all.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test func everyGestureTipIsDefined() {
    for id in photoSequence + ["featureTip.cameraZoom.ruler"] {
      #expect(tip(id) != nil, "missing tip \(id)")
    }
  }

  // MARK: - Ordering

  /// Zoom → pull-out ruler → rotate → level → move → re-center. Both pull-out
  /// wordings sit at the same rank because only one of them is ever anchored.
  @Test func photoTipsSurfaceInSpecifiedOrder() {
    let priorities = photoSequence.compactMap { tip($0)?.priority }
    #expect(priorities == [16, 15, 15, 14, 13, 12, 11])
  }

  @Test func gestureTipsOutrankEveryOtherTip() {
    let gestureIDs = Set(photoSequence + ["featureTip.cameraZoom.ruler"])
    let gesture = FeatureTipDefinitions.all.filter { gestureIDs.contains($0.id) }
    let others = FeatureTipDefinitions.all.filter { !gestureIDs.contains($0.id) }
    let lowestGesture = gesture.map(\.priority).min()
    let highestOther = others.map(\.priority).max()
    #expect(lowestGesture != nil)
    #expect(highestOther != nil)
    if let lowestGesture, let highestOther {
      #expect(lowestGesture > highestOther)
    }
  }

  /// The live-camera ruler is its own mode, and must not be pre-empted by a
  /// reference-photo tip should both ever be eligible at once.
  @Test func cameraZoomTipOutranksPhotoTips() {
    let camera = tip("featureTip.cameraZoom.ruler")?.priority
    let photoMax = photoSequence.compactMap { tip($0)?.priority }.max()
    #expect(camera != nil)
    #expect(photoMax != nil)
    if let camera, let photoMax {
      #expect(camera > photoMax)
    }
  }

  // MARK: - Grouping

  /// `markSeen` clears every tip sharing a `featureKey`, so a step that shared
  /// one with the next would retire it before it ever showed.
  @Test func eachPhotoStepRetiresIndependently() {
    let steps = photoSequence
      .filter { !$0.hasPrefix("featureTip.photoEdgeZoom") }
      .compactMap { tip($0)?.featureKey }
    #expect(Set(steps).count == steps.count)
  }

  /// The two pull-out wordings are one feature: whichever edge the user drags
  /// from, the other wording must never resurface.
  @Test func edgeZoomWordingsShareOneFeatureKey() {
    let leading = tip("featureTip.photoEdgeZoom.leading")
    let trailing = tip("featureTip.photoEdgeZoom.trailing")
    #expect(leading?.featureKey == trailing?.featureKey)
    #expect(leading?.anchorID != trailing?.anchorID)
  }

  /// A control hosting two tips reports one anchor frame for both, so the pair
  /// must be separated by priority alone — never tied.
  @Test func tipsSharingAnAnchorAreStrictlyOrdered() {
    let grouped = Dictionary(grouping: FeatureTipDefinitions.all, by: \.anchorID)
    for (anchorID, tips) in grouped where tips.count > 1 {
      let priorities = tips.map(\.priority)
      #expect(Set(priorities).count == priorities.count, "tied priorities on \(anchorID)")
    }
  }

  @Test func rotationBeltAndTranslationPadEachHostTwoTips() {
    let belt = FeatureTipDefinitions.all.filter {
      $0.anchorID == FeatureTipDefinitions.AnchorID.photoRotationBelt
    }
    let pad = FeatureTipDefinitions.all.filter {
      $0.anchorID == FeatureTipDefinitions.AnchorID.photoTranslationPad
    }
    #expect(belt.count == 2)
    #expect(pad.count == 2)
    // Rotation is taught before translation.
    #expect(belt.map(\.priority).min() ?? 0 > pad.map(\.priority).max() ?? 0)
  }

  // MARK: - Eligibility

  /// The onboarding tutorial never teaches these gestures, so they must survive
  /// the blanket suppression applied when onboarding completes.
  @Test func gestureTipsSurfaceAfterOnboarding() {
    for id in photoSequence + ["featureTip.cameraZoom.ruler"] {
      #expect(tip(id)?.showsAfterOnboarding == true, "\(id) would be suppressed for good")
    }
  }

  /// Camera capture is not gated behind Joodle Pro, so neither are its tips.
  @Test func gestureTipsAreNotPremiumGated() {
    for id in photoSequence + ["featureTip.cameraZoom.ruler"] {
      #expect(tip(id)?.requiresPremium == false)
    }
  }

  /// These bubbles follow live controls rather than a whole screen.
  @Test func gestureTipsAreAnchorVisible() {
    for id in photoSequence + ["featureTip.cameraZoom.ruler"] {
      guard let behavior = tip(id)?.behavior else {
        #expect(Bool(false), "missing tip \(id)")
        continue
      }
      if case .anchorVisible = behavior {} else {
        #expect(Bool(false), "\(id) should be .anchorVisible")
      }
    }
  }
}
