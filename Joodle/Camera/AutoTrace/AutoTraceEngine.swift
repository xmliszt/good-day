//
//  AutoTraceEngine.swift
//  Joodle
//
//  Converts a positioned reference photo into doodle strokes, entirely
//  on-device.
//
//  Approach, and why:
//
//  • `VNDetectContoursRequest` (Vision, iOS 14+) does the heavy lifting. It
//    finds edges AND returns them already vectorized as polylines, AND offers
//    Ramer–Douglas–Peucker simplification — the three steps a hand-rolled Canny
//    + Moore-neighbourhood tracer would need, in one first-party call. Our
//    deployment floor is iOS 17.5, so every supported device gets this. It needs
//    no model download, no network, and no Apple Intelligence.
//
//  • `VNGenerateForegroundInstanceMaskRequest` (iOS 17+) is layered on top
//    opportunistically to knock the background out before contouring, because
//    background clutter is the main thing that turns a trace into spaghetti. It
//    is never required: if the device is slow, the model is unavailable, or the
//    photo has no clear subject (landscapes, flat-lays), it fails softly and the
//    contour pass runs on the full frame. Quality tiering, not availability
//    tiering — there is no device on which the feature stops working.
//
//  • Apple Intelligence / the Foundation Models framework is deliberately NOT
//    used. It is iOS 26+ (image attachments iOS 27+), runtime-gated by
//    `SystemLanguageModel.availability`, and fundamentally a *text* model —
//    emitting a couple of thousand accurate 2-D coordinates token by token would
//    be slow, context-bounded and geometrically unfaithful. Image Playground was
//    rejected for a different reason: it reimagines a photo rather than tracing
//    it, and hands back a raster that would still need vectorizing.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import Vision

struct AutoTraceRequest {
  let image: UIImage
  let zoom: CGFloat
  let rotation: Angle
  let offset: CGSize
  let detail: AutoTraceDetail
}

/// A finished trace handed from the camera context to the canvas.
///
/// Identity is a fresh `id` per result rather than the stroke contents, so
/// re-tracing at the same level with the same framing still registers as a new
/// result for `onChange` — the user pressed the button again and expects
/// something to happen.
struct AutoTraceResult: Identifiable, Equatable {
  let id = UUID()
  let strokes: [PathData]
  let detail: AutoTraceDetail

  static func == (lhs: AutoTraceResult, rhs: AutoTraceResult) -> Bool {
    lhs.id == rhs.id
  }
}

struct AutoTraceOutcome {
  let strokes: [PathData]
  /// Whether subject isolation actually contributed. Surfaced for analytics and
  /// debugging only — the user-visible behaviour is identical either way.
  let usedSubjectIsolation: Bool
}

enum AutoTraceEngine {

  private static let context = CIContext(options: [.useSoftwareRenderer: false])

  /// Runs the full pipeline off the main actor and returns stroke data in canvas
  /// coordinates. Returns an outcome with no strokes when the photo yields
  /// nothing worth drawing — a blank wall, say — which callers surface rather
  /// than treating as an error.
  static func trace(_ request: AutoTraceRequest, canvasSize: CGFloat = CANVAS_SIZE) async
    -> AutoTraceOutcome
  {
    await trace(request, config: AutoTraceConfig(detail: request.detail), canvasSize: canvasSize)
  }

  /// Runs the pipeline with an explicit, free-form config rather than one of the
  /// three presets. `request.detail` is ignored — the config carries every knob.
  /// The debug Auto-Trace Lab drives this; the preset entry point above funnels
  /// into it via `AutoTraceConfig(detail:)`.
  static func trace(
    _ request: AutoTraceRequest, config: AutoTraceConfig, canvasSize: CGFloat = CANVAS_SIZE
  ) async -> AutoTraceOutcome {
    let image = request.image
    let zoom = request.zoom
    let rotation = request.rotation
    let offset = request.offset

    return await Task.detached(priority: .userInitiated) { () -> AutoTraceOutcome in
      guard
        let flattened = AutoTraceFlattener.flatten(
          image: image, zoom: zoom, rotation: rotation, offset: offset, canvasSize: canvasSize,
          side: CGFloat(config.renderSide))
      else {
        return AutoTraceOutcome(strokes: [], usedSubjectIsolation: false)
      }

      let isolated = config.useSubjectIsolation ? isolateSubject(in: flattened) : (flattened, false)
      let preprocessed = preprocess(isolated.0, config: config) ?? isolated.0
      let contours = detectContours(in: preprocessed, config: config, canvasSize: canvasSize)
      let strokes = AutoTraceVectorizer.vectorize(
        contours: contours, config: config, canvasSize: canvasSize)

      return AutoTraceOutcome(strokes: strokes, usedSubjectIsolation: isolated.1)
    }.value
  }

  // MARK: - Preprocessing

