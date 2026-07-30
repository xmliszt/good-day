//
//  ReferencePhotoImporter.swift
//  Joodle
//
//  Turns raw image data picked from the user's album into a tracing-reference
//  backdrop, matching what a live capture produces: an upright, centre-cropped,
//  downsampled square.
//

import CoreGraphics
import ImageIO
import UIKit

enum ReferencePhotoImporter {
  /// Long-side budget for an imported reference, matching the capture path's
  /// backdrop. The reference is drawn at 30% opacity into a canvas a few hundred
  /// points wide, so 1024px is already well past what the tracing overlay can
  /// show — and keeping the bitmap small matters twice over, because every
  /// zoom / rotate / offset of the adjust controls recomposites it.
  static let maxPixelDimension = 1024

  /// Loads `data` into a backdrop-ready square, off the main thread. A nil
  /// `data` (the picker transfer failed) is just a failed import, so it passes
  /// straight through as nil rather than making every caller pre-check.
  ///
  /// The decode has to stay off-main: this used to run `UIImage(data:)` through
  /// two full-resolution `UIGraphicsImageRenderer` passes on the main actor —
  /// one to bake in the EXIF orientation, one to crop — which for a 12MP shot
  /// meant a 48MB bitmap followed by a 36MB one (and ~4x that for 48MP),
  /// freezing the canvas for as long as it took.
  static func squareReference(from data: Data?) async -> UIImage? {
    guard let data else { return nil }
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: decodeSquare(from: data))
      }
    }
  }

  /// Synchronous decode. Stateless and CPU-only, so it can run on any queue —
  /// call it OFF the main thread.
  ///
  /// ImageIO subsamples straight from the source at the reduced size and applies
  /// the orientation transform in the same pass, so no full-resolution bitmap is
  /// ever materialised; the crop is then a free `CGImage` window over it.
  private static func decodeSquare(from data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      // Always resample the full image: an embedded EXIF thumbnail would be
      // far too small and soft to trace against.
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
    ]
    guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    let side = min(scaled.width, scaled.height)
    guard side > 0 else { return nil }
    let cropRect = CGRect(
      x: (scaled.width - side) / 2,
      y: (scaled.height - side) / 2,
      width: side,
      height: side
    )
    guard let cropped = scaled.cropping(to: cropRect) else { return nil }
    // Already upright thanks to `kCGImageSourceCreateThumbnailWithTransform`,
    // and in pixels, so the backdrop's `scaledToFill` sees the square as-is.
    return UIImage(cgImage: cropped, scale: 1, orientation: .up)
  }
}
