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
    let image = request.image
    let zoom = request.zoom
    let rotation = request.rotation
    let offset = request.offset
    let detail = request.detail

    return await Task.detached(priority: .userInitiated) { () -> AutoTraceOutcome in
      guard
        let flattened = AutoTraceFlattener.flatten(
          image: image, zoom: zoom, rotation: rotation, offset: offset, canvasSize: canvasSize)
      else {
        return AutoTraceOutcome(strokes: [], usedSubjectIsolation: false)
      }

      let isolated = isolateSubject(in: flattened)
      let conditioned = condition(isolated.image) ?? isolated.image
      let contours = detectContours(in: conditioned, detail: detail, canvasSize: canvasSize)
      let strokes = AutoTraceVectorizer.vectorize(
        contours: contours, detail: detail, canvasSize: canvasSize)

      return AutoTraceOutcome(strokes: strokes, usedSubjectIsolation: isolated.didIsolate)
    }.value
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
  static func condition(_ image: CGImage) -> CGImage? {
    let source = CIImage(cgImage: image)

    let mono = CIFilter.colorControls()
    mono.inputImage = source
    mono.saturation = 0
    mono.contrast = 1.1
    guard let desaturated = mono.outputImage else { return nil }

    let blur = CIFilter.gaussianBlur()
    blur.inputImage = desaturated
    blur.radius = 1.5
    guard let blurred = blur.outputImage else { return nil }

    // Blurring grows the extent; crop back so coordinates stay normalized
    // against the original square.
    return context.createCGImage(blurred, from: source.extent)
  }

  // MARK: - Contour detection

  static func detectContours(
    in image: CGImage, detail: AutoTraceDetail, canvasSize: CGFloat = CANVAS_SIZE
  ) -> [AutoTraceContour] {
    let request = VNDetectContoursRequest()
    request.contrastAdjustment = detail.contrastAdjustment
    request.detectsDarkOnLight = true
    request.maximumImageDimension = Int(AutoTraceFlattener.renderSide)

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
        contour, depth: 0, maxDepth: detail.childDepth, epsilon: detail.polygonEpsilon,
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
