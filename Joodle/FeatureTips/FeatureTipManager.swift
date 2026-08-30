//
//  FeatureTipManager.swift
//  Joodle
//
//  Drives non-blocking feature-discovery tooltips. Holds the persisted "seen"
//  set, the live frames of on-screen anchors, the active screen scopes, and the
//  single currently-active tip. Follows the `ChangelogManager.shared` singleton
//  convention.
//
//  Eligibility model (no version comparison needed):
//    • `.anchorVisible` tips show while their anchor is on screen AND unseen.
//    • `.scoped` tips show while their scope (a whole screen) is active AND
//      unseen — even before the target row renders. When the live anchor frame
//      is unavailable the bubble clamps to a screen edge (see `fallbackEdge`).
//    • Tapping a tip's target marks its whole feature seen (`markSeen` clears
//      every tip sharing the same `featureKey`).
//    • New installs are suppressed: `markAllCurrentTipsAsSeen()` is called once
//      on first onboarding completion, so fresh users — who already learned the
//      features via the onboarding tutorial — don't get tooltips. Existing,
//      already-onboarded users have these tips unseen, so newly-added tips
//      surface for them on update.
//    • Tips flagged `showsAfterOnboarding` are exempt from that permanent
//      suppression: on onboarding completion they're suppressed only for the
//      current session (in-memory, see `sessionSuppressedIDs`), so they stay
//      hidden the first time the user opens the app but surface from the second
//      launch onward — for features the onboarding tutorial doesn't cover.
//    • A tip flagged `nudgeable` can be put back on screen for a few seconds by
//      `nudge(_:)` even once seen, for a user who is visibly stuck (see
//      `registerMissedTap(nudging:)` and `MissedTapStreak`).
//

import SwiftUI

@MainActor
final class FeatureTipManager: ObservableObject {
    static let shared = FeatureTipManager()

    // MARK: - Published State

    /// The tip currently eligible to display, or `nil` when none.
    @Published private(set) var activeTip: FeatureTip?

    /// Global-space frame of the active tip's anchor when it is on screen, used
    /// to position the bubble. `nil` for a scoped tip whose target is currently
    /// off-screen — the overlay then clamps to `fallbackEdge`.
    @Published private(set) var activeFrame: CGRect?

    /// Edge a scoped tip clamps to when `activeFrame` is `nil`.
    @Published private(set) var fallbackEdge: FeatureTipEdge = .bottom

    // MARK: - Private State

    private let defaults = UserDefaults.standard
    private let seenIDsKey = "featureTip_seenIDs"

    /// anchorID → latest global frame, only for anchors currently on screen.
    private var frames: [String: CGRect] = [:]

    /// anchorID → last known global frame, retained after the anchor leaves the
    /// screen so we can tell which edge it scrolled off toward.
    private var lastFrames: [String: CGRect] = [:]

    /// Screen scopes currently active (see `.featureTipScope(_:)`).
    private var activeScopes: Set<String> = []

    /// Anchor whose tips are hidden for the duration of an in-progress gesture,
    /// so the bubble never sits over controls the gesture itself reveals (e.g.
    /// the auto-trace fan). The stage showing when the interaction began is held
    /// in `suspendedTipID` and resolved when it ends. See `beginInteraction`.
    private var suspendedAnchorID: String?
    private var suspendedTipID: String?

    /// Full-screen height reported by the overlay, used to derive the fallback
    /// edge from a last-known frame.
    private var viewportHeight: CGFloat = 0

    private var seenIDs: Set<String>

    /// Tips suppressed for this app session only — never persisted. Populated
    /// by `markAllCurrentTipsAsSeen()` for `showsAfterOnboarding` tips so they
    /// stay hidden for the rest of the onboarding session, then surface on the
    /// next launch (a fresh manager starts this set empty). These tips are NOT
    /// in `seenIDs`, so they keep showing across launches until tapped.
    private var sessionSuppressedIDs: Set<String> = []

    /// Whether any defined tip is still unseen. When `false` the manager can
    /// never surface a tip, so the per-scroll-frame registration hot path
    /// short-circuits to a no-op — the common case for already-resolved users
    /// and brand-new installs (which are suppressed up front). Recomputed only
    /// when the seen set changes, never on the hot path.
    private var hasUnseenTips: Bool

