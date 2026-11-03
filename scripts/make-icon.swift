#!/usr/bin/env swift
// Draws the SwiftDesk app icon with CoreGraphics and packages it as Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift              # writes Resources/AppIcon.icns and Resources/AppIcon-1024.png
//   ICONSET_DIR=/tmp/x.iconset swift scripts/make-icon.swift   # keep the PNGs (the name must end in .iconset)
//
// Concept: a display glowing with a deep blue screen, and a white pointer streaking across it on cyan speed
// lines; remote control, fast. Geometry follows the macOS (Big Sur and later) icon grid: an 824 x 824
// continuous-corner body centred on a 1024 x 1024 canvas, with a soft drop shadow. 32 px and 16 px renders use
// simplified, pixel-aligned variants (bigger display, thick bezel, two bold speed lines, and at 16 px a pointer
// placed pixel by pixel) so the icon stays legible in Finder lists and the menu bar.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

enum Palette {
    static let bodyTop = rgb(0x5B57EE)       // indigo
    static let bodyBottom = rgb(0x1E1A6E)    // deep indigo
    static let bezelTop = rgb(0xFFFFFF)
    static let bezelBottom = rgb(0xD5DBF5)
    static let screenTop = rgb(0x2547C9)     // blue
    static let screenBottom = rgb(0x0A0F35)  // near-black navy
    static let streak = rgb(0x5EEAF5)        // bright cyan
    static let cursorFill = rgb(0xFFFFFF)
    static let cursorEdge = rgb(0x0E1440)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

// MARK: - Shapes

/// Rounded rectangle with continuous-curvature ("squircle") corners: each corner is a quarter superellipse that
/// starts 1.53 r from the corner and meets the straight edges with zero curvature, like Apple's icon shape.
func continuousRect(_ rect: CGRect, radius r: CGFloat, exponent n: CGFloat = 3.3) -> CGPath {
    let e = min(r * 1.5287, min(rect.width, rect.height) / 2)
    let path = CGMutablePath()
    let steps = 48
    // Corners clockwise in y-down space: centre, signs, and whether the sweep runs from the vertical axis.
    let corners: [(cx: CGFloat, cy: CGFloat, sx: CGFloat, sy: CGFloat, fromVertical: Bool)] = [
        (rect.maxX - e, rect.minY + e, 1, -1, true),   // top-right: top edge -> right edge
        (rect.maxX - e, rect.maxY - e, 1, 1, false),   // bottom-right: right edge -> bottom edge
        (rect.minX + e, rect.maxY - e, -1, 1, true),   // bottom-left: bottom edge -> left edge
        (rect.minX + e, rect.minY + e, -1, -1, false), // top-left: left edge -> top edge
    ]
    for (index, c) in corners.enumerated() {
        for i in 0...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let t = (c.fromVertical ? 1 - f : f) * (.pi / 2)
            // Superellipse |u|^n + |v|^n = 1 in the corner's quadrant.
            let u = pow(cos(t), 2 / n), v = pow(sin(t), 2 / n)
            let p = CGPoint(x: c.cx + c.sx * e * u, y: c.cy + c.sy * e * v)
            if index == 0 && i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
    }
    path.closeSubpath()
    return path
}

/// The classic arrow pointer, tip at the origin, about 1 unit tall, in a y-down space.
func cursorPath(at tip: CGPoint, height h: CGFloat) -> CGPath {
    let pts: [(CGFloat, CGFloat)] = [
        (0, 0), (0, 0.80), (0.185, 0.63), (0.305, 0.905), (0.435, 0.85), (0.315, 0.585), (0.56, 0.585),
    ]
    let path = CGMutablePath()
    path.addLines(between: pts.map { CGPoint(x: tip.x + $0.0 * h, y: tip.y + $0.1 * h) })
    path.closeSubpath()
    return path
}

// MARK: - Drawing

struct Streak {
    var y: CGFloat, x0: CGFloat, x1: CGFloat, width: CGFloat
}

struct Layout {
    var screen: CGRect          // outer bezel rect
    var bezel: CGFloat          // bezel thickness
    var bezelRadius: CGFloat
    var neck: CGRect?           // stand neck (drawn as a gentle trapezoid when detailed)
    var foot: CGRect?
    var cursorTip: CGPoint
    var cursorHeight: CGFloat
    var cursorEdge: CGFloat     // how far the dark outline extends beyond the white pointer
    var streaks: [Streak]
    var detail: Bool            // sheens, glows, tapering, and other touches that only help at larger sizes
    var pixelPointer: [[CGFloat]]? = nil  // 16 px only: per-pixel pointer coverage, rows from the tip down

