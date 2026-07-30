//
//  FeatureTip.swift
//  Joodle
//
//  Model for a non-blocking feature-discovery tooltip — a subtle bubble that
//  points at a control to surface a newly-shipped feature to users who already
//  finished onboarding. Unlike the onboarding interactive tutorial it never
//  dims or blocks input; it disappears for good the moment the user taps the
//  target. See `FeatureTipManager` for eligibility/lifecycle.
//

import CoreGraphics
import Foundation

/// Which screen edge a scoped tip clamps to when its target is off-screen.
enum FeatureTipEdge {
    case top
    case bottom
}

/// Where, within the target frame, the bubble's beak points. `.trailing` is for
/// targets like a `Toggle` whose meaningful control (the switch) sits at the
/// trailing edge rather than the row center.
enum FeatureTipHorizontalTarget {
    case center
    case trailing
}

/// How a tip decides when it's eligible to show, and how it positions itself.
enum FeatureTipBehavior {
    /// Show only while the anchor is actually on screen; hide the moment it
    /// leaves. Used by the camera-reference tip.
    case anchorVisible

    /// Show for as long as the given scope is active (e.g. a whole screen),
    /// even before the target row is rendered. When the live anchor frame is
    /// unavailable the bubble clamps to a screen edge — following the target as
    /// it scrolls into view, and falling back to `defaultEdge` on first appear.
    case scoped(scopeID: String, defaultEdge: FeatureTipEdge)
}

/// A single discoverable feature hint.
struct FeatureTip: Identifiable {
    /// Stable identity used to persist the "seen" state. Never reuse across
    /// different features — once an id is marked seen it never shows again.
    let id: String

    /// Matches the `.featureTip(_:)` anchor attached to the target control.
    /// The manager positions the bubble against this anchor's live frame.
    let anchorID: String

    /// Groups multi-stage tips for one feature. Marking any tip seen marks
    /// every tip sharing the same `featureKey` seen — so resolving the final
    /// stage (e.g. touching a toggle) also clears the earlier guiding tips.
    let featureKey: String

    /// Localizable message shown in the bubble. `LocalizedStringResource`
    /// literals are auto-extracted into `Localizable.xcstrings`, matching the
    /// existing `TooltipBubble` convention.
    let message: LocalizedStringResource

    /// Eligibility + positioning strategy. See `FeatureTipBehavior`.
    let behavior: FeatureTipBehavior

    /// Where the beak points within the target frame.
    let horizontalTarget: FeatureTipHorizontalTarget

    /// Points to pull the bubble's attach edge *into* the target frame, so the
    /// beak points at the part of the control that actually reads as the control
    /// rather than at its outer bounds. Needed when a target's frame is padded
    /// with something visually empty (the zoom ruler's edge flare) or wrapped by
    /// another control (the translation pad, ringed by the rotation dial's band).
    /// Clamped to half the frame's height at render time.
    let targetInset: CGFloat

    /// Higher wins when several tips are eligible on the same screen — only one
    /// shows at a time.
    let priority: Int

    /// When `true`, the tip is only eligible while the user has premium access.
    /// Used for tips that surface a Pro-only feature, so free users never see a
    /// hint for something they can't use.
    let requiresPremium: Bool

    /// When `true`, finishing onboarding does NOT permanently mark this tip
    /// seen. Instead the manager suppresses it only for the remainder of the
    /// onboarding session, so it stays hidden the first time the user opens the
    /// app but surfaces from the second launch onward — until they tap its
    /// target. Use for features that aren't covered by the onboarding tutorial.
    ///
    /// When `false` (the default) the tip is suppressed for good on first
    /// onboarding completion, since the tutorial already taught the feature.
    let showsAfterOnboarding: Bool

    init(
        id: String,
        anchorID: String,
        featureKey: String,
        message: LocalizedStringResource,
        behavior: FeatureTipBehavior = .anchorVisible,
        horizontalTarget: FeatureTipHorizontalTarget = .center,
        targetInset: CGFloat = 0,
        priority: Int = 0,
        requiresPremium: Bool = false,
        showsAfterOnboarding: Bool = false
    ) {
        self.id = id
        self.anchorID = anchorID
        self.featureKey = featureKey
        self.message = message
        self.behavior = behavior
        self.horizontalTarget = horizontalTarget
        self.targetInset = targetInset
        self.priority = priority
        self.requiresPremium = requiresPremium
        self.showsAfterOnboarding = showsAfterOnboarding
    }
}
