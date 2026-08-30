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
        /// The checkmark button in the drawing canvas's top row.
        static let canvasFinish = "featureTip.canvasFinish"
        /// The eraser half of the clear/erase pill in the drawing canvas's top row.
        static let eraseTool = "featureTip.eraseTool"
        /// The horizontal doodle carousel in the day sheet's bottom half, guiding
        /// the user to swipe past the first doodle to add another one that day.
        static let multiDoodleCarousel = "featureTip.multiDoodle.carousel"
        /// The standalone auto-trace button in the reference-photo adjust overlay.
        /// Hosts a three-stage sequence — tap, change detail, relocate — resolved
        /// by `.touch`, one stage per interaction.
        static let autoTrace = "featureTip.autoTrace"
        /// The "Auto Trace" row in root Settings, guiding Pro users to configure
        /// the new feature.
        static let autoTraceSettingsRow = "featureTip.autoTrace.settingsRow"
    }

    /// Tip identifiers callers need to name. Most tips are only ever reached
    /// through their anchor, so they don't need one — these are the ones a call
    /// site addresses directly (e.g. to nudge).
    enum TipID {
        static let canvasFinish = "featureTip.canvasFinish"
        /// The root-Settings "Auto Trace" row tip, resolved when the user
        /// navigates into the settings screen rather than by a tap gesture.
        static let autoTraceSettingsRow = "featureTip.autoTrace.settingsRow"
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

    /// Shared key for the ruler-drag lesson. The live-camera ruler and the
    /// reference-photo one are the same control taught the same way, and they
    /// appear back to back (drag to zoom, shoot, then adjust the photo) — so
    /// working either one retires the lesson instead of restating it verbatim.
    private static let zoomDragFeature = "zoomDrag"

    /// Distinct keys for the three auto-trace button stages, so working one
    /// gesture retires only that stage and lets the next surface — the same
    /// per-stage-key pattern the rotation belt and translation pad use.
    private static let autoTraceTapFeature = "autoTraceTap"
    private static let autoTraceDetailFeature = "autoTraceDetail"
    private static let autoTraceRelocateFeature = "autoTraceRelocate"

    /// Points to pull a zoom-ruler tip's attach point down into the ruler. The
    /// ruler's top ~64pt is the ogee that morphs it into the screen edge, so a
    /// bubble hung off the container's top edge floats over empty space; this
    /// lands the beak on the ruler's solid body instead.
    private static let zoomRulerInset: CGFloat = 40

    /// Points to pull a translation-pad tip's attach point down into the pad.
    /// The pad is ringed by the rotation dial's 20pt band, whose indicator dot
    /// sits at top center — right where an un-inset beak would point.
    private static let translationPadInset: CGFloat = 24

    // Priorities 12…21 are the camera / reference-photo gesture tips. Every
    // reference-photo control is on screen at once, so priority alone decides
    // the order the bubbles walk the user through them: zoom (17), the pull-out
    // ruler on the other edge (16), rotate (15), level (14), move (13),
    // re-center (12). Each has its own `featureKey`, so working one control
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
            featureKey: zoomDragFeature,
            message: "Try dragging to zoom",
            targetInset: zoomRulerInset,
            priority: 21,
            showsAfterOnboarding: true
        ),
        // Reference photo, step 1 of 6: the zoom ruler on the handedness edge.
        // Shares the live camera's feature key — same control, same lesson.
        FeatureTip(
            id: "featureTip.photoZoom.ruler",
            anchorID: AnchorID.photoZoomRuler,
            featureKey: zoomDragFeature,
            message: "Try dragging to zoom",
            targetInset: zoomRulerInset,
            priority: 17,
            showsAfterOnboarding: true
        ),
        // Step 2: the second ruler hiding behind the opposite edge. Two wordings
        // for one feature — the anchored one names the edge to pull from.
        FeatureTip(
            id: "featureTip.photoEdgeZoom.leading",
            anchorID: AnchorID.photoEdgeZoomLeading,
            featureKey: photoEdgeZoomFeature,
            message: "Drag out from the left edge",
            targetInset: zoomRulerInset,
            priority: 16,
            showsAfterOnboarding: true
        ),
        FeatureTip(
            id: "featureTip.photoEdgeZoom.trailing",
            anchorID: AnchorID.photoEdgeZoomTrailing,
            featureKey: photoEdgeZoomFeature,
            message: "Drag out from the right edge",
            targetInset: zoomRulerInset,
            priority: 16,
            showsAfterOnboarding: true
        ),
        // Steps 3 and 4: the rotation belt — turning it, then levelling it.
        FeatureTip(
            id: "featureTip.photoRotation.drag",
            anchorID: AnchorID.photoRotationBelt,
            featureKey: "photoRotationDrag",
            message: "Drag the belt to rotate",
            priority: 15,
            showsAfterOnboarding: true
        ),
        FeatureTip(
            id: "featureTip.photoRotation.reset",
            anchorID: AnchorID.photoRotationBelt,
            featureKey: "photoRotationReset",
            message: "Double-tap to reset rotation",
            priority: 14,
            showsAfterOnboarding: true
        ),
        // How to leave the expanded canvas. Tapping the surrounding backdrop used
        // to collapse it, so a user who reaches for that now gets nothing and
        // reads it as a bug — the checkmark is the only way out. Priority 10 puts
        // it directly under the gesture band: while the reference-photo controls
        // are up the user is mid-adjustment, not hunting for the exit, so that
        // sequence runs first; everywhere else this outranks every other tip.
        //
        // `nudgeable`, so it comes back for a few seconds when someone taps the
        // backdrop repeatedly — the exact gesture that used to close the canvas.
        // That's the one hint worth repeating: a user who can't find the way out
        // is stuck, whereas every other tip is only ever a suggestion.
        FeatureTip(
            id: TipID.canvasFinish,
            anchorID: AnchorID.canvasFinish,
            featureKey: "canvasFinish",
            message: "Tap here to finish your doodle",
            priority: 10,
            nudgeable: true,
            showsAfterOnboarding: true
        ),
        // Erase-tool discovery: the clear/erase pill only mounts once the canvas
        // has a stroke, so the tip surfaces exactly when the user has something to
        // erase. Priority 11 puts it above the finish tip (10) so it takes over
        // the moment a stroke exists, but below the reference-photo gesture band —
        // which the two never actually contend for, since camera mode hides the
        // pill. Tapping the eraser both activates erase mode and retires the tip.
        FeatureTip(
            id: "featureTip.eraseTool",
            anchorID: AnchorID.eraseTool,
            featureKey: "eraseTool",
            message: "Use erase to erase a stroke",
            priority: 11,
            showsAfterOnboarding: true
        ),
        // Multiple-doodles-per-day discovery: once a day has its first doodle and
        // can still hold more, point at the carousel's trailing edge so the user
        // learns to swipe past it to draw another doodle for the same day. Gated
        // at the call site (`isEnabled`) to the "first doodle drawn + room left"
        // state, and resolved by `.touch` the moment they swipe the carousel.
        FeatureTip(
            id: "featureTip.multiDoodle.carousel",
            anchorID: AnchorID.multiDoodleCarousel,
            featureKey: "multiDoodle",
            message: "Swipe to add more doodles",
            horizontalTarget: .trailing,
            priority: 2,
            showsAfterOnboarding: true
        ),
        // Steps 5 and 6: the translation pad — scrubbing it, then re-centering.
        FeatureTip(
            id: "featureTip.photoTranslation.drag",
            anchorID: AnchorID.photoTranslationPad,
            featureKey: "photoTranslationDrag",
            message: "Drag the pad to move the photo",
            targetInset: translationPadInset,
            priority: 13,
            showsAfterOnboarding: true
        ),
        FeatureTip(
            id: "featureTip.photoTranslation.recenter",
            anchorID: AnchorID.photoTranslationPad,
            featureKey: "photoTranslationRecenter",
            message: "Double-tap to re-center the photo",
            targetInset: translationPadInset,
            priority: 12,
            showsAfterOnboarding: true
        ),
        // Auto-trace button: a three-stage sequence off one anchor, resolved by
        // `.touch` so each interaction retires the showing stage and surfaces the
        // next (tap → change detail → relocate). Pro only — the button exists
        // only for Pro users who turned auto-trace on. Priorities 24…22 seat the
        // sequence above the reference-photo gesture band (12…17), so the headline
        // button is taught before the manual adjust controls that share the
        // screen. The bubble sits above the corner-docked button and, once the
        // overlay clamps it on-screen, aligns to the button's side.
        FeatureTip(
            id: "featureTip.autoTrace.tap",
            anchorID: AnchorID.autoTrace,
            featureKey: autoTraceTapFeature,
            message: "Tap to auto trace",
            priority: 24,
            requiresPremium: true,
            showsAfterOnboarding: true
        ),
        FeatureTip(
            id: "featureTip.autoTrace.detail",
            anchorID: AnchorID.autoTrace,
            featureKey: autoTraceDetailFeature,
            message: "Long-press or swipe out to change detailness",
            priority: 23,
            requiresPremium: true,
            showsAfterOnboarding: true
        ),
        FeatureTip(
            id: "featureTip.autoTrace.relocate",
            anchorID: AnchorID.autoTrace,
            featureKey: autoTraceRelocateFeature,
            message: "Drag horizontally to opposite side",
            priority: 22,
            requiresPremium: true,
            showsAfterOnboarding: true
        ),
        // Root Settings: point at the "Auto Trace" row so Pro users find where to
        // configure (and enable) the new feature — the discovery path for those
        // whose toggle is still off. Pro only, matching the Wiggly/Rainbow row
        // tips: free users see the Pro-badged row but aren't sent to a paywall by
        // a tip. Priority 7 seats it above those so the newest feature leads.
        FeatureTip(
            id: "featureTip.autoTrace.settingsRow",
            anchorID: AnchorID.autoTraceSettingsRow,
            featureKey: "autoTraceSettings",
            message: "Configure the new auto-trace feature",
            behavior: .scoped(scopeID: ScopeID.settings, defaultEdge: .bottom),
            priority: 7,
            requiresPremium: true,
            showsAfterOnboarding: true
        )
    ]
}
