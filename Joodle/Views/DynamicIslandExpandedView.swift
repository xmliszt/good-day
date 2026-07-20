//
//  DynamicIslandExpandedView.swift
//  Joodle
//
//  Created by Li Yuxuan on 17/8/25.
//

import SwiftUI

// MARK: - Tunable configuration
//
// All of `DynamicIslandExpandedView`'s tweakable knobs in one place — the open
// animation, the glass backdrop reveal, and the container chrome. Adjust here
// rather than hunting through the view body.
//
// A file-scoped enum (rather than `static` members on the view) because the
// view is generic — `DynamicIslandExpandedView<Content>` — and generic types
// can't hold static stored properties.
private enum DIConfig {

  // MARK: Open / collapse animation

  /// Spring the container's size, scale and fade ride on *expand*. Snappier
  /// (0.4s) and much bouncier than the collapse — the container springs open
  /// with a lively overshoot.
  static let expandSpring: Animation = .spring(response: 0.4, dampingFraction: 0.55, blendDuration: 0.25)

  /// Collapse rides a faster, well-damped spring (the previous open/collapse
  /// curve): a bouncy collapse would overshoot and momentarily peek out from
  /// behind the DI cutout, so it stays damped to tuck away cleanly.
  static let collapseSpring: Animation = .spring(response: 0.25, dampingFraction: 0.8, blendDuration: 0.25)

  /// Width-only spring on expand: far snappier than `expandSpring` so the
  /// container shoots sideways across the DI cutout (concealing it) while the
  /// vertical growth is still barely under way. On collapse the width rides the
  /// calmer `collapseSpring` so it stays wide (still concealing the cutout)
  /// while the height tucks away first — see `heightLeadSpring`.
  static let widthLeadSpring: Animation = .spring(response: 0.4, dampingFraction: 0.9)

  /// Height-only spring on collapse: the mirror of `widthLeadSpring`. On the way
  /// out the vertical dimension leads (tucking the container up into the pill)
  /// while the width lags behind on the slower `collapseSpring`, so the reverse
  /// of the expand choreography plays. Well-damped so the height never
  /// overshoots and peeks out from behind the DI cutout.
  static let heightLeadSpring: Animation = .spring(response: 0.25, dampingFraction: 0.9)

  // MARK: Glass backdrop reveal

  /// Fraction of the container height where the backdrop glass begins while
  /// collapsed (rides the expand spring up to the expanded fraction below).
  static let glassTopFractionCollapsed: CGFloat = 0.9

  /// Settled glass-start fraction in light mode. Must sit below the top button
  /// row and inside the gradient's solid-black band so the glass's straight top
  /// edge is never visible.
  static let glassTopFractionExpandedLight: CGFloat = 0.2

  /// Dark-mode counterpart — the black gradient already blends into the dark
  /// content behind, so only a sliver of glass at the bottom is revealed.
  static let glassTopFractionExpandedDark: CGFloat = 0.2

  // MARK: Container chrome

  /// Inner padding between the container edge and its content, in points. Drives
  /// the content's concentric corner radius (`containerRadius - this`).
  static let contentInnerPaddingPt: CGFloat = 8

  /// Dimming of the backdrop behind the expanded container (0 = none).
  static let backdropDimOpacity: Double = 0.5

  /// Floating container's layered drop shadow when expanded. Two stacked
  /// shadows make the container read as a self-illuminated object hovering
  /// above the content, mimicking the reference glass blob: a wide, dissolved
  /// dark shadow that reads as a faint ring offset from the container, with a
  /// tighter, lighter glow sitting on top of it as the container's own
  /// reflective bloom.
  static let darkShadowRadiusPt: CGFloat = 32
  static let darkShadowYOffsetPt: CGFloat = 36
  static let darkShadowOpacity: Double = 0.45

  /// Reflective bloom: a soft oval glow anchored to the container's bottom
  /// edge, reading as light spilling out the bottom rather than a full-outline
  /// glow. Width is a fraction of the expanded container width.
  static let bloomWidthFraction: CGFloat = 0.82
  static let bloomHeightPt: CGFloat = 8
  static let bloomBlurPt: CGFloat = 6
  static let bloomYOffsetPt: CGFloat = 6
  static let bloomOpacity: Double =  0.7

  /// Horizontal inset from the screen edges on non-Dynamic-Island devices, in
  /// points (DI devices derive it from the cutout frame instead).
  static let nonDIHorizontalInsetPt: CGFloat = 10
}

struct DynamicIslandExpandedView<Content: View>: View {

