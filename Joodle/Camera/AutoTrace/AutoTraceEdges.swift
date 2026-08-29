//
//  AutoTraceEdges.swift
//  Joodle
//
//  Edge-map preprocessing for auto-trace. `VNDetectContoursRequest` traces
//  boundaries between light and dark *regions*, so on the raw photo it captures
//  the silhouette but misses interior lines — those are gradient *edges*, not
//  closed regions. Running a first-party edge detector first and handing Vision
//  a binary line image is the standard "photo → line art" fix (Canny / Sobel /
//  DoG-XDoG pipelines all work this way): interior detail becomes its own set of
//  contours.
//
//  The output is normalized to DARK lines on WHITE so it drops straight into the
//  existing contour pass, which runs with `detectsDarkOnLight = true`.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum AutoTraceEdges {

  private static let context = CIContext(options: [.useSoftwareRenderer: false])

  /// The raw edge image for `config.edgeMethod`, as white lines on black — the
  /// natural output of the detectors, before dilation / binarization / polarity.
  /// Surfaced separately so the debug lab can show it as its own stage.
  static func rawEdges(_ cgImage: CGImage, config: AutoTraceConfig) -> CGImage? {
    let source = CIImage(cgImage: cgImage)
    guard let edges = rawEdgeImage(source, config: config) else { return nil }
    let cropped = edges.cropped(to: source.extent)
    return context.createCGImage(cropped, from: source.extent)
  }

  /// The Vision-ready edge map: dark lines on white, after optional gap-closing
  /// dilation and binarization. `nil` for `.none`, which has no edge map.
  static func edgeMap(_ cgImage: CGImage, config: AutoTraceConfig) -> CGImage? {
    let source = CIImage(cgImage: cgImage)
    guard var edges = rawEdgeImage(source, config: config) else { return nil }
    edges = edges.cropped(to: source.extent)

    // Grow bright lines to bridge small breaks so a dashed edge traces as one
    // contour rather than a string of specks.
    if config.edgeDilation > 0 {
      let dilate = CIFilter.morphologyMaximum()
      dilate.inputImage = edges
      dilate.radius = Float(config.edgeDilation)
      if let out = dilate.outputImage { edges = out.cropped(to: source.extent) }
    }

    // Binarize to crisp 0/1 lines.
    if config.useOtsuThreshold {
      let otsu = CIFilter.colorThresholdOtsu()
      otsu.inputImage = edges
      if let out = otsu.outputImage { edges = out }
    } else {
      let threshold = CIFilter.colorThreshold()
      threshold.inputImage = edges
      threshold.threshold = Float(config.binaryThreshold)
      if let out = threshold.outputImage { edges = out }
    }

    // White-on-black → dark-on-white for the dark-on-light contour pass.
    let invert = CIFilter.colorInvert()
    invert.inputImage = edges
    guard let inverted = invert.outputImage else { return nil }

    return context.createCGImage(inverted, from: source.extent)
  }

  // MARK: - Detectors

  /// Runs the selected detector and returns white-lines-on-black in the source's
  /// coordinate space. Each branch normalizes to that convention so `edgeMap`'s
  /// dilation/threshold/invert tail is method-agnostic.
  private static func rawEdgeImage(_ source: CIImage, config: AutoTraceConfig) -> CIImage? {
    switch config.edgeMethod {
    case .none:
      return nil

    case .canny:
      let canny = CIFilter.cannyEdgeDetector()
      canny.inputImage = source
      canny.gaussianSigma = Float(config.cannyGaussianSigma)
      canny.perceptual = false
      canny.thresholdLow = Float(config.cannyThresholdLow)
      canny.thresholdHigh = Float(config.cannyThresholdHigh)
      canny.hysteresisPasses = Int(config.cannyHysteresisPasses)
      // Already white-on-black.
      return canny.outputImage

    case .sobel:
      let edges = CIFilter.edges()
      edges.inputImage = grayscale(source)
      edges.intensity = Float(config.sobelEdgeIntensity)
      guard let out = edges.outputImage else { return nil }
      // Sobel output is coloured bright edges on dark; desaturate to luma so the
      // threshold tail sees a clean grayscale line image.
      return grayscale(out)

    case .lineOverlay:
      let overlay = CIFilter.lineOverlay()
      overlay.inputImage = source
      overlay.nrNoiseLevel = Float(config.lineNoiseLevel)
      overlay.nrSharpness = Float(config.lineSharpness)
      overlay.edgeIntensity = Float(config.lineEdgeIntensity)
      overlay.threshold = Float(config.lineThreshold)
      overlay.contrast = Float(config.lineContrast)
      guard let out = overlay.outputImage else { return nil }
      // Line overlay draws dark lines on a transparent field. Flatten over white
      // (dark-on-white), then invert to the white-on-black convention this
      // function returns.
      let white = CIImage(color: .white).cropped(to: source.extent)
      let composited = out.composited(over: white)
      let invert = CIFilter.colorInvert()
      invert.inputImage = composited
      return invert.outputImage
    }
  }

  private static func grayscale(_ image: CIImage) -> CIImage {
    let mono = CIFilter.colorControls()
    mono.inputImage = image
    mono.saturation = 0
    return mono.outputImage ?? image
  }
}
