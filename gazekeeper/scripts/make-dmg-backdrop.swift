import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The DMG window backdrop: the site's eye chart, as two lines framing the
// drag. Written as a two-image TIFF (1x and 2x) so Finder picks the sharp
// one on Retina displays instead of showing a 2x PNG at double size.

let points = CGSize(width: 640, height: 430)
let fontURL = URL(fileURLWithPath: CommandLine.arguments[0])
  .deletingLastPathComponent().appendingPathComponent("../Resources/OpticianSans.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)

let ink = CGColor(srgbRed: 0.055, green: 0.067, blue: 0.063, alpha: 1)
let faint = CGColor(srgbRed: 0.055, green: 0.067, blue: 0.063, alpha: 0.45)
let teal = CGColor(srgbRed: 0.055, green: 0.486, blue: 0.447, alpha: 1)

func render(scale: CGFloat) -> CGImage {
  let context = CGContext(
    data: nil, width: Int(points.width * scale), height: Int(points.height * scale),
    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.scaleBy(x: scale, y: scale)
  // Top-left origin, matching Finder's icon coordinates.
  context.translateBy(x: 0, y: points.height)
  context.scaleBy(x: 1, y: -1)

  context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
  context.fill(CGRect(origin: .zero, size: points))

  func text(
    _ string: String, font: String, size: CGFloat, color: CGColor, kern: CGFloat = 0,
    x: CGFloat, baseline: CGFloat, align: CGFloat = 0
  ) {
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String):
        CTFontCreateWithName(font as CFString, size, nil),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
      NSAttributedString.Key(kCTKernAttributeName as String): kern,
    ]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: string, attributes: attributes))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: x - CGFloat(width) * align, y: baseline)
    CTLineDraw(line, context)
    context.restoreGState()
  }

  let left: CGFloat = 40
  let right = points.width - 40

  text("1", font: "Menlo", size: 10, color: faint, x: left, baseline: 72)
  text("GAZEKEEPER", font: "OpticianSans-Regular", size: 34, color: ink, kern: 7,
    x: points.width / 2 + 3.5, baseline: 74, align: 0.5)
  text("20/200", font: "Menlo", size: 10, color: faint, x: right, baseline: 72, align: 1)

  // The drag: a hairline with a teal head, between the two icon slots.
  context.setStrokeColor(faint)
  context.setLineWidth(1)
  context.move(to: CGPoint(x: 262, y: 250))
  context.addLine(to: CGPoint(x: 374, y: 250))
  context.strokePath()
  context.setStrokeColor(teal)
  context.setLineWidth(1.5)
  context.setLineCap(.round)
  context.setLineJoin(.round)
  context.move(to: CGPoint(x: 368, y: 244))
  context.addLine(to: CGPoint(x: 376, y: 250))
  context.addLine(to: CGPoint(x: 368, y: 256))
  context.strokePath()

  text("2", font: "Menlo", size: 10, color: teal, x: left, baseline: 382)
  text("DRAG TO APPLICATIONS", font: "OpticianSans-Regular", size: 11, color: ink, kern: 3.2,
    x: points.width / 2 + 1.6, baseline: 383, align: 0.5)
  text("20/20", font: "Menlo", size: 10, color: teal, x: right, baseline: 382, align: 1)
  context.setFillColor(teal)
  context.fill(CGRect(x: left, y: 392, width: right - left, height: 1))

  return context.makeImage()!
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(
  outputURL as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
for scale: CGFloat in [1, 2] {
  let dpi = 72 * scale
  CGImageDestinationAddImage(
    destination, render(scale: scale),
    [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
}
CGImageDestinationFinalize(destination)
print("wrote \(outputURL.path)")