  @Environment(\.colorScheme) private var colorScheme
  @Binding var isExpanded: Bool
  let content: Content
  let hidden: Bool
  let onDismiss: (() -> Void)?
  /// When non-nil, the visible rounded container registers itself as a
  /// tutorial highlight anchor under this ID, with its own concentric corner
  /// radius. Lets the tutorial overlay cutout hug the floating container
  /// exactly rather than the parent view's full-screen frame.
  let tutorialAnchorID: String?
  /// Whether tapping the backdrop outside the visible container fires
  /// `onDismiss`. Defaults to `true` (the daily "tap outside to save & close"
  /// affordance). The interactive tutorial disables it because dismissal is
  /// driven explicitly per step — an accidental backdrop tap there would close
  /// the canvas out of band and wedge the tutorial flow.
  let dismissOnTapOutside: Bool

  /// Backdrop glass-start fraction — collapsed value rides the expand spring up
  /// to the theme-specific expanded value. All three live in `DIConfig`.
  private var glassTopFraction: CGFloat {
    guard isExpanded else { return DIConfig.glassTopFractionCollapsed }
    return colorScheme == .dark
      ? DIConfig.glassTopFractionExpandedDark
      : DIConfig.glassTopFractionExpandedLight
  }

  init(
    isExpanded: Binding<Bool>,
    @ViewBuilder content: () -> Content,
    hidden: Bool = false,
    onDismiss: (() -> Void)? = nil,
    tutorialAnchorID: String? = nil,
    dismissOnTapOutside: Bool = true
  ) {
    self._isExpanded = isExpanded
    self.content = content()
    self.hidden = hidden
    self.onDismiss = onDismiss
    self.tutorialAnchorID = tutorialAnchorID
    self.dismissOnTapOutside = dismissOnTapOutside
  }

  // MARK: - Layout adaptation
  //
  // On Dynamic Island devices the floating container hides behind the DI
  // cutout when collapsed. On notch / non-cutout devices there's no pill to
  // hide behind, so the container starts just below the top safe area and
  // collapses to zero size when hidden.

  /// Symmetric inset used as the horizontal padding between the container and
  /// the device's screen edges. Picked to keep the container corner radius
  /// concentric with the device's screen corners.
  private var containerHorizontalInset: CGFloat {
    if UIDevice.hasDynamicIsland {
      return UIDevice.dynamicIslandFrame.origin.y
    } else {
      return DIConfig.nonDIHorizontalInsetPt
    }
  }

  /// Y offset where the top edge of the floating container starts.
  private var containerTopOffset: CGFloat {
    if UIDevice.hasDynamicIsland {
      return UIDevice.dynamicIslandFrame.origin.y
    } else {
      // Land just below the notch / status bar area.
      return UIDevice.topSafeAreaInset
    }
  }

  /// Height reserved at the top of the container so the content doesn't draw
  /// under the DI cutout. Zero on non-DI devices since the container starts
  /// below the notch.
  private var topContentInset: CGFloat {
    UIDevice.hasDynamicIsland ? UIDevice.dynamicIslandSize.height : 0
  }

  /// Size of the collapsed container. On DI devices this matches the DI
  /// capsule so it tucks behind the cutout. On non-DI devices we collapse
  /// to zero — there's no cutout to align with.
  private var collapsedSize: CGSize {
    UIDevice.hasDynamicIsland ? UIDevice.dynamicIslandSize : .zero
  }

  /// Liquid Glass rendered inside a zero-size frame aborts the entire view's
  /// render on iOS 26 — on non-DI devices (e.g. iPhone SE) the collapsed
  /// container is `.zero`, which blanked the whole screen. The glass is
  /// invisible while collapsed anyway (covered by the black layer, and
  /// zero-sized here), so only mount it once the container has a real frame.
  private var shouldRenderContainerGlass: Bool {
    isExpanded || collapsedSize != .zero
  }

  /// Outer container corner radius, concentric with the device screen.
  private var containerCornerRadius: CGFloat {
    max(UIDevice.screenCornerRadius - containerHorizontalInset, 0)
  }

  /// Content clip corner radius — accounts for the inner padding.
  private var contentCornerRadius: CGFloat {
    max(containerCornerRadius - DIConfig.contentInnerPaddingPt, 0)
  }

  private var expandedContentWidth: CGFloat {
    UIScreen.main.bounds.width - (containerHorizontalInset * 2)
  }

