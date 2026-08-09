//
//  FeatureTipAnchorModifier.swift
//  Joodle
//
//  Attach points for a feature-discovery tooltip:
//
//  • `.featureTip(_:)` marks the target control. It reports the target's global
//    frame to `FeatureTipManager` while on screen and (per `resolution`)
//    dismisses the tip when the target is tapped or dragged — without consuming
//    the gesture, so the real action still fires. Mirrors the
//    `TutorialFrameReader` pattern (HighlightAnchorModifier.swift).
//
//  • `.featureTipScope(_:)` marks a whole screen as the scope for a `.scoped`
//    tip, so the bubble can appear before the target row renders and clamp to a
//    screen edge. It reports visibility via a UIKit controller probe, because in
//    a `NavigationStack` SwiftUI's `.onDisappear` does NOT fire when a child is
//    pushed over the screen — but `viewWillDisappear` reliably does.
//
//  `isEnabled` gates registration for targets that stay in the view tree while
//  not actually visible (e.g. the drawing canvas tucked behind the Dynamic
//  Island when collapsed). When disabled, the anchor unregisters so the bubble
//  never points at a stale, off-screen frame.
//

import SwiftUI

/// How interacting with a target retires (marks seen) its tip.
enum FeatureTipResolution: Equatable {
    /// A tap resolves the tip. The default — matches buttons, rows and toggles.
    case tap
    /// Any touch over the target resolves whichever of its tips is currently on
    /// screen. For controls driven by a *drag* (a zoom ruler, a scrub pad, a
    /// rotary dial), where a `TapGesture` never fires. Unlike `.tap` it resolves
    /// the *showing* tip rather than a fixed one, so several tips can share the
    /// anchor and surface as a sequence — one per interaction.
    case touch
    /// Touching the target never resolves the tip — for anchors that only
    /// advance to a later stage (e.g. a row that navigates deeper before the
    /// real resolving control), or that aren't touchable at all.
    case none
}

private struct FeatureTipAnchorModifier: ViewModifier {
    /// Anchor id (matches `FeatureTip.anchorID`).
    let anchorID: String
    /// Tip id `.tap` marks seen. Resolved from the catalogue so callers only
    /// pass the anchor id at the call site. `.touch` ignores it and resolves the
    /// showing tip instead, since it supports several tips per anchor.
    let tipID: String?
    /// Only register/show the tip while this is true.
    let isEnabled: Bool
    /// Which of the target's own touches resolve (mark seen) the tip.
    let resolution: FeatureTipResolution

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        // Never let the frame-reporting background intercept
                        // taps meant for the target control.
                        .allowsHitTesting(false)
                        .onAppear {
                            registerIfEnabled(geo.frame(in: .global))
                        }
                        .onChange(of: geo.frame(in: .global)) { _, newFrame in
                            registerIfEnabled(newFrame)
                        }
                        .onChange(of: isEnabled) { _, enabled in
                            if enabled {
                                registerIfEnabled(geo.frame(in: .global))
                            } else {
                                FeatureTipManager.shared.unregisterFrame(anchorID: anchorID)
                            }
                        }
                }
            )
            .onDisappear {
                FeatureTipManager.shared.unregisterFrame(anchorID: anchorID)
            }
            // Only attach the dismiss gesture when the target actually resolves
            // the tip. A `TapGesture` here — even simultaneous — competes with a
            // Button/Toggle's own hit testing over its icon/label, so we skip it
            // entirely for advance-only anchors (`.none`).
            .if(isTapResolved) { view in
                view.simultaneousGesture(
                    TapGesture().onEnded {
                        if let tipID {
                            FeatureTipManager.shared.markSeen(tipID)
                        }
                    }
                )
            }
            // A zero-distance drag catches both taps and drags, so a
            // gesture-driven control resolves its tip the moment the user
            // actually works it. Simultaneous, so the control's own drag still
            // recognizes normally.
            .if(isTouchResolved) { view in
                view.simultaneousGesture(
                    DragGesture(minimumDistance: 0).onEnded { _ in
                        // Resolve whichever tip currently points at this anchor
                        // rather than a fixed id: one control can host a short
                        // sequence of tips (drag it, then double-tap it), and a
                        // touch should retire only the bubble on screen.
                        let manager = FeatureTipManager.shared
                        guard let active = manager.activeTip,
                            active.anchorID == anchorID
                        else { return }
                        manager.markSeen(active.id)
                    }
                )
            }
    }

    private var isTapResolved: Bool { resolution == .tap && tipID != nil }

    private var isTouchResolved: Bool { resolution == .touch }

    private func registerIfEnabled(_ frame: CGRect) {
        guard isEnabled else { return }
        FeatureTipManager.shared.registerFrame(anchorID: anchorID, frame: frame)
    }
}

// MARK: - Scope Probe

/// Reports the host screen's visibility to `FeatureTipManager` using UIKit
/// view-controller lifecycle, which — unlike SwiftUI's `.onAppear`/`.onDisappear`
/// — fires reliably on `NavigationStack` push/pop. Mirrors the
/// `NavigationGestureEnabler` representable already used in `SettingsView`.
private struct FeatureTipScopeProbe: UIViewControllerRepresentable {
    let scopeID: String

    func makeUIViewController(context: Context) -> ProbeController {
        ProbeController(scopeID: scopeID)
    }

    func updateUIViewController(_ uiViewController: ProbeController, context: Context) {
        uiViewController.scopeID = scopeID
    }

    final class ProbeController: UIViewController {
        var scopeID: String

        init(scopeID: String) {
            self.scopeID = scopeID
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            // The controller only deinits when its screen is destroyed — a
            // pushed child keeps it alive. That's the moment last-known anchor
            // frames go stale (the next visit starts with a fresh scroll
            // position), whereas on a mere push/pop they stay valid.
            let scopeID = scopeID
            Task { @MainActor in
                FeatureTipManager.shared.forgetLastFrames(inScope: scopeID)
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            FeatureTipManager.shared.activateScope(scopeID)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            FeatureTipManager.shared.deactivateScope(scopeID)
        }
    }
}

extension View {
    /// Mark this view as a feature-discovery tooltip target. For
    /// `.anchorVisible` tips the bubble appears while this anchor is on screen
    /// (and `isEnabled`) and the tip is unseen; for `.scoped` tips it positions
    /// the bubble against this anchor's live frame. Interacting with the view
    /// dismisses the tip forever, per `resolution`.
    ///
    /// Pass `isEnabled` for targets that remain in the view tree while not
    /// actually visible, so the tooltip only shows when the target truly is.
    /// Pass `resolution: .touch` for a drag-driven control (no tap to catch),
    /// or `.none` for a target that only advances to a later stage.
    func featureTip(
        _ anchorID: String,
        isEnabled: Bool = true,
        resolution: FeatureTipResolution = .tap
    ) -> some View {
        let tipID = FeatureTipDefinitions.all.first { $0.anchorID == anchorID }?.id
        return modifier(FeatureTipAnchorModifier(
            anchorID: anchorID,
            tipID: tipID,
            isEnabled: isEnabled,
            resolution: resolution
        ))
    }

    /// Mark this view as the scope for a `.scoped` feature tip. While this
    /// screen is visible the tip is eligible to show (clamped to a screen edge
    /// until its target scrolls into view).
    func featureTipScope(_ scopeID: String) -> some View {
        background(FeatureTipScopeProbe(scopeID: scopeID))
    }
}
