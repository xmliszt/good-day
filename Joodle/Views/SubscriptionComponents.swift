//
//  SubscriptionComponents.swift
//  Joodle
//
//  Created by Subscription Components
//

import SwiftUI

// MARK: - Trial Timeline

/// A three-stage trial timeline rendered as a vertical rail (à la TIDE): each stage's
/// icon sits on a connecting line on the left, and the line fills as the trial progresses.
/// Labels differ by context — see `Style`.
struct TrialTimelineView: View {
  /// Which label set to show.
  /// `.onboarding` is forward-looking ("Today / In 5 days / In 7 days");
  /// `.trial` describes the stages once the trial is already underway.
  enum Style { case onboarding, trial }

  let style: Style
  /// Fraction (0...1) of the trial elapsed. The rail fills to exactly this fraction of its
  /// total height, and each milestone lights when the fill reaches its day position.
  let progress: Double

  private struct Node {
    let icon: String
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
  }

  /// Day each milestone sits at, along a 7-day trial: start (0), reminder (5), ends (7).
  /// Milestones are spaced evenly; only the rail *fill* is proportional to elapsed time.
  private let dayAnchors: [Double] = [0, 5, 7]
  private let totalDays: Double = 7
  /// Uniform height of every connector between milestones (visual spacing, not time-scaled).
  private let segmentHeight: CGFloat = 28

  private var elapsedDays: Double { min(max(progress, 0), 1) * totalDays }

  /// Index of the latest milestone the trial has reached (for highlighting its label).
  private var activeIndex: Int {
    dayAnchors.lastIndex(where: { elapsedDays >= $0 - 0.0001 }) ?? 0
  }

  private var nodes: [Node] {
    switch style {
    case .onboarding:
      return [
        Node(icon: "lock.open.fill", title: "Today", subtitle: "Full access to all Pro features."),
        Node(icon: "bell.fill", title: "In 5 days", subtitle: "We'll remind you before it ends."),
        Node(icon: "crown.fill", title: "In 7 days", subtitle: "No auto charge — get Pro, or keep doodling on Free.")
      ]
    case .trial:
      return [
        Node(icon: "lock.open.fill", title: "Pro trial starts", subtitle: "Full access to all Pro features."),
        Node(icon: "bell.fill", title: "Reminder", subtitle: "We'll remind you before it ends."),
        Node(icon: "crown.fill", title: "Pro trial ends", subtitle: "No auto charge — get Pro, or keep doodling on Free.")
      ]
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
        nodeRow(index: index, node: node, isLast: index == nodes.count - 1)
      }
    }
    .padding(.horizontal, 24)
  }

  private func nodeRow(index: Int, node: Node, isLast: Bool) -> some View {
    let reached = elapsedDays >= dayAnchors[index] - 0.0001
    // Connectors are a fixed height; the fill within each reflects elapsed time across its day-span.
    let segmentDays = isLast ? 0 : dayAnchors[index + 1] - dayAnchors[index]
    let segmentFill = segmentDays == 0 ? 0 : min(max((elapsedDays - dayAnchors[index]) / segmentDays, 0), 1)

    return HStack(alignment: .top, spacing: 14) {
      // Left rail: icon circle + proportional connecting line below it
      VStack(spacing: 0) {
        ZStack {
          Circle()
            .fill(reached ? Color.appAccent : Color.clear)
            .overlay(Circle().strokeBorder(reached ? Color.clear : Color.borderColor, lineWidth: 1.5))
            .frame(width: 30, height: 30)
          Image(systemName: node.icon)
            .font(.appFont(size: 12, weight: .bold))
            .foregroundColor(reached ? .appAccentContrast : .secondary)
        }
        if !isLast {
          ZStack(alignment: .top) {
            Capsule()
              .fill(Color.borderColor.opacity(0.5))
              .frame(width: 2, height: segmentHeight)
            Capsule()
              .fill(Color.appAccent)
              .frame(width: 2, height: segmentHeight * CGFloat(segmentFill))
              .animation(.springFkingSatifying, value: segmentFill)
          }
        }
      }

      // Stage text
      VStack(alignment: .leading, spacing: 2) {
        Text(node.title)
          .font(.appHeadline())
          .foregroundColor(index == activeIndex ? .appAccent : .primary)
        Text(node.subtitle)
          .font(.appCaption())
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.bottom, isLast ? 0 : 12)

      Spacer(minLength: 0)
    }
  }
}

// MARK: - Pro Comparison Table

/// A Free-vs-Pro comparison table for the expired/pay paywall.
/// Shows concrete free values (e.g. "30", "5") rather than meaningless checkmarks,
/// so the gap between Free and Pro is visceral.
struct ProComparisonTable: View {
  private struct ComparisonRow: Identifiable {
    let id = UUID()
    let label: LocalizedStringResource
    let free: String
    let pro: LocalizedStringResource
    /// Pro value is "unlimited" — prefix it with an infinity glyph instead of text.
    let proIsUnlimited: Bool
    /// Pro value is the wiggly placeholder doodle instead of text.
    var proIsWiggle: Bool = false
    /// Pro value is a rainbow gradient chip instead of text.
    var proIsRainbow: Bool = false
  }

