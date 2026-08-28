//
//  AutoTraceFlattener.swift
//  Joodle
//
//  Renders the positioned reference photo into a flat square bitmap — the exact
//  crop the user is looking at through the canvas, with their zoom, rotation and
//  offset already baked in.
//
//  This is what makes auto-trace WYSIWYG. The alternative — detect contours on
//  the raw photo and then push the results back through the inverse transform —
//  has to get the inverse exactly right, and still traces parts of the photo
//  that are outside the canvas. Flattening first makes "what you see is what you
//  trace" true by construction, for the cost of one draw call.
//

import CoreGraphics
import SwiftUI
import UIKit

enum AutoTraceFlattener {

  /// Side length of the bitmap handed to Vision. Above the canvas's own 342pt so
  /// contour detection has real pixels to work with, and matched to the
  /// `maximumImageDimension` the request is configured with so Vision doesn't
  /// resample it again.
  static let renderSide: CGFloat = 1024

  /// Rasterizes `image` through the current backdrop transform into a square
  /// bitmap of `side` points.
  ///
  /// The photo is drawn over opaque white for the same reason the canvas does:
  /// a rotated photo can leave the corners uncovered, and Vision's contour
  /// detector treats transparent pixels as black, which would draw a hard frame
  /// around the whole image and swamp the real subject.
  static func flatten(
    image: UIImage,
    zoom: CGFloat,
    rotation: Angle,
    offset: CGSize,
    canvasSize: CGFloat = CANVAS_SIZE,
    side: CGFloat = renderSide
  ) -> CGImage? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true

    let renderSize = CGSize(width: side, height: side)
    let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)

    let rendered = renderer.image { context in
      let cgContext = context.cgContext
      cgContext.setFillColor(UIColor.white.cgColor)
      cgContext.fill(CGRect(origin: .zero, size: renderSize))

      // Work in canvas points, then scale the whole thing up to the bitmap.
      let upscale = side / canvasSize
      cgContext.scaleBy(x: upscale, y: upscale)
      cgContext.concatenate(
        PhotoBackdropGeometry.backdropTransform(
          zoom: zoom, rotation: rotation, offset: offset, canvasSize: canvasSize))

      // `scaledToFill` on a square image into a square frame is a plain 1:1
      // fit, so the untransformed photo covers exactly the canvas square.
      image.draw(in: CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
    }

    return rendered.cgImage
  }
}
