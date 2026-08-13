//
//  DoodleCarouselStaggerTests.swift
//  JoodleTests
//
//  Pins the desynced multi-doodle grid rotation: each day derives a deterministic
//  per-cell phase offset from its dateString, so multi-doodle cells cross-fade at
//  staggered instants instead of all swapping on the same global boundary. These
//  tests guard both halves of the acceptance criteria — the stagger is real (not
//  in sync) and it is deterministic (same seed → same result every run).
//

import Foundation
import Testing

@testable import Joodle

struct DoodleCarouselStaggerTests {
  /// A spread of real "yyyy-MM-dd" keys the grid would actually feed in.
  private let seeds: [String] = (1...28).map { day in
    String(format: "2025-03-%02d", day)
  }

  // MARK: - Degenerate counts

  @Test func zeroOrOneDoodleAlwaysShowsFirst() {
    for seed in seeds {
      #expect(DoodleCarouselCell.displayedIndex(count: 0, seed: seed) == 0)
      #expect(DoodleCarouselCell.displayedIndex(count: 1, seed: seed) == 0)
    }
  }

  // MARK: - Determinism (not true randomness)

  @Test func phaseOffsetIsDeterministicPerKey() {
    for seed in seeds {
      #expect(DoodleCarouselCell.phaseOffset(for: seed) == DoodleCarouselCell.phaseOffset(for: seed))
    }
  }

  @Test func displayedIndexIsDeterministicForSameInputs() {
    let instant = Date(timeIntervalSinceReferenceDate: 12_345.678)
    for seed in seeds {
      let a = DoodleCarouselCell.displayedIndex(count: 3, seed: seed, at: instant)
      let b = DoodleCarouselCell.displayedIndex(count: 3, seed: seed, at: instant)
      #expect(a == b)
      #expect((0..<3).contains(a))
    }
  }

  @Test func phaseOffsetIsNonNegative() {
    for seed in seeds {
      #expect(DoodleCarouselCell.phaseOffset(for: seed) >= 0)
    }
  }

  // MARK: - Stagger (cells do NOT swap in unison)

  @Test func distinctDaysProduceDistinctPhaseOffsets() {
    let offsets = Set(seeds.map { DoodleCarouselCell.phaseOffset(for: $0) })
    // Far from every key colliding onto one global phase — the whole point.
    #expect(offsets.count > seeds.count / 2)
  }

  @Test func multiDoodleCellsAreDesyncedAcrossTime() {
    // Sample finely across a few cycles: if the rotation were still driven purely
    // by absolute time, every seed would report the identical index at every
    // instant. With per-cell phase offsets, there must be instants where the
    // displayed indices disagree.
    let base = Date(timeIntervalSinceReferenceDate: 0)
    var sawDisagreement = false
    var tick = 0.0
    while tick < 15.0 {
      let instant = base.addingTimeInterval(tick)
      let indices = Set(seeds.map {
        DoodleCarouselCell.displayedIndex(count: 3, seed: $0, at: instant)
      })
      if indices.count > 1 { sawDisagreement = true; break }
      tick += 0.1
    }
    #expect(sawDisagreement)
  }
}