  private var rows: [ComparisonRow] {
    [
      ComparisonRow(label: "Joodle entries",
                    free: "\(SubscriptionManager.freeJoodlesAllowed)", pro: "Unlimited", proIsUnlimited: true),
      ComparisonRow(label: "Anniversary alarms",
                    free: "\(SubscriptionManager.freeAnniversaryAlarmsAllowed)", pro: "Unlimited", proIsUnlimited: true),
      ComparisonRow(label: "Auto trace",
                    free: String(localized: "Once a day"), pro: "Unlimited", proIsUnlimited: true),
      ComparisonRow(label: "Widgets",
                    free: "—", pro: "All widgets", proIsUnlimited: false),
      ComparisonRow(label: "Sharing",
                    free: String(localized: "With Joodle mark"), pro: "No watermark", proIsUnlimited: false),
      ComparisonRow(label: "Theme color",
                    free: String(localized: "Core single color"), pro: "", proIsUnlimited: false, proIsRainbow: true),
      ComparisonRow(label: "Wiggly strokes",
                    free: "—", pro: "", proIsUnlimited: false, proIsWiggle: true),
      ComparisonRow(label: "Fun experiment",
                    free: "—", pro: "Full access", proIsUnlimited: false)
    ]
  }

  private let valueColumnWidth: CGFloat = 112

  var body: some View {
    VStack(spacing: 0) {
      headerRow
        .padding(.bottom, 6)

      ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        if index > 0 {
          Divider().overlay(Color.borderColor.opacity(0.4))
        }
        valueRow(row)
      }
    }
    .padding(.vertical, 8)
    .background(
      // Highlight the Pro column behind every row.
      HStack(spacing: 0) {
        Spacer()
        RoundedRectangle(cornerRadius: 16)
          .fill(
            LinearGradient(
              colors: [.appAccent.opacity(0.08), .appAccent.opacity(0.16)],
              startPoint: .top, endPoint: .bottom
            )
          )
          .overlay(
            RoundedRectangle(cornerRadius: 16)
              .strokeBorder(Color.appAccent.opacity(0.45), lineWidth: 1)
          )
          .frame(width: valueColumnWidth)
      }
    )
    .padding(.horizontal, 20)
    .padding(.bottom, 16)
  }

  private var headerRow: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      Text("Free")
        .font(.appCaption(weight: .bold))
        .foregroundColor(.secondary)
        .frame(width: valueColumnWidth)
      HStack(spacing: 3) {
        Image(systemName: "crown.fill").font(.appFont(size: 9))
        Text("Pro").font(.appCaption(weight: .bold))
      }
      .foregroundColor(.appAccent)
      .frame(width: valueColumnWidth)
    }
  }

  private func valueRow(_ row: ComparisonRow) -> some View {
    HStack(spacing: 0) {
      Text(row.label)
        .font(.appCaption())
        .foregroundColor(.primary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text(row.free)
        .font(.appCaption())
        .foregroundColor(.secondary)
        .frame(width: valueColumnWidth)

      Group {
        if row.proIsWiggle {
          // Showcase the feature with a single boiling line at the canvas's true
          // stroke width, so the wiggle reads clearly. The row grows past its
          // 44pt minimum to fit.
          WigglyLinePreview()
            .frame(width: valueColumnWidth, height: 52)
        } else if row.proIsRainbow {
          // The rainbow theme's Pro value: a gradient chip rather than the word
          // "Rainbow", inset so its padding matches the other cells.
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
              LinearGradient(
                colors: RainbowPalette.colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        } else if row.proIsUnlimited {
          HStack(spacing: 3) {
            Image(systemName: "infinity").font(.appFont(size: 13, weight: .bold))
            Text(row.pro)
          }
        } else {
          Text(row.pro)
        }
      }
      .font(.appCaption(weight: .bold))
      .foregroundColor(.appAccent)
      .frame(width: valueColumnWidth)
    }
    .frame(minHeight: 44)
  }
}

// MARK: - Wiggly Line Preview

/// A single hand-drawn-looking line that boils with the wigglypaint effect,
/// drawn at the canvas's true stroke width and jitter amplitude (1:1, no
/// scaling) so the Pro comparison row shows the feature exactly as it reads
/// while doodling.
private struct WigglyLinePreview: View {
  /// Stable anchor for the boil's periodic clock.
  @State private var epoch = Date()

  /// A loose wave — deliberately not straight, to read like a real stroke —
  /// sampled densely enough that the per-vertex boil looks like a lively wiggle.
  private func points(in size: CGSize) -> [CGPoint] {
    let count = 28
    let padX: CGFloat = 16
    let usableWidth = size.width - padX * 2
    let midY = size.height / 2
    let amplitude = size.height * 0.18
    return (0..<count).map { i in
      let t = CGFloat(i) / CGFloat(count - 1)
      let x = padX + t * usableWidth
      // 1.5 humps plus a faint faster ripple so it looks hand-drawn, not sinusoidal.
      let y = midY - amplitude * (sin(t * .pi * 3) * 0.85 + sin(t * .pi * 6 + 0.7) * 0.15)
      return CGPoint(x: x, y: y)
    }
  }

  var body: some View {
    TimelineView(.periodic(from: epoch, by: WigglyStroke.boilInterval)) { timeline in
      Canvas { context, size in
        let frame = WigglyStroke.frameIndex(at: timeline.date.timeIntervalSinceReferenceDate)
        let path = WigglyStroke.path(points: points(in: size), isDot: false, frame: frame)
        context.stroke(
          path,
          with: .color(.appAccent),
          style: StrokeStyle(lineWidth: DRAWING_LINE_WIDTH, lineCap: .round, lineJoin: .round)
        )
      }
    }
  }
}

// MARK: - Previews

#Preview("Trial Timeline") {
  VStack(spacing: 40) {
    TrialTimelineView(style: .onboarding, progress: 0)        // day 0
    TrialTimelineView(style: .trial, progress: 3.0 / 7.0)     // day 3 — partial fill
    TrialTimelineView(style: .trial, progress: 6.0 / 7.0)     // day 6 — past reminder
  }
  .padding(.vertical)
}

#Preview("Pro Comparison Table") {
  ProComparisonTable()
}