    /// 64 px and up.
    static let full = Layout(
        screen: CGRect(x: 196, y: 246, width: 632, height: 436), bezel: 28, bezelRadius: 60,
        neck: CGRect(x: 456, y: 672, width: 112, height: 86), foot: CGRect(x: 368, y: 746, width: 288, height: 34),
        cursorTip: CGPoint(x: 528, y: 330), cursorHeight: 404, cursorEdge: 11,
        streaks: [Streak(y: 418, x0: 296, x1: 484, width: 30),
                  Streak(y: 500, x0: 244, x1: 484, width: 34),
                  Streak(y: 582, x0: 314, x1: 484, width: 30)],
        detail: true)

    /// 32 px (16 pt @2x, 32 pt @1x). One design unit = 1/32 px, so edges below sit on whole pixels.
    static let small = Layout(
        screen: CGRect(x: 160, y: 192, width: 704, height: 480), bezel: 64, bezelRadius: 96,
        neck: CGRect(x: 448, y: 672, width: 128, height: 64), foot: CGRect(x: 320, y: 736, width: 384, height: 64),
        cursorTip: CGPoint(x: 544, y: 272), cursorHeight: 336, cursorEdge: 0,
        streaks: [Streak(y: 384, x0: 256, x1: 464, width: 64),
                  Streak(y: 512, x0: 288, x1: 464, width: 64)],
        detail: false)

    /// 16 px. One design unit = 1/16 px: a 1 px white bezel, a navy screen seven pixels tall, a hand-placed
    /// pointer, two speed lines, and a foot directly under the display (no room for a neck).
    static let tiny = Layout(
        screen: CGRect(x: 192, y: 192, width: 640, height: 576), bezel: 64, bezelRadius: 96,
        neck: nil, foot: CGRect(x: 384, y: 768, width: 256, height: 64),
        cursorTip: CGPoint(x: 512, y: 256), cursorHeight: 448, cursorEdge: 0,
        streaks: [Streak(y: 352, x0: 256, x1: 448, width: 64),
                  Streak(y: 480, x0: 288, x1: 448, width: 64)],
        detail: false,
        pixelPointer: [[1, 0, 0, 0],
                       [1, 1, 0, 0],
                       [1, 1, 1, 0],
                       [1, 1, 1, 1],
                       [1, 0.7, 0, 0],
                       [0.6, 1, 0, 0],
                       [0, 1, 0.5, 0]])

    static func forPixels(_ pixels: Int) -> Layout {
        pixels <= 16 ? .tiny : pixels <= 32 ? .small : .full
    }
}

func drawIcon(in ctx: CGContext, pixels: Int) {
    let s = CGFloat(pixels) / 1024
    let layout = Layout.forPixels(pixels)

    ctx.saveGState()
    // Work in a y-down 1024 x 1024 design space. Shadow offsets stay in device space (y up), hence the negatives.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: s, y: -s)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = continuousRect(body, radius: 185.4)

    // Drop shadow under the body, per the macOS icon template.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: rgb(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(Palette.bodyBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // Body: indigo gradient, a cyan glow rising from behind the display, and a soft top sheen.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([Palette.bodyTop, Palette.bodyBottom]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.drawRadialGradient(gradient([rgb(0x38BDF8, 0.40), rgb(0x38BDF8, 0)]),
                           startCenter: CGPoint(x: 512, y: 640), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 640), endRadius: 480, options: [])
    if layout.detail {
        ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)]),
                               start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 420), options: [])
    }
    ctx.restoreGState()

    if layout.detail {
        // Hairline inner highlight along the body edge, brightest at the top.
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        ctx.addPath(bodyPath)
        ctx.setLineWidth(5)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.40), rgb(0xFFFFFF, 0.0)]),
                               start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 560), options: [])
        ctx.restoreGState()
    }

    drawDisplay(in: ctx, layout: layout, scale: s)

    ctx.restoreGState()
}