  /// Corner radius of the DI cutout itself — a capsule, so the radius is half
  /// the cutout height. The collapsed container matches this exactly so it tucks
  /// cleanly behind the cutout with no corners peeking out.
  private var collapsedCornerRadius: CGFloat {
    collapsedSize.height / 2
  }

  private var containerShape: RoundedRectangle {
    // While collapsed the radius matches the DI capsule (half the cutout
    // height) so the shape tucks exactly behind the cutout. On expand it
    // animates up to the screen-concentric radius; on collapse it animates
    // back down to the capsule radius so the corners never grow larger than
    // the cutout and leak out around it.
    RoundedRectangle(
      cornerRadius: isExpanded ? containerCornerRadius : collapsedCornerRadius,
      style: .continuous
    )
  }

  /// Hairline rim light tracing the container edge — a non-uniform,
  /// gradient-driven stroke (brightest along the top edge and corners, fading
  /// down the sides, with a faint re-catch at the bottom lip) that reads as
  /// the glass edge catching ambient light. This is what keeps the dark
  /// container legible against a dark background; the bottom region already
  /// gets a real refractive edge from the glass backdrop, so the stroke stays
  /// subtle there.
  private var containerEdgeHighlight: some View {
    containerShape
      .strokeBorder(
        LinearGradient(
          stops: [
            .init(color: .white.opacity(0.0), location: 0),
            .init(color: .white.opacity(0.0), location: 0.3),
            .init(color: .white.opacity(0.1), location: 0.5),
            .init(color: .white.opacity(0.3), location: 0.75),
            .init(color: .white.opacity(0.5), location: 1),
          ],
          startPoint: .top,
          endPoint: .bottom
        ),
        lineWidth: 1
      )
      // Hidden while collapsed so no rim ever outlines the pill tucked behind
      // the DI cutout; fades in with the expand spring.
      .opacity(isExpanded ? 1 : 0)
      .allowsHitTesting(false)
  }

  /// Color of the bottom contrast wash — the theme's *opposite* tone so it
  /// lifts the foreground prompt text off the clear glass: white in light
  /// mode, black in dark mode.
  private var contrastWashColor: Color {
    colorScheme == .dark ? .white.opacity(0.4) : .white.opacity(0.8)
  }

