//
//  AutoTraceConfig.swift
//  Joodle
//
//  Every knob the auto-trace pipeline exposes, in one flat value. The shipping
//  path never constructs one of these directly — `AutoTraceDetail` maps each of
//  its three presets onto a config (see `init(detail:)`): the per-level values
//  come from the preset, and the shared defaults here (Canny edge extraction,
//  subject isolation, conditioning) apply to every level. The debug Auto-Trace
//  Lab is the one place that builds a free-form config and sweeps these values.
//

import Foundation

/// How the subject's lines are extracted before contour tracing.
///
/// `VNDetectContoursRequest` traces boundaries between light and dark *regions*,
/// so on its own it captures the silhouette but misses interior lines (a face's
/// features, folds, panel gaps) — those are *edges*, not closed regions. The
/// edge-map methods run a first-party edge detector first and hand Vision a
/// binary line image, so interior detail becomes traceable contours too.
enum AutoTraceEdgeMethod: String, CaseIterable, Identifiable, Equatable {
  /// Contour the conditioned photo directly. Silhouette-only — the original
  /// behaviour, kept as a fallback for comparison.
  case none
  /// `CICannyEdgeDetector` — the classic multi-stage edge detector. Best
  /// all-round interior-line fidelity, and the shipping default.
  case canny
  /// `CIEdges` — a cheap Sobel magnitude. Faster, blunter, noisier.
  case sobel
  /// `CILineOverlay` — Apple's built-in photo→sketch filter (Sobel + noise
  /// reduction). Produces the most "hand-drawn" lines.
  case lineOverlay

  var id: String { rawValue }

  var title: String {
    switch self {
    case .none: return "Region (silhouette)"
    case .canny: return "Canny edges"
    case .sobel: return "Sobel edges"
    case .lineOverlay: return "Line overlay (sketch)"
    }
  }
}

/// A complete, order-independent snapshot of the trace pipeline's tuning. Types
/// are the ergonomic ones for sliders (`Double`/`Int`/`Bool`); the engine casts
/// to Vision's `Float`/`CGFloat` at the point of use.
///
/// Defaults reproduce `.balanced`, so `AutoTraceConfig()` is a sane starting
/// point on its own.
struct AutoTraceConfig: Equatable {

  // MARK: - Subject isolation & source

  /// Whether to knock the background out with `VNGenerateForegroundInstanceMaskRequest`
  /// before contouring. Off traces the full frame — useful for seeing how much
  /// clutter isolation was actually removing.
  var useSubjectIsolation: Bool = true

  /// Side length, in pixels, of the square bitmap handed to Vision. Higher gives
  /// contour detection more to work with at a linear cost in time. Also fed to
  /// the request's `maximumImageDimension` so Vision doesn't resample it again.
  var renderSide: Double = 640

  // MARK: - Conditioning

  /// Saturation before contouring. 0 desaturates fully — colour rarely helps an
  /// edge finder and often invents contours along hue boundaries.
  var conditionSaturation: Double = 0

  /// Contrast bump applied during conditioning (distinct from Vision's own
  /// `contrastAdjustment` below — this one is a plain CIColorControls pass).
  var conditionContrast: Double = 1.1

  /// Gaussian blur radius before contouring. The single most important denoise
  /// knob: too low and fabric weave / skin / sensor noise register as contours;
  /// too high and the subject's real outline softens away. Applies only to the
  /// `.none` (region) path — the edge detectors do their own denoising.
  var blurRadius: Double = 1.5

  // MARK: - Edge extraction

  /// Which line-extraction strategy runs before contour tracing. Canny is the
  /// shipping default — it builds a binary edge map so interior lines are traced,
  /// not just the silhouette. `.none` falls back to the original region-contour
  /// behaviour.
  var edgeMethod: AutoTraceEdgeMethod = .canny

  /// `CICannyEdgeDetector.gaussianSigma` — pre-blur that sets the finest edge
  /// scale. Higher ignores fine texture, keeps only bold lines.
  var cannyGaussianSigma: Double = 5.0

  /// Canny weak-edge threshold. Edges above this survive only if connected to a
  /// strong edge (hysteresis).
  var cannyThresholdLow: Double = 0.0935

  /// Canny strong-edge threshold. Edges above this are always kept.
  var cannyThresholdHigh: Double = 0.0554

  /// Canny hysteresis passes (0...20) promoting weak edges connected to strong
  /// ones. More passes = more continuous lines.
  var cannyHysteresisPasses: Int = 1

  /// `CIEdges.intensity` for the Sobel method. Higher surfaces fainter edges.
  var sobelEdgeIntensity: Double = 2.0

  /// `CILineOverlay.nrNoiseLevel` — noise removed before edge tracing.
  var lineNoiseLevel: Double = 0.07
  /// `CILineOverlay.nrSharpness` — sharpening during noise reduction.
  var lineSharpness: Double = 0.71
  /// `CILineOverlay.edgeIntensity` — Sobel accentuation; low values (~1) are
  /// typical.
  var lineEdgeIntensity: Double = 1.0
  /// `CILineOverlay.threshold` — edge visibility cutoff.
  var lineThreshold: Double = 0.1
  /// `CILineOverlay.contrast` — edge contrast / antialiasing.
  var lineContrast: Double = 50

  /// Morphological dilation radius applied to the edge map to close small gaps
  /// so broken lines trace as continuous contours. 0 disables it.
  var edgeDilation: Double = 0