    /// Anchors belonging to a `nudgeable` tip. They must keep reporting their
    /// frame even once every tip is seen — otherwise the `hasUnseenTips`
    /// short-circuit means a nudge has no frame to point at, and none is coming
    /// (the anchor's `onAppear` already fired and was dropped). Computed once:
    /// the catalogue is static.
    private let nudgeableAnchorIDs: Set<String>

    /// Tip currently forced on screen by `nudge(_:)`, exempt from the seen and
    /// session-suppression checks. `nil` when no nudge is in flight.
    private var nudgedTipID: String?

    /// Bumped on every nudge so an expiry scheduled by an earlier one can't
    /// retire a nudge that has since superseded it.
    private var nudgeGeneration = 0

    /// Backdrop-tap streak feeding `registerMissedTap(nudging:)`.
    private var missedTaps = MissedTapStreak()

    private var nudgedTip: FeatureTip? {
        nudgedTipID.flatMap { id in FeatureTipDefinitions.all.first { $0.id == id } }
    }

    private init() {
        let stored = defaults.stringArray(forKey: seenIDsKey) ?? []
        let seen = Set(stored)
        seenIDs = seen
        hasUnseenTips = FeatureTipDefinitions.all.contains { !seen.contains($0.id) }
        nudgeableAnchorIDs = Set(FeatureTipDefinitions.all.filter(\.nudgeable).map(\.anchorID))
    }

    // MARK: - Anchor Registration

    /// Called by `.featureTip(_:)` when the target appears or moves.
    func registerFrame(anchorID: String, frame: CGRect) {
        // Hot path (fires every frame while scrolling): bail before touching any
        // state once there's nothing left that could ever show. A nudgeable
        // anchor is exempt — it can be asked to show again after being seen, so
        // its frame has to stay current.
        guard hasUnseenTips || nudgeableAnchorIDs.contains(anchorID) else { return }
        lastFrames[anchorID] = frame
        guard frames[anchorID] != frame else { return }
        frames[anchorID] = frame
        recompute()
    }

    /// Called by `.featureTip(_:)` when the target leaves the screen.
    func unregisterFrame(anchorID: String) {
        guard frames[anchorID] != nil else { return }
        frames.removeValue(forKey: anchorID)
        if nudgeableAnchorIDs.contains(anchorID) {
            // The target is gone — the canvas collapsed — so the question the
            // nudge was answering has been answered one way or another. Drop it,
            // and don't let a half-built tap streak carry into the next session.
            missedTaps.reset()
            if nudgedTip?.anchorID == anchorID { nudgedTipID = nil }
        }
        recompute()
    }

    // MARK: - Scope Registration

    /// Called by `.featureTipScope(_:)` when its host screen becomes visible.
    func activateScope(_ scopeID: String) {
        guard hasUnseenTips else { return }
        guard !activeScopes.contains(scopeID) else { return }
        activeScopes.insert(scopeID)
        recompute()
    }

    /// Called by `.featureTipScope(_:)` when its host screen is covered/popped.
    ///
    /// Deliberately keeps `lastFrames`: when a child screen is pushed over this
    /// scope, the scroll position underneath is preserved, so the last-known
    /// frames stay valid for deriving the fallback edge after popping back.
    /// Forgetting them belongs to `forgetLastFrames(inScope:)`, which fires only
    /// when the host screen is actually destroyed.
    func deactivateScope(_ scopeID: String) {
        guard activeScopes.contains(scopeID) else { return }
        activeScopes.remove(scopeID)
        recompute()
    }

    /// Called when a scope's host screen is destroyed (left for good, not just
    /// covered by a pushed child). Forgets where the scope's targets last sat,
    /// so the next visit — whose scroll position starts fresh — derives the
    /// fallback edge from `defaultEdge` instead of a stale frame.
    func forgetLastFrames(inScope scopeID: String) {
        for tip in FeatureTipDefinitions.all {
            if case .scoped(scopeID, _) = tip.behavior {
                lastFrames.removeValue(forKey: tip.anchorID)
            }
        }
    }