  /// The image handed to the contour pass. For `.none` this is the desaturated,
  /// blurred photo (silhouette tracing); for the edge methods it is a binary
  /// edge map (dark lines on white) so interior lines are traced too.
  static func preprocess(_ image: CGImage, config: AutoTraceConfig) -> CGImage? {
    switch config.edgeMethod {
    case .none:
      return condition(image, config: config)
    case .canny, .sobel, .lineOverlay:
      return AutoTraceEdges.edgeMap(image, config: config)
    }
  }

  // MARK: - Subject isolation (optional)

  /// Composites the photo's foreground subject over flat white so the contour
  /// pass sees the subject and nothing else. Returns the input untouched
  /// whenever isolation isn't possible — every failure here is expected and
  /// silent.
  static func isolateSubject(in image: CGImage) -> (image: CGImage, didIsolate: Bool) {
    guard #available(iOS 17.0, *) else { return (image, false) }

    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
      guard let observation = request.results?.first,
        !observation.allInstances.isEmpty
      else {
        return (image, false)
      }

      let maskBuffer = try observation.generateScaledMaskForImage(
        forInstances: observation.allInstances, from: handler)
      let mask = CIImage(cvPixelBuffer: maskBuffer)
      let source = CIImage(cgImage: image)

      let blend = CIFilter.blendWithMask()
      blend.inputImage = source
      blend.backgroundImage = CIImage(color: .white).cropped(to: source.extent)
      blend.maskImage = mask.transformed(
        by: CGAffineTransform(
          scaleX: source.extent.width / max(mask.extent.width, 1),
          y: source.extent.height / max(mask.extent.height, 1)))

      guard let output = blend.outputImage,
        let rendered = context.createCGImage(output, from: source.extent)
      else {
        return (image, false)
      }
      return (rendered, true)
    } catch {
      return (image, false)
    }
  }

  // MARK: - Conditioning

  /// Desaturates and softens the image before contour detection. The blur is the
  /// important part: without it, fabric weave, skin texture and sensor noise all
  /// register as contours and bury the subject's actual outline.
  static func condition(_ image: CGImage, config: AutoTraceConfig) -> CGImage? {
    let source = CIImage(cgImage: image)

    let mono = CIFilter.colorControls()
    mono.inputImage = source
    mono.saturation = Float(config.conditionSaturation)
    mono.contrast = Float(config.conditionContrast)
    guard let desaturated = mono.outputImage else { return nil }

    let blur = CIFilter.gaussianBlur()
    blur.inputImage = desaturated
    blur.radius = Float(config.blurRadius)
    guard let blurred = blur.outputImage else { return nil }

    // Blurring grows the extent; crop back so coordinates stay normalized
    // against the original square.
    return context.createCGImage(blurred, from: source.extent)
  }

  // MARK: - Contour detection

  static func detectContours(
    in image: CGImage, config: AutoTraceConfig, canvasSize: CGFloat = CANVAS_SIZE
  ) -> [AutoTraceContour] {
    let request = VNDetectContoursRequest()
    request.contrastAdjustment = Float(config.contrastAdjustment)
    request.detectsDarkOnLight = true
    request.maximumImageDimension = Int(config.renderSide)

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return []
    }

    guard let observation = request.results?.first else { return [] }

    var collected: [AutoTraceContour] = []
    for contour in observation.topLevelContours {
      collect(
        contour, depth: 0, maxDepth: config.childDepth, epsilon: Float(config.polygonEpsilon),
        canvasSize: canvasSize, into: &collected)
    }
    return collected
  }

  /// Walks the contour tree to `maxDepth`, simplifying each contour as it goes.
  /// Child contours are the interior detail — the holes inside an outline — so
  /// descending is what separates a silhouette from a drawing with features in
  /// it.
  ///
  /// The image frame does not count as a level. Vision reports the bitmap's own
  /// boundary as the outermost contour *and* reports its inner lip as that
  /// contour's only child, so the photo's actual content does not begin until
  /// depth 2. Letting those two artificial levels consume the depth budget would
  /// mean `.simple` never sees anything at all and `.detailed` sees only a
  /// silhouette. Border contours are therefore skipped and their children
  /// inherit the same depth, so `maxDepth` counts levels of real interior detail
  /// — which is what the presets describe.
  private static func collect(
    _ contour: VNContour,
    depth: Int,
    maxDepth: Int,
    epsilon: Float,
    canvasSize: CGFloat,
    into collected: inout [AutoTraceContour]
  ) {
    let simplified = (try? contour.polygonApproximation(epsilon: epsilon)) ?? contour
    let points = simplified.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }

    let isBorder = AutoTraceVectorizer.isImageBorder(
      AutoTraceVectorizer.canvasPoints(fromNormalized: points, canvasSize: canvasSize),
      canvasSize: canvasSize)

    if !isBorder, points.count >= 2 {
      collected.append(AutoTraceContour(normalizedPoints: points, depth: depth))
    }

    let childDepth = isBorder ? depth : depth + 1
    guard childDepth <= maxDepth else { return }
    for child in contour.childContours {
      collect(
        child, depth: childDepth, maxDepth: maxDepth, epsilon: epsilon, canvasSize: canvasSize,
        into: &collected)
    }
  }
}

