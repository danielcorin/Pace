// Generates the app icon and menu bar template icon headlessly.
// The design leans into the pace/paste pun: a clipboard leaning forward
// with motion streaks trailing behind it — a paste moving at pace.
//
// Run from the repo root:
//   swift scripts/generate-icons.swift
//
// Outputs PNGs into Sources/PaceApp/Assets.xcassets/{AppIcon.appiconset,MenuBarIcon.imageset}.

import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Sources/PaceApp/Assets.xcassets")
let appIconDir = assets.appendingPathComponent("AppIcon.appiconset")
let menuIconDir = assets.appendingPathComponent("MenuBarIcon.imageset")

try FileManager.default.createDirectory(at: appIconDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: menuIconDir, withIntermediateDirectories: true)

func makeContext(_ px: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

func writePNG(_ ctx: CGContext, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.lastPathComponent)")
}

func capsule(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: r, cornerHeight: r, transform: nil)
}

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// Forward lean (italic) shear: x' = x + k * (y - pivotY). Top leans right.
func shear(_ k: CGFloat, pivotY: CGFloat) -> CGAffineTransform {
    CGAffineTransform(a: 1, b: 0, c: k, d: 1, tx: -k * pivotY, ty: 0)
}

let lean: CGFloat = tan(9 * .pi / 180)

// MARK: - App icon (designed in 1024-space)

func drawAppIcon(px: Int) -> CGContext {
    let ctx = makeContext(px)
    let scale = CGFloat(px) / 1024
    ctx.scaleBy(x: scale, y: scale)

    // Squircle background with a diagonal gray → black gradient.
    let squircle = rounded(100, 100, 824, 824, 186)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [srgb(0.48, 0.48, 0.50), srgb(0.06, 0.06, 0.07)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 220, y: 920),
                           end: CGPoint(x: 860, y: 130),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Glyph: sheared forward, soft drop shadow. Shadow params live in base
    // (pixel) space, so scale them by hand.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale),
                  blur: 30 * scale,
                  color: srgb(0, 0, 0, 0.30))
    ctx.concatenate(shear(lean, pivotY: 512))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // Clipboard board + clip tab, white.
    ctx.setFillColor(srgb(1, 1, 1))
    ctx.addPath(rounded(407, 285, 330, 430, 46))   // board
    ctx.fillPath()
    ctx.addPath(rounded(487, 676, 170, 88, 30))    // clip tab
    ctx.fillPath()

    // Motion streaks trailing behind (to the left).
    ctx.setFillColor(srgb(1, 1, 1, 0.95))
    ctx.addPath(capsule(208, 593, 152, 34))
    ctx.fillPath()
    ctx.setFillColor(srgb(1, 1, 1, 0.72))
    ctx.addPath(capsule(152, 483, 208, 34))
    ctx.fillPath()
    ctx.setFillColor(srgb(1, 1, 1, 0.50))
    ctx.addPath(capsule(238, 375, 122, 34))
    ctx.fillPath()

    // Knockouts: clip ring + pasted "text" lines show the gradient through.
    ctx.setBlendMode(.clear)
    ctx.addPath(CGPath(ellipseIn: CGRect(x: 554, y: 708, width: 36, height: 36), transform: nil))
    ctx.fillPath()
    ctx.addPath(capsule(455, 567, 235, 36))
    ctx.fillPath()
    ctx.addPath(capsule(455, 482, 170, 36))
    ctx.fillPath()
    ctx.addPath(capsule(455, 397, 205, 36))
    ctx.fillPath()
    ctx.setBlendMode(.normal)

    ctx.endTransparencyLayer()
    ctx.restoreGState()
    return ctx
}

// MARK: - Menu bar template icon (designed in 18-space, black-on-clear)

func drawMenuBarIcon(px: Int) -> CGContext {
    let ctx = makeContext(px)
    let scale = CGFloat(px) / 18
    ctx.scaleBy(x: scale, y: scale)
    ctx.concatenate(shear(lean, pivotY: 9))

    let black = srgb(0, 0, 0)
    ctx.setStrokeColor(black)
    ctx.setFillColor(black)
    ctx.setLineCap(.round)

    // Board outline.
    ctx.setLineWidth(1.4)
    ctx.addPath(rounded(7.4, 2.6, 8.0, 12.4, 1.8))
    ctx.strokePath()

    // Clip tab, filled.
    ctx.addPath(rounded(9.6, 13.9, 3.6, 2.2, 1.1))
    ctx.fillPath()

    // "Text" lines on the board.
    ctx.setLineWidth(1.25)
    ctx.move(to: CGPoint(x: 9.6, y: 10.6)); ctx.addLine(to: CGPoint(x: 13.2, y: 10.6))
    ctx.move(to: CGPoint(x: 9.6, y: 7.9)); ctx.addLine(to: CGPoint(x: 12.2, y: 7.9))
    ctx.strokePath()

    // Motion streaks.
    ctx.setLineWidth(1.5)
    ctx.move(to: CGPoint(x: 2.7, y: 11.9)); ctx.addLine(to: CGPoint(x: 5.1, y: 11.9))
    ctx.move(to: CGPoint(x: 3.5, y: 7.0)); ctx.addLine(to: CGPoint(x: 5.4, y: 7.0))
    ctx.strokePath()
    return ctx
}

// MARK: - Emit files

let appIconSizes = [16, 32, 64, 128, 256, 512, 1024]
for px in appIconSizes {
    writePNG(drawAppIcon(px: px), to: appIconDir.appendingPathComponent("icon_\(px).png"))
}
writePNG(drawMenuBarIcon(px: 18), to: menuIconDir.appendingPathComponent("MenuBarIcon.png"))
writePNG(drawMenuBarIcon(px: 36), to: menuIconDir.appendingPathComponent("MenuBarIcon@2x.png"))