  /// Whether to binarize the edge map with Otsu's automatic threshold. When
  /// false, `binaryThreshold` is used as a fixed cutoff.
  var useOtsuThreshold: Bool = true

  /// Fixed binarization cutoff for the edge map when `useOtsuThreshold` is off.
  var binaryThreshold: Double = 0.5

  // MARK: - Vision contour detection

  /// `VNDetectContoursRequest.contrastAdjustment`. Higher collapses soft
  /// gradients into nothing, leaving only strong outlines.
  var contrastAdjustment: Double = 2.0

  /// How deep into `VNContour.childContours` the walk descends (interior detail
  /// inside an outline). 0 keeps silhouettes only.
  var childDepth: Int = 1

  /// Epsilon for `VNContour.polygonApproximation(epsilon:)`, in normalized
  /// (0...1) space. Larger = blunter corners, fewer vertices.
  var polygonEpsilon: Double = 0.003

  // MARK: - Vectorization

  /// Spacing, in canvas points, that surviving contours are resampled to.
  /// Smaller = smoother curves, since the renderer draws straight segments and
  /// does no smoothing of its own.
  var resampleSpacing: Double = 2.5

  /// Minimum contour perimeter to keep, as a fraction of the canvas perimeter
  /// (`4 * canvasSize`). Below this a contour is noise, not a line.
  var minPerimeterFraction: Double = 0.025

  /// Hard ceiling on emitted strokes. Contours are ranked longest-first, so the
  /// budget spends itself on structure.
  var maxStrokes: Int = 120

  /// Hard ceiling on total emitted points across all strokes — the guard that
  /// keeps `DayEntry.drawingData` (JSON, mirrored to the widget) from bloating.
  var maxPoints: Int = 2500
}

extension AutoTraceConfig {

  /// The config a shipping detail preset expands to. Copies each preset's
  /// per-level values verbatim (child depth, epsilon, spacing, budgets) and
  /// inherits the shared defaults for everything else — edge extraction
  /// (Canny), subject isolation, conditioning — from the memberwise init.
  init(detail: AutoTraceDetail) {
    self.init()
    contrastAdjustment = Double(detail.contrastAdjustment)
    childDepth = detail.childDepth
    polygonEpsilon = Double(detail.polygonEpsilon)
    resampleSpacing = Double(detail.resampleSpacing)
    minPerimeterFraction = Double(detail.minPerimeterFraction)
    maxStrokes = detail.maxStrokes
    maxPoints = detail.maxPoints
  }

#if DEBUG
  /// A paste-ready dump for the Auto-Trace Lab's Export button. Valid Swift plus
  /// a comment on every field saying where its value lives in-code, so the whole
  /// block can be handed back verbatim to update the presets and engine
  /// constants.
  var swiftLiteral: String {
    func f(_ value: Double, _ places: Int = 4) -> String {
      String(format: "%.\(places)f", value)
    }
    return """
      // Auto-trace tuning — exported from the Auto-Trace Lab.
      // Per-level fields map to AutoTraceDetail.<the level you tuned>;
      // isolation / renderSide / conditioning map to AutoTraceEngine + AutoTraceFlattener.
      AutoTraceConfig(
        // → AutoTraceEngine.trace / AutoTraceFlattener.renderSide
        useSubjectIsolation: \(useSubjectIsolation),
        renderSide: \(f(renderSide, 0)),
        // → AutoTraceEngine.condition(_:config:)
        conditionSaturation: \(f(conditionSaturation)),
        conditionContrast: \(f(conditionContrast)),
        blurRadius: \(f(blurRadius, 2)),
        // → AutoTraceEngine.preprocess / AutoTraceEdges
        edgeMethod: .\(edgeMethod.rawValue),
        cannyGaussianSigma: \(f(cannyGaussianSigma, 2)),
        cannyThresholdLow: \(f(cannyThresholdLow)),
        cannyThresholdHigh: \(f(cannyThresholdHigh)),
        cannyHysteresisPasses: \(cannyHysteresisPasses),
        sobelEdgeIntensity: \(f(sobelEdgeIntensity, 2)),
        lineNoiseLevel: \(f(lineNoiseLevel)),
        lineSharpness: \(f(lineSharpness, 2)),
        lineEdgeIntensity: \(f(lineEdgeIntensity, 2)),
        lineThreshold: \(f(lineThreshold)),
        lineContrast: \(f(lineContrast, 1)),
        edgeDilation: \(f(edgeDilation, 1)),
        useOtsuThreshold: \(useOtsuThreshold),
        binaryThreshold: \(f(binaryThreshold, 2)),
        // → AutoTraceDetail.contrastAdjustment
        contrastAdjustment: \(f(contrastAdjustment, 2)),
        // → AutoTraceDetail.childDepth
        childDepth: \(childDepth),
        // → AutoTraceDetail.polygonEpsilon
        polygonEpsilon: \(f(polygonEpsilon)),
        // → AutoTraceDetail.resampleSpacing
        resampleSpacing: \(f(resampleSpacing, 2)),
        // → AutoTraceDetail.minPerimeterFraction
        minPerimeterFraction: \(f(minPerimeterFraction)),
        // → AutoTraceDetail.maxStrokes
        maxStrokes: \(maxStrokes),
        // → AutoTraceDetail.maxPoints
        maxPoints: \(maxPoints)
      )
      """
  }
#endif
}
