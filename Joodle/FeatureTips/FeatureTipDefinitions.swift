//
//  FeatureTipDefinitions.swift
//  Joodle
//
//  Static catalogue of every feature-discovery tooltip, mirroring how
//  `ChangelogData` holds bundled changelog entries. Add one entry per feature
//  you want existing (already-onboarded) users to discover, then attach the
//  matching `.featureTip(_:)` modifier to the target control.
//

import Foundation

enum FeatureTipDefinitions {
    /// Stable anchor / tip identifiers. Kept in one place so the catalogue and
    /// the `.featureTip(_:)` call sites can't drift apart.
    enum AnchorID {
        static let cameraReference = "featureTip.cameraReference"
        /// The "Customization" row in Settings.
        static let wigglyCustomizationRow = "featureTip.wigglyStrokes.customizationRow"
        /// The "Wiggly Strokes" toggle on the Customization screen.
        static let wigglyToggle = "featureTip.wigglyStrokes.toggle"
        /// The "Customization" row in Settings, guiding toward the rainbow theme.
        static let rainbowCustomizationRow = "featureTip.rainbow.customizationRow"
        /// The rainbow swatch in the Theme Color grid on the Customization screen.
        static let rainbowSwatch = "featureTip.rainbow.swatch"
        /// The Instagram quick-share button in `ShareCardSelectorView`.
        static let instagramShare = "featureTip.instagramShare"
        /// The live-camera zoom ruler on the handedness edge.
        static let cameraZoomRuler = "featureTip.cameraZoom.ruler"
        /// The reference-photo zoom ruler on the handedness edge.
        static let photoZoomRuler = "featureTip.photoZoom.ruler"
        /// The screen-edge grab band that pulls out a second zoom ruler, on the
        /// edge *opposite* the handedness one. One anchor per edge, because the
        /// bubble's copy names the edge the user has to drag from.
        static let photoEdgeZoomLeading = "featureTip.photoEdgeZoom.leading"
        static let photoEdgeZoomTrailing = "featureTip.photoEdgeZoom.trailing"
        /// The rotation belt wrapping the translation pad. Hosts two tips — turn
        /// it, then double-tap to level — off this one anchor.
        static let photoRotationBelt = "featureTip.photoRotation.belt"
        /// The 2-axis translation pad. Hosts two tips (scrub, then double-tap to
        /// re-center) off one anchor.
        static let photoTranslationPad = "featureTip.photoTranslation.pad"
    }

    /// Stable scope identifiers for `.scoped` tips. A scope is a whole screen
    /// whose visibility decides whether the tip is eligible (see
    /// `.featureTipScope(_:)`).
    enum ScopeID {
        static let settings = "featureTipScope.settings"
        static let customization = "featureTipScope.customization"
    }

    /// Shared key linking the two-stage Wiggly Strokes discovery so touching
    /// the toggle resolves both stages at once.
    private static let wigglyStrokesFeature = "wigglyStrokes"

    /// Shared key linking the two-stage rainbow theme discovery so selecting the
    /// rainbow swatch resolves both stages at once.
    private static let rainbowFeature = "rainbow"

    /// Shared key for the pull-out zoom ruler, whose bubble comes in a
    /// left-edge and a right-edge wording — only one of the two is ever
    /// anchored (the edge opposite the user's handedness), and resolving it
    /// retires both wordings.
    private static let photoEdgeZoomFeature = "photoEdgeZoom"

    // Priorities 10…20 are the camera / reference-photo gesture tips. Every
    // reference-photo control is on screen at once, so priority alone decides
    // the order the bubbles walk the user through them: zoom (16), the pull-out
    // ruler on the other edge (15), rotate (14), level (13), move (12),
    // re-center (11). Each has its own `featureKey`, so working one control
    // retires only that step and lets the next surface. The band sits above
    // every other tip so the sequence never interleaves with them.

