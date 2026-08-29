//
//  AutoTraceLab.swift
//  Joodle
//
//  Development-only tuning workbench for the auto-trace engine. Not referenced
//  in the shipping UI — reach it via Settings → Developer Options (DEBUG) or the
//  `#Preview` below. Import a photo from the album or capture a fresh one, sweep
//  the sliders while the trace re-runs live, then Export the config and paste it
//  back into AutoTraceDetail.swift / AutoTraceEngine.swift. Mirrors the shape of
//  `FujifilmFilterLab`.
//

#if DEBUG

import PhotosUI
import SwiftUI
import UIKit

struct AutoTraceLab: View {
  @State private var config = AutoTraceConfig(detail: .balanced)
  @State private var showOriginal = false
  @State private var showExport = false
  @State private var didCopy = false

  // Source photo, square-cropped to match Joodle's reference capture. `base`
  // changes as the user imports/captures; `baseVersion` lets the trace task
  // observe those swaps alongside `config` changes.
  @State private var base: UIImage?
  @State private var baseVersion = 0
  @State private var pickerItem: PhotosPickerItem?
  @State private var showCamera = false
  @State private var showPhotoPicker = false

  // Latest trace, encoded the way `DayEntry.drawingData` stores it so the
  // preview renders through the exact same path the app and widget use.
  @State private var strokesData: Data?
  @State private var isTracing = false
  @State private var strokeCount = 0
  @State private var pointCount = 0
  @State private var usedIsolation = false
  @State private var elapsedMs: Double = 0

  // Per-step snapshots for the debug strip, plus the one tapped for a zoomed look.
  @State private var stages: [AutoTraceStage] = []
  @State private var zoomedStage: AutoTraceStage?

  private let previewSide: CGFloat = CANVAS_SIZE

  private struct TraceKey: Equatable {
    var config: AutoTraceConfig
    var version: Int
  }