  /// Contrast wash rising from the bottom edge of the container. The clear
  /// glass at the bottom refracts the background and kills the contrast of
  /// the inspirational prompt text drawn over it; this lays a subtle
  /// opposite-tone glow underneath the text to restore legibility.
  ///
  /// Shape is a horizontally-placed half oval — the flat bottom spans the
  /// full container width and the top arcs up to a rounded crown, fading out
  /// completely by ~20% of the container height. Brightest (20% opacity)
  /// along the bottom, fading to clear toward the top.
  private var contrastWash: some View {
    GeometryReader { proxy in
      EllipticalGradient(
        stops: [
          .init(color: contrastWashColor, location: 0),
          .init(color: .white.opacity(0), location: 1),
        ],
        center: .bottom
      )
      // The frame is twice the target reveal so the ellipse's *upper half*
      // (centered on the bottom edge) spans the visible bottom 20%, full
      // width across the base and curving up to the rounded crown.
      .frame(height: proxy.size.height * 0.4)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
    // Tied to the expansion — the prompt text only shows once expanded, and
    // it should never leak around the collapsed pill.
    .opacity(isExpanded ? 1 : 0)
    .allowsHitTesting(false)
  }

  /// Container backdrop: clear Liquid Glass that refracts the content
  /// behind the container, under a black gradient that stays solid
  /// at the top (so it still blends into the DI cutout) and fades out toward
  /// the bottom so the glass edge shows through. While collapsed — and on
  /// pre-iOS 26 — the container stays flat black so it conceals inside the
  /// island cutout.
  private var containerBackground: some View {
    ZStack {
      if #available(iOS 26.0, *) {
        // Glass only in the bottom region the gradient reveals: it would be
        // invisible under the solid-black top anyway, and extending it under
        // the top button row stacks the buttons' Liquid Glass on this surface
        // — unsupported, and it made the buttons render invisible. The glass
        // view's *frame* is confined to the bottom region (not just its
        // shape): the system resolves glass stacking by view bounds, so a
        // full-size view with a bottom-only shape still underlaps the
        // buttons. Scoped in its own GlassEffectContainer so it also never
        // merges with them. Skipped while the container is collapsed to zero
        // size (non-DI devices) — zero-size Liquid Glass aborts the render.
        if shouldRenderContainerGlass {
          GlassEffectContainer {
            GeometryReader { proxy in
              Color.clear
                .glassEffect(
                  .clear,
                  in: UnevenRoundedRectangle(
                    cornerRadii: .init(
                      bottomLeading: containerCornerRadius,
                      bottomTrailing: containerCornerRadius
                    ),
                    style: .continuous
                  )
                )
                .frame(height: proxy.size.height * (1 - glassTopFraction))
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
          }
        }
      } else {
        // No Liquid Glass: a frosted ultra-thin material gives a soft blur of
        // the content behind the bottom region (where the gradient fades to
        // clear) instead of the clear-glass look, which renders badly on these
        // OSes.
        Rectangle().fill(.ultraThinMaterial)
      }

      LinearGradient(
        stops: [
          .init(color: .black, location: 0),
          .init(color: .black, location: (1 - glassTopFraction)),
          .init(color: .black.opacity(0), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )

      // Half-oval contrast glow rising from the bottom edge so the prompt
      // text stays legible over the clear refractive glass. Only needed on
      // Liquid Glass: the frosted material fallback is opaque enough on its
      // own, so the wash is redundant there.
      if #available(iOS 26.0, *) {
        contrastWash
      }

      // Solid cover while collapsed; fades out with the expand spring so the
      // glass bottom is only revealed once the container leaves the cutout.
      Color.black.opacity(isExpanded ? 0 : 1)
    }
  }

  var body: some View {
    ZStack {
      // Backdrop when expanded: a subtle dim instead of a blur material — the
      // container's clear Liquid Glass refracts what's behind it, and blurring
      // the backdrop would wash out that lensing. Keeping the content sharp
      // (just darkened for focus) lets the glass edge distortion read clearly.
      if isExpanded {
        Rectangle().fill(Color.black.opacity(DIConfig.backdropDimOpacity))
      }

      // Invisible container
      // Optional to set background to make content below opaque
      VStack {
        // Visible content
        VStack(spacing: 0) {
          // Top reserved space so content doesn't draw under the DI cutout.
          if topContentInset > 0 {
            Spacer()
              .frame(maxWidth: .infinity, maxHeight: topContentInset)
          }

          // The content
          content
            .frame(width: expandedContentWidth)
            .clipShape(RoundedRectangle(cornerRadius: contentCornerRadius, style: .continuous))
        }
        .opacity(isExpanded ? 1 : 0)
        .scaleEffect(isExpanded ? 1 : 0)
        .animation(isExpanded ? DIConfig.expandSpring : DIConfig.collapseSpring, value: isExpanded)
        // Width on a much faster spring than height *on expand* so the
        // horizontal expansion decisively leads: the container snaps sideways
        // across the DI cutout and conceals it while the vertical growth
        // (standard spring, ~4× slower) is still barely under way. On collapse
        // the roles reverse — width rides the calmer `collapseSpring` so it
        // stays wide while the height leads (see the height frame below).
        .frame(width: isExpanded ? expandedContentWidth : collapsedSize.width)
        .animation(
          isExpanded ? DIConfig.widthLeadSpring : DIConfig.collapseSpring,
          value: isExpanded
        )
        // Height is the mirror image of the width spring: on expand it lags
        // (slow `expandSpring`) so the width leads; on collapse it leads
        // (snappy `heightLeadSpring`) so the container tucks up vertically
        // first while the width is still shrinking behind it.
        .frame(
          height: isExpanded ? nil : collapsedSize.height,
          alignment: .top)
        .animation(
          isExpanded ? DIConfig.expandSpring : DIConfig.heightLeadSpring,
          value: isExpanded
        )
        // Black at the top to blend into the dynamic island cutout, fading
        // into clear refractive glass toward the bottom when expanded.
        .background(containerBackground)
        // Corner radius matches border of the device
        .clipShape(containerShape)
        // Rim light along the clipped edge — drawn above the clip so the
        // hairline never gets shaved off by it.
        .overlay(containerEdgeHighlight)
        .tutorialHighlightAnchor(
          tutorialAnchorID ?? "",
          isEnabled: tutorialAnchorID != nil,
          cornerRadius: containerCornerRadius
        )
        // Reflective bloom: a soft oval glow placed BEHIND the container and
        // anchored to its bottom edge. The container's opaque black top covers
        // the upper half of the ellipse, so the glow only blooms out the
        // bottom — light spilling from the base rather than a full outline.
        // Applied before the dark shadow so it layers in front of it.
        .background(alignment: .bottom) {
          Ellipse()
            .fill(Color.white)
            .frame(
              width: expandedContentWidth * DIConfig.bloomWidthFraction,
              height: DIConfig.bloomHeightPt
            )
            .blur(radius: DIConfig.bloomBlurPt)
            .offset(y: DIConfig.bloomYOffsetPt)
            .opacity(
              isExpanded
                ? // If in light theme, use bloomOpacity; otherwise in dark theme, use custom value 0.9
                colorScheme == .light ? DIConfig.bloomOpacity : 0.9 : 0
            )
        }
        // Wide, dissolved dark shadow sitting furthest back — a faint ring
        // offset from the container. Together with the bloom the container
        // reads as a self-illuminated pane of glass hovering above the content.
        // Rides the expand spring (clear while collapsed so nothing leaks
        // around the DI cutout).
        .shadow(
          color: isExpanded ? .black.opacity(DIConfig.darkShadowOpacity) : .clear,
          radius: DIConfig.darkShadowRadiusPt,
          y: DIConfig.darkShadowYOffsetPt
        )
        // Chrome (clip shape, rim-light overlay, background, bloom, shadow)
        // shares the height's spring on *both* directions. This matters most for
        // the clipped corner radius: it animates between the screen-concentric
        // radius and the DI-capsule radius, and must shrink in lockstep with the
        // height. If it lagged on a slower spring the `RoundedRectangle` clamp
        // (radius → height/2) would overtake it and the corner would snap to a
        // capsule instantly instead of rounding smoothly.
        .animation(isExpanded ? DIConfig.expandSpring : DIConfig.heightLeadSpring, value: isExpanded)
        // Tap gesture to absorb tap in the visible container to prevent dismiss
        .onTapGesture {}
        // Absorb every other touch sequence over the container, not just taps:
        // the hit region spans the full container shape (transparent regions
        // included) and the zero-distance drag claims presses/drags for the
        // container, so touch-downs can never fall through and flash a pressed
        // state on a button sitting behind the expanded view. Simultaneous, so
        // the canvas's own drawing gesture and buttons are unaffected.
        .contentShape(containerShape)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in })

        // Spacer to push the actual visible content to the top
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // Move it so that it is at the position of dynamic island / below the notch
      .offset(y: containerTopOffset)
    }
    .ignoresSafeArea(.all, edges: .vertical)
    // Define hit zone
    .contentShape(RoundedRectangle(cornerRadius: UIDevice.screenCornerRadius))
    // Only receive hit test when expanded. This must stay enabled even when
    // backdrop-tap dismiss is off: the container still needs to absorb taps in
    // the backdrop region (so they don't fall through to the view behind) and
    // to keep its own content — the canvas and its buttons — interactive.
    .allowsHitTesting(isExpanded)
    .animation(isExpanded ? DIConfig.expandSpring : DIConfig.collapseSpring, value: isExpanded)
    .onTapGesture {
      // The tutorial drives canvas dismissal explicitly per step, so a stray
      // backdrop tap must not close the canvas — but the tap is still absorbed
      // here (no fall-through to the grid behind).
      guard dismissOnTapOutside else { return }
      onDismiss?()
    }
    // Hide status bar when expanded
    .statusBarHidden(isExpanded)
    .if(self.hidden) { view in
      view.hidden()
    }
  }
}

#Preview("Shrinked View") {
  @Previewable @State var isExpanded = false
  ZStack {
    DynamicIslandExpandedView(
      isExpanded: $isExpanded,
      content: {
        Button("Tap me") {
          debugPrint("HELLO")
        }
      },
      hidden: false,
      onDismiss: {
        isExpanded = false
      }
    )
    Button("Toggle") {
      isExpanded.toggle()
    }
  }
}

#Preview("Expanded View") {
  @Previewable @State var isExpanded = true

  ZStack {
    DynamicIslandExpandedView(
      isExpanded: $isExpanded,
      content: {
        ZStack {
          Color.blue
          Text("HELLO WORLD")
        }
        .frame(height: 300)
      },
      hidden: false,
      onDismiss: {
        isExpanded = false
      })
    Button("Toggle") {
      isExpanded.toggle()
    }
  }
}

#Preview("Hidden View") {
  @Previewable @State var isExpanded = true

  ZStack {
    DynamicIslandExpandedView(
      isExpanded: $isExpanded,
      content: {
        ZStack {
          Color.blue
          Text("HELLO WORLD")
        }
        .frame(height: 300)
      },
      hidden: true,
      onDismiss: {
        isExpanded = false
      })
    Button("Toggle") {
      isExpanded.toggle()
    }
  }
}