    /// All defined tips. Order is irrelevant — `FeatureTipManager` selects by
    /// `priority`.
    static let all: [FeatureTip] = [
        FeatureTip(
            id: "featureTip.cameraReference",
            anchorID: AnchorID.cameraReference,
            featureKey: "cameraReference",
            message: "Take a photo as reference",
            priority: 0
        ),
        // Stage 1: guide the user from Settings into the Customization screen.
        // Pro only — don't send free users toward a toggle they can't enable.
        FeatureTip(
            id: "featureTip.wigglyStrokes.settingsEntry",
            anchorID: AnchorID.wigglyCustomizationRow,
            featureKey: wigglyStrokesFeature,
            message: "Make your doodles wiggle",
            behavior: .scoped(scopeID: ScopeID.settings, defaultEdge: .bottom),
            priority: 5,
            requiresPremium: true,
            showsAfterOnboarding: true
        ),
        // Stage 2: point at the toggle switch on the Customization screen.
        FeatureTip(
            id: "featureTip.wigglyStrokes.toggleEntry",
            anchorID: AnchorID.wigglyToggle,
            featureKey: wigglyStrokesFeature,
            message: "Make your doodles wiggle",
            behavior: .scoped(scopeID: ScopeID.customization, defaultEdge: .bottom),
            horizontalTarget: .trailing,
            priority: 6,
            requiresPremium: true,
            showsAfterOnboarding: true
        ),
        // Rainbow theme discovery (Pro only, lower priority than Wiggly Strokes
        // so it surfaces only once Wiggly has been resolved).
        // Stage 1: guide the user from Settings into the Customization screen.
        FeatureTip(
            id: "featureTip.rainbow.settingsEntry",
            anchorID: AnchorID.rainbowCustomizationRow,
            featureKey: rainbowFeature,
            message: "Try one color a month",
            behavior: .scoped(scopeID: ScopeID.settings, defaultEdge: .bottom),
            priority: 3,
            requiresPremium: true,
            showsAfterOnboarding: true
        ),
        // Stage 2: point at the rainbow swatch in the Theme Color grid.
        FeatureTip(
            id: "featureTip.rainbow.swatchEntry",
            anchorID: AnchorID.rainbowSwatch,
            featureKey: rainbowFeature,
            message: "Try one color a month",
            behavior: .scoped(scopeID: ScopeID.customization, defaultEdge: .bottom),
            priority: 4,
            requiresPremium: true,
            showsAfterOnboarding: true
        ),
        // Surface the Instagram quick-share path. The bubble points at the
        // Instagram share button, which is always on screen while the share
        // sheet is open (when Instagram is installed).
        FeatureTip(
            id: "featureTip.instagramShare",
            anchorID: AnchorID.instagramShare,
            featureKey: "instagramShare",
            message: "Share your doodle to Instagram",
            priority: 1,
            showsAfterOnboarding: true
        ),
        // Live camera: the fine-zoom ruler on the handedness edge. Its own mode,
        // so it never competes with the reference-photo sequence below.
        FeatureTip(
            id: "featureTip.cameraZoom.ruler",
            anchorID: AnchorID.cameraZoomRuler,
            featureKey: "cameraZoomDrag",
            message: "Try dragging to zoom",
            priority: 20,
            showsAfterOnboarding: true
        ),
        // Reference photo, step 1 of 6: the zoom ruler on the handedness edge.
        FeatureTip(
            id: "featureTip.photoZoom.ruler",
            anchorID: AnchorID.photoZoomRuler,
            featureKey: "photoZoomDrag",
            message: "Try dragging to zoom",
            priority: 16,
            showsAfterOnboarding: true
        ),
        // Step 2: the second ruler hiding behind the opposite edge. Two wordings
        // for one feature — the anchored one names the edge to pull from.
        FeatureTip(
            id: "featureTip.photoEdgeZoom.leading",
            anchorID: AnchorID.photoEdgeZoomLeading,
            featureKey: photoEdgeZoomFeature,
            message: "Drag out from the left edge",
            priority: 15,
            showsAfterOnboarding: true
        ),
        FeatureTip(
            id: "featureTip.photoEdgeZoom.trailing",
            anchorID: AnchorID.photoEdgeZoomTrailing,
            featureKey: photoEdgeZoomFeature,
            message: "Drag out from the right edge",
            priority: 15,
            showsAfterOnboarding: true
        ),
        // Steps 3 and 4: the rotation belt — turning it, then levelling it.
        FeatureTip(
            id: "featureTip.photoRotation.drag",
            anchorID: AnchorID.photoRotationBelt,
            featureKey: "photoRotationDrag",
            message: "Drag the belt to rotate",
            priority: 14,
            showsAfterOnboarding: true
        ),
        FeatureTip(
            id: "featureTip.photoRotation.reset",
            anchorID: AnchorID.photoRotationBelt,
            featureKey: "photoRotationReset",
            message: "Double-tap to reset rotation",
            priority: 13,
            showsAfterOnboarding: true
        ),
        // Steps 5 and 6: the translation pad — scrubbing it, then re-centering.
        FeatureTip(
            id: "featureTip.photoTranslation.drag",
            anchorID: AnchorID.photoTranslationPad,
            featureKey: "photoTranslationDrag",
            message: "Drag the pad to move the photo",
            priority: 12,
            showsAfterOnboarding: true
        ),
        FeatureTip(
            id: "featureTip.photoTranslation.recenter",
            anchorID: AnchorID.photoTranslationPad,
            featureKey: "photoTranslationRecenter",
            message: "Double-tap to re-center the photo",
            priority: 11,
            showsAfterOnboarding: true
        )
    ]
}