    /// Reported by the overlay so the fallback edge can be derived from a
    /// last-known frame relative to the screen middle.
    ///
    /// Deliberately NOT gated on `hasUnseenTips`: the overlay reports this once
    /// when it first lays out (app launch), which may be before any tip becomes
    /// unseen (e.g. a debug reset, or simply ordering). Skipping it would leave
    /// `viewportHeight == 0`, making `edge(for:)` fall back to `.bottom` and the
    /// tip wrongly reappear at the bottom after scrolling its target off the top.
    /// It's not a hot path — it only fires on appear / rotation.
    func setViewportHeight(_ height: CGFloat) {
        guard viewportHeight != height else { return }
        viewportHeight = height
        recompute()
    }

    // MARK: - Dismissal

    /// Permanently dismiss the feature owning the given tip id (its target was
    /// tapped). Clears every tip sharing the same `featureKey`, so resolving a
    /// later stage also retires the earlier guiding tips.
    func markSeen(_ id: String) {
        guard let tip = FeatureTipDefinitions.all.first(where: { $0.id == id }) else { return }
        // Before the newly-seen guard below: a nudged tip is usually one that's
        // already seen, so `newlySeen` is empty and an early return would leave
        // the bubble up for the rest of the nudge — pointing at a button the user
        // just pressed.
        if nudgedTipID == id { clearNudge() }
        let groupIDs = FeatureTipDefinitions.all
            .filter { $0.featureKey == tip.featureKey }
            .map(\.id)
        let newlySeen = Set(groupIDs).subtracting(seenIDs)
        guard !newlySeen.isEmpty else { return }
        seenIDs.formUnion(newlySeen)
        refreshHasUnseenTips()
        persistSeenIDs()
        recompute()
    }

    /// Dismiss the tip currently pointing at the given anchor, if any. For
    /// gestures that resolve a tip without the anchor view itself seeing the
    /// touch — e.g. the screen-edge pull, whose grab band is a separate,
    /// screen-tall recognizer. Ignores anchors whose tip isn't on screen, so a
    /// hint the user never saw is never silently retired.
    func markSeen(anchorID: String) {
        guard let active = activeTip, active.anchorID == anchorID else { return }
        markSeen(active.id)
    }

    // MARK: - Interaction Suspension

    /// Hide whichever tip is currently pointing at `anchorID` for the duration of
    /// a gesture, remembering it so `endInteraction` can resolve it on release.
    /// For controls that reveal more UI mid-gesture (the auto-trace fan blooms
    /// buttons right where the bubble sits) — keeping the bubble up would obscure
    /// them, and advancing to the next stage immediately would just swap in
    /// another bubble over the same spot.
    func beginInteraction(anchorID: String) {
        guard let active = activeTip, active.anchorID == anchorID else { return }
        suspendedAnchorID = anchorID
        suspendedTipID = active.id
        recompute()
    }

    /// End the gesture started by `beginInteraction`: resolve the stage that was
    /// showing when it began (so the next surfaces only now, with the control
    /// idle again). A no-op if no interaction is suspended for this anchor.
    func endInteraction(anchorID: String) {
        guard suspendedAnchorID == anchorID else { return }
        let tipID = suspendedTipID
        suspendedAnchorID = nil
        suspendedTipID = nil
        if let tipID {
            markSeen(tipID)
        } else {
            recompute()
        }
    }

    // MARK: - Nudges

    /// How long a nudged tip stays on screen. Long enough to read and act on,
    /// short enough that it doesn't linger over the canvas afterwards.
    private static let nudgeDurationSeconds: TimeInterval = 6

    /// Records a tap that landed somewhere the user evidently expected to do
    /// something and didn't, and nudges `tipID` once enough of them land in
    /// quick succession. See `MissedTapStreak` for the threshold.
    func registerMissedTap(nudging tipID: String) {
        guard missedTaps.register() else { return }
        nudge(tipID)
    }