#if DEBUG

/// One captured intermediate from a trace, for the Auto-Trace Lab's step-by-step
/// view. `@unchecked Sendable` so the whole result can cross the detached-task
/// boundary — `UIImage` is safe to read across threads once built.
struct AutoTraceStage: Identifiable, @unchecked Sendable {
  let id = UUID()
  let title: String
  let subtitle: String
  let image: UIImage
}

struct AutoTraceDebugResult: @unchecked Sendable {
  let outcome: AutoTraceOutcome
  let stages: [AutoTraceStage]
}

extension AutoTraceEngine {

  /// Re-runs the pipeline capturing every intermediate as an image, so the lab
  /// can show what each step produced. Reuses the exact primitives `trace`
  /// uses — only the orchestration differs, to snapshot between steps.
  static func debugStages(
    _ request: AutoTraceRequest, config: AutoTraceConfig, canvasSize: CGFloat = CANVAS_SIZE
  ) -> AutoTraceDebugResult {
    var stages: [AutoTraceStage] = []

    guard
      let flattened = AutoTraceFlattener.flatten(
        image: request.image, zoom: request.zoom, rotation: request.rotation,
        offset: request.offset, canvasSize: canvasSize, side: CGFloat(config.renderSide))
    else {
      return AutoTraceDebugResult(
        outcome: AutoTraceOutcome(strokes: [], usedSubjectIsolation: false), stages: stages)
    }
    stages.append(
      AutoTraceStage(
        title: "Flattened", subtitle: "WYSIWYG crop → \(Int(config.renderSide))px",
        image: UIImage(cgImage: flattened)))

    let isolated = config.useSubjectIsolation ? isolateSubject(in: flattened) : (flattened, false)
    stages.append(
      AutoTraceStage(
        title: "Subject", subtitle: isolated.1 ? "isolated" : "not isolated",
        image: UIImage(cgImage: isolated.0)))

    // Preprocessing — the step that differs by edge method.
    if config.edgeMethod == .none {
      if let conditioned = condition(isolated.0, config: config) {
        stages.append(
          AutoTraceStage(
            title: "Conditioned", subtitle: "desaturate + blur \(String(format: "%.1f", config.blurRadius))",
            image: UIImage(cgImage: conditioned)))
      }
    } else {
      if let raw = AutoTraceEdges.rawEdges(isolated.0, config: config) {
        stages.append(
          AutoTraceStage(
            title: "Raw edges", subtitle: config.edgeMethod.title,
            image: UIImage(cgImage: raw)))
      }
      if let map = AutoTraceEdges.edgeMap(isolated.0, config: config) {
        stages.append(
          AutoTraceStage(
            title: "Edge map", subtitle: "binarized · dark-on-white",
            image: UIImage(cgImage: map)))
      }
    }

    let preprocessed = preprocess(isolated.0, config: config) ?? isolated.0
    let contours = detectContours(in: preprocessed, config: config, canvasSize: canvasSize)
    let strokes = AutoTraceVectorizer.vectorize(
      contours: contours, config: config, canvasSize: canvasSize)

    stages.append(
      AutoTraceStage(
        title: "Contours", subtitle: "\(contours.count) found",
        image: rasterizeStrokes(strokes, side: CGFloat(config.renderSide), canvasSize: canvasSize)))

    return AutoTraceDebugResult(
      outcome: AutoTraceOutcome(strokes: strokes, usedSubjectIsolation: isolated.1), stages: stages)
  }

  /// Draws stroke data (canvas coordinates) onto white as a preview thumbnail.
  private static func rasterizeStrokes(
    _ strokes: [PathData], side: CGFloat, canvasSize: CGFloat
  ) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
    let scale = side / canvasSize
    return renderer.image { ctx in
      let cg = ctx.cgContext
      cg.setFillColor(UIColor.white.cgColor)
      cg.fill(CGRect(x: 0, y: 0, width: side, height: side))
      cg.setStrokeColor(UIColor.label.cgColor)
      cg.setLineWidth(max(DRAWING_LINE_WIDTH * scale, 1))
      cg.setLineCap(.round)
      cg.setLineJoin(.round)
      for stroke in strokes {
        let points = stroke.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        guard let first = points.first else { continue }
        cg.beginPath()
        cg.move(to: first)
        for point in points.dropFirst() { cg.addLine(to: point) }
        cg.strokePath()
      }
    }
  }
}

#endif