  var body: some View {
    VStack(spacing: 0) {
      preview
      if !stages.isEmpty {
        stagesStrip
      }
      Divider()
      controls
    }
    .sheet(item: $zoomedStage) { stage in
      stageZoomSheet(stage)
    }
    .task(id: pickerItem) {
      guard let item = pickerItem else { return }
      if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
        setBase(image)
      }
    }
    .fullScreenCover(isPresented: $showCamera) {
      TraceCameraPicker { image in
        setBase(image)
        showCamera = false
      }
      .ignoresSafeArea()
    }
    .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images, photoLibrary: .shared())
    .sheet(isPresented: $showExport) {
      exportSheet
    }
  }

  // MARK: - Preview

  private var preview: some View {
    ZStack {
      Color(uiColor: .systemBackground)
      if let base {
        ZStack {
          // The source, dimmed, as a tracing reference underneath the strokes —
          // or full-strength while pressing, to compare against the trace.
          Image(uiImage: base)
            .resizable()
            .scaledToFit()
            .frame(width: previewSide, height: previewSide)
            .opacity(showOriginal ? 1 : 0.18)

          if !showOriginal, let strokesData {
            DoodleRendererView(
              size: previewSide,
              hasEntry: true,
              dotStyle: .present,
              drawingData: strokesData,
              strokeColor: .primary,
              renderScale: 1.0,
              showEmptyDot: false
            )
          }
        }
        .frame(width: previewSide, height: previewSide)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) { statsBadge }
        .overlay(alignment: .topLeading) { replaceButton }
        .overlay(alignment: .topTrailing) {
          if isTracing {
            ProgressView()
              .padding(8)
          }
        }
      } else {
        VStack(spacing: 12) {
          Image(systemName: "photo.on.rectangle.angled")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text(verbatim: "Import or capture a photo to begin")
            .font(.callout)
            .foregroundStyle(.secondary)
          sourceButtons
        }
        .padding()
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 380)
    .contentShape(Rectangle())
    .onLongPressGesture(minimumDuration: 0) {
    } onPressingChanged: { pressing in
      showOriginal = pressing
    }
    // Debounced live re-trace: cancelled and restarted on every config or image
    // change, so a full trace (a few hundred ms) only fires once a slider drag
    // settles rather than on every tick.
    .task(id: TraceKey(config: config, version: baseVersion)) {
      await retrace()
    }
  }

  // MARK: - Step-by-step strip

  private var stagesStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(alignment: .top, spacing: 10) {
        ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
          Button {
            zoomedStage = stage
          } label: {
            VStack(spacing: 4) {
              Image(uiImage: stage.image)
                .resizable()
                .scaledToFit()
                .frame(width: 92, height: 92)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                  RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 0.5))
              Text(verbatim: "\(index + 1). \(stage.title)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
              Text(verbatim: stage.subtitle)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(width: 100)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .frame(height: 150)
  }

  private func stageZoomSheet(_ stage: AutoTraceStage) -> some View {
    NavigationStack {
      ScrollView([.horizontal, .vertical]) {
        Image(uiImage: stage.image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity)
          .padding()
      }
      .navigationTitle(Text(verbatim: stage.title))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { zoomedStage = nil }
        }
      }
    }
  }

  private var statsBadge: some View {
    Text(verbatim: showOriginal
      ? "ORIGINAL"
      : "\(strokeCount) strokes · \(pointCount) pts · \(usedIsolation ? "isolated" : "full frame") · \(Int(elapsedMs)) ms")
      .font(.caption2.weight(.semibold).monospacedDigit())
      .foregroundStyle(.white)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.black.opacity(0.55), in: Capsule())
      .padding(.bottom, 10)
  }

  private var sourceButtons: some View {
    HStack {
      Button {
        showPhotoPicker = true
      } label: {
        Label("Photo Library", systemImage: "photo")
      }
      Button {
        showCamera = true
      } label: {
        Label("Camera", systemImage: "camera")
      }
      .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
    }
    .font(.caption.weight(.semibold))
    .buttonStyle(.bordered)
  }

  /// In-place photo swap without leaving the lab. Sits on the preview so a new
  /// subject is one tap away while tuning.
  private var replaceButton: some View {
    Menu {
      Button {
        showPhotoPicker = true
      } label: {
        Label("Photo Library", systemImage: "photo")
      }
      Button {
        showCamera = true
      } label: {
        Label("Camera", systemImage: "camera")
      }
      .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
    } label: {
      Label("Replace", systemImage: "arrow.triangle.2.circlepath")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
    }
    .padding(8)
  }

  // MARK: - Controls

  private var controls: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Menu {
            Button("Simple") { config = AutoTraceConfig(detail: .simple) }
            Button("Balanced") { config = AutoTraceConfig(detail: .balanced) }
            Button("Detailed") { config = AutoTraceConfig(detail: .detailed) }
          } label: {
            Label("Load preset", systemImage: "slider.horizontal.3")
              .font(.caption2)
          }
          .buttonStyle(.bordered)
          Spacer()
        }

        Button {
          UIPasteboard.general.string = config.swiftLiteral
          didCopy = true
          showExport = true
        } label: {
          Label("Export config", systemImage: "square.and.arrow.up")
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

        Text(verbatim: "Press and hold the preview to compare against the source photo.")
          .font(.caption2)
          .foregroundStyle(.secondary)

        group("Subject & source") {
          Toggle(isOn: $config.useSubjectIsolation) {
            Text(verbatim: "Isolate subject").font(.caption2)
          }
          intSlider("Render side (px)", $config.renderSide, 256...2048)
        }
        group("Edge extraction") {
          Picker(selection: $config.edgeMethod) {
            ForEach(AutoTraceEdgeMethod.allCases) { method in
              Text(verbatim: method.title).tag(method)
            }
          } label: {
            Text(verbatim: "Method")
          }
          .pickerStyle(.menu)
          .font(.caption2)

          Text(verbatim: config.edgeMethod == .none
            ? "Region mode traces the silhouette only — interior lines are not captured."
            : "Edge mode builds a line map first, so interior lines are traced too.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

          if config.edgeMethod != .none {
            slider("Dilation (close gaps)", $config.edgeDilation, 0...4)
            Toggle(isOn: $config.useOtsuThreshold) {
              Text(verbatim: "Otsu auto-threshold").font(.caption2)
            }
            if !config.useOtsuThreshold {
              slider("Binary threshold", $config.binaryThreshold, 0...1)
            }
          }
        }
        if config.edgeMethod == .canny {
          group("Canny") {
            slider("Gaussian sigma", $config.cannyGaussianSigma, 0.5...8)
            slider("Threshold low", $config.cannyThresholdLow, 0...0.3)
            slider("Threshold high", $config.cannyThresholdHigh, 0...0.5)
            intSlider("Hysteresis passes", intBinding(\.cannyHysteresisPasses), 0...20)
          }
        }
        if config.edgeMethod == .sobel {
          group("Sobel") {
            slider("Edge intensity", $config.sobelEdgeIntensity, 0.5...10)
          }
        }
        if config.edgeMethod == .lineOverlay {
          group("Line overlay") {
            slider("Noise level", $config.lineNoiseLevel, 0...0.5)
            slider("Sharpness", $config.lineSharpness, 0...2)
            slider("Edge intensity", $config.lineEdgeIntensity, 0...5)
            slider("Threshold", $config.lineThreshold, 0...1)
            slider("Contrast", $config.lineContrast, 1...100)
          }
        }
        if config.edgeMethod == .none {
          group("Conditioning") {
            slider("Saturation", $config.conditionSaturation, 0...1)
            slider("Contrast", $config.conditionContrast, 0.5...2)
            slider("Blur radius", $config.blurRadius, 0...5)
          }
        }
        group("Contours & simplification") {
          intSlider("Child depth (interior detail)", intBinding(\.childDepth), 0...4)
          slider("Polygon epsilon", $config.polygonEpsilon, 0.0005...0.02)
          slider("Resample spacing", $config.resampleSpacing, 1...8)
        }
        group("Culling & budgets") {
          slider("Min perimeter fraction", $config.minPerimeterFraction, 0.005...0.1)
          intSlider("Max strokes", intBinding(\.maxStrokes), 10...400)
          intSlider("Max points", intBinding(\.maxPoints), 200...6000)
        }
      }
      .padding(16)
    }
  }

  // MARK: - Export

  private var exportSheet: some View {
    let literal = config.swiftLiteral
    return NavigationStack {
      ScrollView {
        Text(verbatim: literal)
          .font(.system(.footnote, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
      }
      .navigationTitle(Text(verbatim: "Auto-Trace Config"))
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 8) {
          if didCopy {
            Label("Copied to clipboard", systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.green)
          }
          HStack {
            Button {
              UIPasteboard.general.string = literal
              didCopy = true
            } label: {
              Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            ShareLink(item: literal) {
              Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
          }
        }
        .padding()
        .background(.bar)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { showExport = false }
        }
      }
    }
  }

  // MARK: - Tracing

  private func retrace() async {
    guard let base else { return }
    try? await Task.sleep(nanoseconds: 250_000_000)
    if Task.isCancelled { return }

    isTracing = true
    let request = AutoTraceRequest(
      image: base, zoom: 1, rotation: .zero, offset: .zero, detail: .balanced)
    let cfg = config
    let started = Date()
    let result = await Task.detached(priority: .userInitiated) {
      AutoTraceEngine.debugStages(request, config: cfg)
    }.value
    if Task.isCancelled { return }

    let outcome = result.outcome
    strokeCount = outcome.strokes.count
    pointCount = outcome.strokes.reduce(0) { $0 + $1.points.count }
    usedIsolation = outcome.usedSubjectIsolation
    elapsedMs = Date().timeIntervalSince(started) * 1000
    strokesData = try? JSONEncoder().encode(outcome.strokes)
    stages = result.stages
    isTracing = false
  }

  // MARK: - Image source

  /// Centre-crops to a square and downsamples to the same 1024px the real
  /// reference-capture backdrop uses, so the lab traces exactly what a live
  /// capture would.
  private func setBase(_ image: UIImage) {
    let targetPx: CGFloat = 1024
    let side = min(image.size.width, image.size.height)
    let scale = targetPx / side
    let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let origin = CGPoint(x: (targetPx - drawSize.width) / 2, y: (targetPx - drawSize.height) / 2)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetPx, height: targetPx), format: format)
    base = renderer.image { _ in
      image.draw(in: CGRect(origin: origin, size: drawSize))
    }
    baseVersion += 1
  }

  // MARK: - Building blocks

  private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(verbatim: label).font(.caption2)
        Spacer()
        Text(verbatim: String(format: "%.4f", value.wrappedValue))
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range)
    }
  }

  private func intSlider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(verbatim: label).font(.caption2)
        Spacer()
        Text(verbatim: "\(Int(value.wrappedValue.rounded()))")
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range)
    }
  }

  /// Bridges an `Int` config field to the `Binding<Double>` the sliders take,
  /// rounding on write.
  private func intBinding(_ keyPath: WritableKeyPath<AutoTraceConfig, Int>) -> Binding<Double> {
    Binding(
      get: { Double(config[keyPath: keyPath]) },
      set: { config[keyPath: keyPath] = Int($0.rounded()) }
    )
  }
}

// MARK: - Camera capture

/// Minimal `UIImagePickerController` wrapper for capturing a fresh photo in the
/// lab. Requires the app's existing camera usage description.
private struct TraceCameraPicker: UIViewControllerRepresentable {
  var onImage: (UIImage) -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let onImage: (UIImage) -> Void

    init(onImage: @escaping (UIImage) -> Void) { self.onImage = onImage }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = info[.originalImage] as? UIImage {
        onImage(image)
      }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      picker.dismiss(animated: true)
    }
  }
}

#Preview("Auto-Trace Lab") {
  NavigationStack {
    AutoTraceLab()
      .navigationTitle(Text(verbatim: "Auto-Trace Lab"))
      .navigationBarTitleDisplayMode(.inline)
  }
}

#endif
