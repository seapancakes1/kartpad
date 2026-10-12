#!/usr/bin/env bash
# Regenerates the macOS app icon from the iPhone/iPad red K artwork:
#   apple/ios/Assets.xcassets/AppIcon.appiconset/KartPadIcon-1024.png  (64 px and up)
#   apple/ios/Assets.xcassets/KartPadLogo.imageset/KartPadIcon-1024.png (16 and 32 px)
# The art sits in an 824x824 rounded-square body on a 1024 canvas with a soft
# drop shadow (the Big Sur icon grid). At 16 and 32 px the K is drawn larger
# and without its thin diagonal cut, so it stays legible.
# Writes branding/exports/macos/KartPadIcon-<size>.png and
# branding/exports/KartPad.icns. Needs only the Xcode toolchain (swiftc,
# iconutil).
set -euo pipefail
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
app_icon="${repo_root}/apple/ios/Assets.xcassets/AppIcon.appiconset/KartPadIcon-1024.png"
logo="${repo_root}/apple/ios/Assets.xcassets/KartPadLogo.imageset/KartPadIcon-1024.png"
exports="${repo_root}/branding/exports"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
iconset="${temporary}/KartPad.iconset"
mkdir -p "$iconset" "$exports/macos"

cat > "${temporary}/compose.swift" <<'SWIFT'
// Composes the macOS app icon from the iPhone/iPad red K artwork.
// usage: compose <AppIcon-1024.png> <KartPadLogo-1024.png> <output-dir>
// Writes KartPadIcon-<N>.png for N in 16 32 64 128 256 512 1024.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
  FileHandle.standardError.write("usage: compose AppIcon.png Logo.png output-dir\n".data(using: .utf8)!)
  exit(64)
}
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func load(_ path: String) -> CGImage {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        image.width == 1024, image.height == 1024 else {
    FileHandle.standardError.write("not a 1024x1024 image: \(path)\n".data(using: .utf8)!)
    exit(65)
  }
  return image
}

func rgba(_ image: CGImage) -> [UInt8] {
  var pixels = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
  let context = CGContext(data: &pixels, width: 1024, height: 1024, bitsPerComponent: 8,
                          bytesPerRow: 1024 * 4, space: sRGB,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
  return pixels
}

let appIcon = load(arguments[1])
let logo = load(arguments[2])
let outputDirectory = arguments[3]

// The AppIcon's flat background colour, read from its corner.
let iconPixels = rgba(appIcon)
let background = CGColor(colorSpace: sRGB, components: [
  CGFloat(iconPixels[0]) / 255, CGFloat(iconPixels[1]) / 255, CGFloat(iconPixels[2]) / 255, 1])!

// Small sizes: the K silhouette with the thin diagonal cut closed, so it stays
// one solid shape at 16 and 32 pixels.
func closedMarkMask() -> (CGImage, CGRect) {
  let logoPixels = rgba(logo)
  let side = 1024
  var mask = [UInt8](repeating: 0, count: side * side)
  for index in 0..<(side * side) { mask[index] = logoPixels[index * 4 + 3] }
  let radius = 22
  func filter(_ input: [UInt8], dilate: Bool, horizontal: Bool) -> [UInt8] {
    var output = input
    for row in 0..<side {
      for column in 0..<side {
        var value: UInt8 = dilate ? 0 : 255
        for offset in -radius...radius {
          let x = horizontal ? column + offset : column
          let y = horizontal ? row : row + offset
          let sample: UInt8 = (x < 0 || y < 0 || x >= side || y >= side) ? 0 : input[y * side + x]
          value = dilate ? max(value, sample) : min(value, sample)
        }
        output[row * side + column] = value
      }
    }
    return output
  }
  // Closing: dilate, then erode, with a 45-pixel square.
  var closed = filter(filter(mask, dilate: true, horizontal: true), dilate: true, horizontal: false)
  closed = filter(filter(closed, dilate: false, horizontal: true), dilate: false, horizontal: false)
  var minX = side, maxX = 0, minY = side, maxY = 0
  for y in 0..<side { for x in 0..<side where closed[y * side + x] > 127 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
  } }
  let provider = CGDataProvider(data: Data(closed) as CFData)!
  // A greyscale image (not an image mask): white paints when used as a clip mask.
  let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8,
                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: true,
                      intent: .defaultIntent)!
  // Bounds in CoreGraphics coordinates (origin bottom-left).
  let bounds = CGRect(x: minX, y: side - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
  return (image, bounds)
}