func drawDisplay(in ctx: CGContext, layout l: Layout, scale s: CGFloat) {
    let outer = l.screen
    let outerPath = CGPath(roundedRect: outer, cornerWidth: l.bezelRadius, cornerHeight: l.bezelRadius, transform: nil)
    let inner = outer.insetBy(dx: l.bezel, dy: l.bezel)
    let innerRadius = max(l.bezelRadius - l.bezel, 12)
    let innerPath = CGPath(roundedRect: inner, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)

    // Stand: neck and pill-shaped foot, drawn first so the display sits on top.
    if let neckRect = l.neck {
        let neck = CGMutablePath()
        let flare: CGFloat = l.detail ? 14 : 0
        neck.move(to: CGPoint(x: neckRect.minX, y: neckRect.minY))
        neck.addLine(to: CGPoint(x: neckRect.maxX, y: neckRect.minY))
        neck.addLine(to: CGPoint(x: neckRect.maxX + flare, y: neckRect.maxY))
        neck.addLine(to: CGPoint(x: neckRect.minX - flare, y: neckRect.maxY))
        neck.closeSubpath()
        ctx.saveGState()
        ctx.addPath(neck)
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0x8E98CC), rgb(0xC3CBEC)]),
                               start: CGPoint(x: 512, y: neckRect.minY), end: CGPoint(x: 512, y: neckRect.maxY),
                               options: [])
        ctx.restoreGState()
    }
    if let footRect = l.foot {
        let r = l.detail ? footRect.height / 2 : footRect.height / 4
        let foot = CGPath(roundedRect: footRect, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.saveGState()
        if l.detail {
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s, color: rgb(0x05062A, 0.30))
        }
        ctx.addPath(foot)
        ctx.setFillColor(rgb(0xE4E8FA))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Bezel: brushed white-to-lavender aluminium, floating on a soft shadow.
    ctx.saveGState()
    if l.detail {
        ctx.setShadow(offset: CGSize(width: 0, height: -16 * s), blur: 36 * s, color: rgb(0x05062A, 0.45))
    }
    ctx.addPath(outerPath)
    ctx.setFillColor(Palette.bezelBottom)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(outerPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([Palette.bezelTop, Palette.bezelBottom]),
                           start: CGPoint(x: 512, y: outer.minY), end: CGPoint(x: 512, y: outer.maxY), options: [])
    ctx.restoreGState()

    // Screen: deep blue glass with a cyan bloom where the pointer is travelling.
    ctx.saveGState()
    ctx.addPath(innerPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([Palette.screenTop, Palette.screenBottom]),
                           start: CGPoint(x: inner.minX, y: inner.minY), end: CGPoint(x: inner.maxX, y: inner.maxY),
                           options: [])
    if l.detail {
        let bloom = CGPoint(x: inner.minX + inner.width * 0.42, y: inner.midY + 10)
        ctx.drawRadialGradient(gradient([rgb(0x22D3EE, 0.30), rgb(0x22D3EE, 0)]),
                               startCenter: bloom, startRadius: 0, endCenter: bloom, endRadius: inner.width * 0.50,
                               options: [])
        // Glass: a gentle light falloff from the top, and a thin recess shadow under the top bezel.
        ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)]),
                               start: CGPoint(x: 512, y: inner.minY), end: CGPoint(x: 512, y: inner.midY), options: [])
        ctx.drawLinearGradient(gradient([rgb(0x000000, 0.35), rgb(0x000000, 0)]),
                               start: CGPoint(x: 512, y: inner.minY), end: CGPoint(x: 512, y: inner.minY + 18),
                               options: [])
    }
    ctx.restoreGState()

    // Speed lines trailing the pointer: tapered and fading toward the tail, with a cyan glow.
    for streak in l.streaks {
        let w = streak.width
        let path = CGMutablePath()
        if l.detail {
            let tail = w * 0.18
            path.move(to: CGPoint(x: streak.x0, y: streak.y - tail))
            path.addLine(to: CGPoint(x: streak.x1, y: streak.y - w / 2))
            path.addArc(center: CGPoint(x: streak.x1, y: streak.y), radius: w / 2,
                        startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            path.addLine(to: CGPoint(x: streak.x0, y: streak.y + tail))
            path.addArc(center: CGPoint(x: streak.x0, y: streak.y), radius: tail,
                        startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
            path.closeSubpath()
        } else {
            path.addRect(CGRect(x: streak.x0, y: streak.y - w / 2, width: streak.x1 - streak.x0, height: w))
        }
        if l.detail {
            // Glow pass: the shape filled with a soft cyan shadow.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 26 * s, color: rgb(0x22D3EE, 0.75))
            ctx.addPath(path)
            ctx.setFillColor(rgb(0x5EEAF5, 0.35))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let colors = l.detail ? [rgb(0x67E8F9, 0.0), rgb(0x67E8F9, 0.6), rgb(0xCFFAFE)]
                              : [rgb(0x22D3EE, 0.75), Palette.streak, Palette.streak]
        ctx.drawLinearGradient(gradient(colors, [0, 0.5, 1]),
                               start: CGPoint(x: streak.x0, y: streak.y), end: CGPoint(x: streak.x1 + w / 2, y: streak.y),
                               options: [])
        ctx.restoreGState()
    }

    // At 16 px a vector arrow smears into a blob, so the pointer is placed pixel by pixel (white, with coverage).
    if let pixelArt = l.pixelPointer {
        let unit: CGFloat = 64 // one pixel at 16 px
        for (row, values) in pixelArt.enumerated() {
            for (col, alpha) in values.enumerated() where alpha > 0 {
                ctx.setFillColor(rgb(0xFFFFFF, alpha))
                ctx.fill(CGRect(x: l.cursorTip.x + CGFloat(col) * unit, y: l.cursorTip.y + CGFloat(row) * unit,
                                width: unit, height: unit))
            }
        }
        return
    }

    // Pointer: white with a navy edge and a cast shadow so it floats above the glass.
    let pointer = cursorPath(at: l.cursorTip, height: l.cursorHeight)
    if l.cursorEdge > 0 {
        ctx.saveGState()
        if l.detail {
            ctx.setShadow(offset: CGSize(width: 6 * s, height: -16 * s), blur: 28 * s, color: rgb(0x020414, 0.55))
        }
        ctx.addPath(pointer)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(l.cursorEdge * 2)
        ctx.setStrokeColor(Palette.cursorEdge)
        ctx.setFillColor(Palette.cursorEdge)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(pointer)
    if l.detail {
        // Round the pointer's corners slightly with a same-colour stroke.
        ctx.setLineJoin(.round)
        ctx.setLineWidth(6)
        ctx.setStrokeColor(Palette.cursorFill)
        ctx.setFillColor(Palette.cursorFill)
        ctx.drawPath(using: .fillStroke)
        ctx.addPath(pointer)
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0), rgb(0xC7D2FE, 0.6)]),
                               start: CGPoint(x: l.cursorTip.x, y: l.cursorTip.y + l.cursorHeight * 0.3),
                               end: CGPoint(x: l.cursorTip.x, y: l.cursorTip.y + l.cursorHeight), options: [])
    } else {
        ctx.setFillColor(Palette.cursorFill)
        ctx.fillPath()
    }
    ctx.restoreGState()
}

// MARK: - Output

func renderPNG(pixels: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "no bitmap context"])
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    drawIcon(in: ctx, pixels: pixels)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
}

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")

let iconset: URL
if let dir = ProcessInfo.processInfo.environment["ICONSET_DIR"], !dir.isEmpty {
    iconset = URL(fileURLWithPath: dir)
} else {
    iconset = fm.temporaryDirectory.appendingPathComponent("SwiftDesk-\(UUID().uuidString).iconset")
}
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try renderPNG(pixels: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try renderPNG(pixels: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try renderPNG(pixels: 1024, to: resources.appendingPathComponent("AppIcon-1024.png"))

let icns = resources.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("error: iconutil failed (\(iconutil.terminationStatus))\n".data(using: .utf8)!)
    exit(1)
}
if ProcessInfo.processInfo.environment["ICONSET_DIR"] == nil { try? fm.removeItem(at: iconset) }
print("wrote \(icns.path)")
print("wrote \(resources.appendingPathComponent("AppIcon-1024.png").path)")