    /// Put a `nudgeable` tip back on screen for a few seconds even if it has
    /// already been seen — for a user who is visibly hunting for the control it
    /// points at. Ignored for a tip that isn't flagged `nudgeable`, so a nudge
    /// can never resurrect an arbitrary retired hint.
    ///
    /// Deliberately does NOT clear the tip's seen state: this is a one-off
    /// reminder, not an un-retirement, so it goes away on its own whether or not
    /// the user takes the hint.
    private func nudge(_ tipID: String) {
        guard let tip = FeatureTipDefinitions.all.first(where: { $0.id == tipID }),
            tip.nudgeable
        else { return }
        nudgedTipID = tipID
        nudgeGeneration += 1
        let generation = nudgeGeneration
        recompute()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.nudgeDurationSeconds))
            guard generation == nudgeGeneration else { return }
            clearNudge()
        }
    }

    /// Drop the active nudge and any half-built tap streak — on expiry, and when
    /// the user takes the hint. The target simply going away is handled by
    /// `unregisterFrame(anchorID:)` instead.
    private func clearNudge() {
        missedTaps.reset()
        guard nudgedTipID != nil else { return }
        nudgedTipID = nil
        recompute()
    }

    /// Suppress every currently-defined tip. Call once on the user's first
    /// onboarding completion so new installs don't see tooltips for features
    /// the onboarding tutorial already covered.
    ///
    /// Tips flagged `showsAfterOnboarding` are suppressed only for this session
    /// (in-memory) rather than permanently, so they stay hidden the first time
    /// the app is opened but surface on the next launch.
    func markAllCurrentTipsAsSeen() {
        let permanentIDs = FeatureTipDefinitions.all
            .filter { !$0.showsAfterOnboarding }
            .map(\.id)
        let deferredIDs = FeatureTipDefinitions.all
            .filter(\.showsAfterOnboarding)
            .map(\.id)
        seenIDs.formUnion(permanentIDs)
        sessionSuppressedIDs.formUnion(deferredIDs)
        refreshHasUnseenTips()
        persistSeenIDs()
        recompute()
    }

    // MARK: - Selection

    /// Whether a tip is currently eligible to display, per its behavior.
    private func isEligible(_ tip: FeatureTip) -> Bool {
        // Hidden while its anchor is mid-gesture (see `beginInteraction`).
        if tip.anchorID == suspendedAnchorID { return false }
        // An active nudge overrides both dismissal paths — that's the whole point
        // of it — but never the behavior check below: with no anchor on screen
        // there's nothing to point at.
        if tip.id != nudgedTipID {
            guard !seenIDs.contains(tip.id) else { return false }
            guard !sessionSuppressedIDs.contains(tip.id) else { return false }
        }
        if tip.requiresPremium, !SubscriptionManager.shared.hasPremiumAccess { return false }
        switch tip.behavior {
        case .anchorVisible:
            return frames[tip.anchorID] != nil
        case .scoped(let scopeID, _):
            return activeScopes.contains(scopeID)
        }
    }

    /// The edge a scoped tip clamps to when its anchor is off-screen.
    private func edge(for tip: FeatureTip) -> FeatureTipEdge {
        guard case .scoped(_, let defaultEdge) = tip.behavior else { return .bottom }
        guard let last = lastFrames[tip.anchorID], viewportHeight > 0 else { return defaultEdge }
        return last.midY < viewportHeight / 2 ? .top : .bottom
    }

    /// Pick the highest-priority eligible tip and publish its position.
    private func recompute() {
        let eligible = FeatureTipDefinitions.all.filter(isEligible)
        // A nudge answers a question the user is asking right now, so it jumps
        // the queue rather than waiting its turn on priority.
        let candidate = eligible.first { $0.id == nudgedTipID }
            ?? eligible.max { $0.priority < $1.priority }

        let newFrame = candidate.flatMap { frames[$0.anchorID] }
        let newEdge = candidate.map(edge) ?? .bottom

        let identityChanged = activeTip?.id != candidate?.id
        guard identityChanged || activeFrame != newFrame || fallbackEdge != newEdge else { return }

        if identityChanged {
            // Animate the tip appearing / swapping targets — crisp and bouncy.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) {
                activeTip = candidate
                activeFrame = newFrame
                fallbackEdge = newEdge
            }
        } else {
            // Same tip following its target during a scroll — update position
            // without a per-tick spring so the bubble tracks smoothly.
            activeFrame = newFrame
            fallbackEdge = newEdge
        }
    }

    private func refreshHasUnseenTips() {
        hasUnseenTips = FeatureTipDefinitions.all.contains { !seenIDs.contains($0.id) }
    }

    private func persistSeenIDs() {
        defaults.set(Array(seenIDs), forKey: seenIDsKey)
    }

    // MARK: - Debug / Testing

    /// Clear all seen state so tips reappear (for manual testing).
    func resetSeenState() {
        seenIDs.removeAll()
        sessionSuppressedIDs.removeAll()
        nudgedTipID = nil
        missedTaps.reset()
        refreshHasUnseenTips()
        persistSeenIDs()
        recompute()
    }
}
