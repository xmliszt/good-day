//
//  MissedTapStreak.swift
//  Joodle
//
//  Counts taps that landed somewhere the user plainly expected to do something
//  and didn't — the backdrop around the expanded canvas, which used to collapse
//  it. One stray tap means nothing; three in a few seconds reads as "I'm trying
//  to close this and can't find how", which is the cue to re-surface the hint
//  pointing at the button that actually does it.
//
//  Pure value type with the clock injected, so the window logic is testable
//  without waiting on real time.
//

import Foundation

struct MissedTapStreak {
    /// Taps needed inside `windowSeconds` to read as a stuck user.
    static let threshold = 3
    /// How long the streak stays alive. Long enough to cover a deliberate
    /// tap-pause-tap-pause-tap, short enough that taps minutes apart — a user
    /// who simply brushed the backdrop now and then — never accumulate.
    static let windowSeconds: TimeInterval = 3

    /// When the current streak started. `nil` between streaks.
    private var startedAt: Date?
    private var count = 0

    /// Records a tap and reports whether it completed a qualifying streak.
    ///
    /// A tap arriving past the window doesn't fail — it *starts* a fresh streak,
    /// so someone tapping steadily but slowly still gets there. Returns `true`
    /// exactly once per streak: the counter resets on the firing tap so the next
    /// one begins counting again from scratch rather than firing on every
    /// subsequent tap.
    mutating func register(at now: Date = Date()) -> Bool {
        if let startedAt, now.timeIntervalSince(startedAt) <= Self.windowSeconds {
            count += 1
        } else {
            startedAt = now
            count = 1
        }
        guard count >= Self.threshold else { return false }
        reset()
        return true
    }

    /// Drops the in-flight streak — call when the context it was counting in
    /// goes away, so taps from an earlier session can't combine with new ones.
    mutating func reset() {
        startedAt = nil
        count = 0
    }
}
