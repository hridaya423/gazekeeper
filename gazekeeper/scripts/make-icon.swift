import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let scale: CGFloat = 1
let context = CGContext(
  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let s = CGFloat(size)
let tileRect = CGRect(x: 0, y: 0, width: s, height: s)

let tileColors = [
  CGColor(srgbRed: 0.075, green: 0.07, blue: 0.09, alpha: 1),
  CGColor(srgbRed: 0.045, green: 0.04, blue: 0.055, alpha: 1),
]
context.saveGState()
let clip = CGPath(
  roundedRect: tileRect, cornerWidth: s * 0.224, cornerHeight: s * 0.224, transform: nil)
context.addPath(clip)
context.clip()
context.drawLinearGradient(
  CGGradient(colorsSpace: nil, colors: tileColors as CFArray, locations: [0, 1])!,
  start: CGPoint(x: s / 2, y: s),
  end: CGPoint(x: s / 2, y: 0),
  options: [])
context.restoreGState()

let center = CGPoint(x: s * 0.5, y: s * 0.5)
let ringRadius = s * 0.30
let ringWidth = s * 0.085

context.saveGState()
context.setShadow(
  offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.05,
  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
context.setStrokeColor(CGColor(srgbRed: 0.16, green: 0.15, blue: 0.19, alpha: 1))
context.setLineWidth(ringWidth)
context.setLineCap(.round)
context.addArc(
  center: center, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
context.strokePath()
context.restoreGState()

let gradientColors = [
  CGColor(srgbRed: 0.176, green: 0.831, blue: 0.749, alpha: 1),
  CGColor(srgbRed: 0.078, green: 0.722, blue: 0.651, alpha: 1),
  CGColor(srgbRed: 0.059, green: 0.463, blue: 0.431, alpha: 1),
]
let gradient = CGGradient(
  colorsSpace: nil, colors: gradientColors as CFArray, locations: [0, 0.55, 1])!

let arcStart = CGFloat.pi * 0.35
let arcEnd = CGFloat.pi * 2.28
let arcPath = CGMutablePath()
arcPath.addArc(
  center: center, radius: ringRadius, startAngle: arcStart, endAngle: arcEnd, clockwise: false)
let stroked = arcPath.copy(
  strokingWithWidth: ringWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
context.addPath(stroked)
context.clip()
context.drawLinearGradient(
  gradient,
  start: CGPoint(x: s * 0.2, y: s * 0.75),
  end: CGPoint(x: s * 0.8, y: s * 0.25),
  options: [])
context.resetClip()

let glowRadius = s * 0.06
context.saveGState()
context.setShadow(
  offset: .zero, blur: glowRadius,
  color: CGColor(srgbRed: 0.176, green: 0.831, blue: 0.749, alpha: 0.55))
context.setFillColor(CGColor(srgbRed: 0.176, green: 0.831, blue: 0.749, alpha: 1))
let dotRect = CGRect(
  x: center.x - s * 0.062, y: center.y - s * 0.062, width: s * 0.124, height: s * 0.124)
context.fillEllipse(in: dotRect)
context.restoreGState()

let dotGradientColors = [
  CGColor(srgbRed: 0.369, green: 0.918, blue: 0.831, alpha: 1),
  CGColor(srgbRed: 0.176, green: 0.831, blue: 0.749, alpha: 1),
]
let dotGradient = CGGradient(
  colorsSpace: nil, colors: dotGradientColors as CFArray, locations: [0, 1])!
let dotClip = CGPath(ellipseIn: dotRect, transform: nil)
context.saveGState()
context.addPath(dotClip)
context.clip()
context.drawLinearGradient(
  dotGradient,
  start: CGPoint(x: dotRect.minX, y: dotRect.maxY),
  end: CGPoint(x: dotRect.maxX, y: dotRect.minY),
  options: [])
context.restoreGState()

let highlight = CGRect(
  x: s * 0.12, y: s * 0.62, width: s * 0.76, height: s * 0.30)
context.saveGState()
let highlightClip = CGPath(
  roundedRect: tileRect, cornerWidth: s * 0.224, cornerHeight: s * 0.224, transform: nil)
context.addPath(highlightClip)
context.clip()
let highlightColors = [
  CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06),
  CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
]
context.drawLinearGradient(
  CGGradient(colorsSpace: nil, colors: highlightColors as CFArray, locations: [0, 1])!,
  start: CGPoint(x: s * 0.5, y: s),
  end: CGPoint(x: s * 0.5, y: s * 0.45),
  options: [])
context.restoreGState()

let image = context.makeImage()!
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(
  outputURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("wrote \(outputURL.path)")