// macOS (Big Sur and later) icon grid: an 824x824 rounded-square body centred
// on a 1024 canvas, with continuous ("squircle") corners of radius 185.4.
func bodyPath(_ rect: CGRect) -> CGPath {
  let radius = min(185.4, min(rect.width, rect.height) / 2 / 1.52866483)
  // One corner, from the start of the curve on one edge to its end on the
  // other, in units of the radius measured inward from the corner point.
  let segments: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (1.08849323, 0, 0.86840689, 0, 0.66993427, 0.06549600),
    (0.63149399, 0.07491100, 0.63149399, 0.07491100, 0.63149399, 0.07491100),
    (0.37282392, 0.16905899, 0.16906013, 0.37282401, 0.07491100, 0.63149399),
    (0.06549600, 0.66993427, 0.06549600, 0.66993427, 0.06549600, 0.66993427),
    (0, 0.86840689, 0, 1.08849323, 0, 1.52866483),
  ]
  // Corners clockwise in a y-up space: top-left, top-right, bottom-right, bottom-left.
  // Each maps (along, across) offsets to a point; "along" runs toward the corner.
  let corners: [(CGFloat, CGFloat) -> CGPoint] = [
    { a, b in CGPoint(x: rect.minX + b * radius, y: rect.maxY - a * radius) },
    { a, b in CGPoint(x: rect.maxX - a * radius, y: rect.maxY - b * radius) },
    { a, b in CGPoint(x: rect.maxX - b * radius, y: rect.minY + a * radius) },
    { a, b in CGPoint(x: rect.minX + a * radius, y: rect.minY + b * radius) },
  ]
  let path = CGMutablePath()
  for (index, corner) in corners.enumerated() {
    let start = corner(1.52866483, 0)
    if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
    for segment in segments {
      path.addCurve(to: corner(segment.4, segment.5),
                    control1: corner(segment.0, segment.1),
                    control2: corner(segment.2, segment.3))
    }
  }
  path.closeSubpath()
  return path
}

let (markMask, markBounds) = closedMarkMask()
let markRed: CGColor = {
  let pixels = rgba(logo)
  // Sample the logo's red at the middle of the stem (row from the top).
  let index = (500 * 1024 + 300) * 4
  let alpha = max(CGFloat(pixels[index + 3]), 1)
  return CGColor(colorSpace: sRGB, components: [
    CGFloat(pixels[index]) / alpha, CGFloat(pixels[index + 1]) / alpha, CGFloat(pixels[index + 2]) / alpha, 1])!
}()

func render(pixels size: Int) -> CGImage {
  let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.interpolationQuality = .high
  context.setShouldAntialias(true)
  let scale = CGFloat(size) / 1024
  context.scaleBy(x: scale, y: scale)
  let body = CGRect(x: 100, y: 100, width: 824, height: 824)
  let path = bodyPath(body)

  // Soft drop shadow (offsets and blur are in device pixels).
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale,
                    color: CGColor(colorSpace: sRGB, components: [0, 0, 0, 0.3])!)
  context.addPath(path)
  context.setFillColor(background)
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(path)
  context.clip()
  if size >= 64 {
    // The iPhone/iPad AppIcon, unchanged, filling the body.
    context.draw(appIcon, in: body)
  } else {
    context.setFillColor(background)
    context.fill(body)
    // The solid K, enlarged within the body and centred.
    let width = body.width * 0.80
    let factor = width / markBounds.width
    let height = markBounds.height * factor
    let target = CGRect(x: body.midX - width / 2, y: body.midY - height / 2, width: width, height: height)
    let canvas = CGRect(x: target.minX - markBounds.minX * factor, y: target.minY - markBounds.minY * factor,
                        width: 1024 * factor, height: 1024 * factor)
    context.clip(to: canvas, mask: markMask)
    context.setFillColor(markRed)
    context.fill(canvas)
  }
  context.restoreGState()
  return context.makeImage()!
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
  let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("KartPadIcon-\(size).png")
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, render(pixels: size), nil)
  guard CGImageDestinationFinalize(destination) else { exit(74) }
}
SWIFT
xcrun swiftc -O "${temporary}/compose.swift" -o "${temporary}/compose"
"${temporary}/compose" "$app_icon" "$logo" "$exports/macos"

for points in 16 32 128 256 512; do
  cp "$exports/macos/KartPadIcon-${points}.png" "$iconset/icon_${points}x${points}.png"
  pixels=$((points * 2))
  cp "$exports/macos/KartPadIcon-${pixels}.png" "$iconset/icon_${points}x${points}@2x.png"
done
iconutil -c icns "$iconset" -o "$exports/KartPad.icns"
echo "Generated the macOS icon from the iPhone/iPad red K"
