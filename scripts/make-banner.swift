#!/usr/bin/env swift
// Draws the SwiftDesk README banner / GitHub social preview (1280 x 640) with CoreGraphics, CoreText and ImageIO.
//
//   swift scripts/make-banner.swift            # writes docs/assets/banner.png
//
// It reuses the app icon (Resources/AppIcon-1024.png, drawn by scripts/make-icon.swift) and that script's palette:
// a deep indigo-to-navy field, a cyan glow behind the icon, faint cyan speed lines, the "SwiftDesk" wordmark, the
// tagline and a row of feature chips. All text stays inside GitHub's recommended 40 pt safe border so the image also
// works as the repository's social preview.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette (shared with make-icon.swift)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

enum Palette {
    static let indigo = rgb(0x5B57EE)
    static let deepIndigo = rgb(0x1E1A6E)
    static let navy = rgb(0x0A0F35)
    static let night = rgb(0x070A26)
    static let cyan = rgb(0x5EEAF5)
    static let glow = rgb(0x22D3EE)
    static let sky = rgb(0x38BDF8)
    static let lavender = rgb(0xC7D2FE)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

// MARK: - Text

/// The system UI font (SF Pro) at a given size and weight (`kCTFontWeightTrait`, -1 ... 1).
func systemFont(size: CGFloat, weight: CGFloat) -> CTFont {
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
    let traits: [CFString: Any] = [kCTFontWeightTrait: weight]
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontFamilyNameAttribute: CTFontCopyFamilyName(base),
        kCTFontTraitsAttribute: traits,
    ] as CFDictionary)
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}

func line(_ text: String, font: CTFont, color: CGColor, kern: CGFloat = 0) -> CTLine {
    let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color,
                                       kCTKernAttributeName: kern]
    return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
}

func width(of l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

/// Draws a line with its baseline at `baseline` (y-up device space).
func draw(_ l: CTLine, x: CGFloat, baseline: CGFloat, in ctx: CGContext) {
    ctx.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(l, ctx)
}

// MARK: - Canvas

let width = 1280, height = 640
let W = CGFloat(width), H = CGFloat(height)

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconURL = root.appendingPathComponent("Resources/AppIcon-1024.png")
let outDir = root.appendingPathComponent("docs/assets")
let outURL = outDir.appendingPathComponent("banner.png")

guard let iconSource = CGImageSourceCreateWithURL(iconURL as CFURL, nil),
      let icon = CGImageSourceCreateImageAtIndex(iconSource, 0, nil) else {
    FileHandle.standardError.write("error: cannot read \(iconURL.path); run scripts/make-icon.swift first\n".data(using: .utf8)!)
    exit(1)
}

guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {  // opaque: smaller PNG
    FileHandle.standardError.write("error: no bitmap context\n".data(using: .utf8)!)
    exit(1)
}
ctx.interpolationQuality = .high
ctx.setShouldAntialias(true)
ctx.setShouldSmoothFonts(true)

// Device space is y-up; `top(y)` converts a y-down design coordinate.
func top(_ y: CGFloat) -> CGFloat { H - y }

// Icon placement (the PNG's squircle body is 824/1024 of its width, centred).
let iconSize: CGFloat = 420
let iconCenter = CGPoint(x: 300, y: top(320))
let iconRect = CGRect(x: iconCenter.x - iconSize / 2, y: iconCenter.y - iconSize / 2, width: iconSize, height: iconSize)

// MARK: - Background

// Base: deep indigo at the top left falling to near-black navy at the bottom right.
ctx.drawLinearGradient(gradient([Palette.deepIndigo, Palette.navy, Palette.night], [0, 0.55, 1]),
                       start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

// Indigo bloom behind the icon, then a cyan core, echoing the icon's glow.
ctx.drawRadialGradient(gradient([rgb(0x5B57EE, 0.55), rgb(0x5B57EE, 0)]),
                       startCenter: iconCenter, startRadius: 0, endCenter: iconCenter, endRadius: 520, options: [])
ctx.drawRadialGradient(gradient([rgb(0x38BDF8, 0.28), rgb(0x38BDF8, 0)]),
                       startCenter: iconCenter, startRadius: 0, endCenter: iconCenter, endRadius: 300, options: [])

// A soft second light at the top right so the text side is not flat.
let rightLight = CGPoint(x: 1120, y: top(40))
ctx.drawRadialGradient(gradient([rgb(0x818CF8, 0.22), rgb(0x818CF8, 0)]),
                       startCenter: rightLight, startRadius: 0, endCenter: rightLight, endRadius: 520, options: [])

// Faint dot grid on the right, fading toward the text, for texture.
ctx.saveGState()
let gridStep: CGFloat = 32
var gy: CGFloat = gridStep / 2
while gy < H {
    var gx: CGFloat = gridStep / 2
    while gx < W {
        let fade = max(0, min(1, (gx - 520) / 700))
        if fade > 0 {
            ctx.setFillColor(rgb(0xC7D2FE, 0.07 * fade))
            ctx.fillEllipse(in: CGRect(x: gx - 1.2, y: gy - 1.2, width: 2.4, height: 2.4))
        }
        gx += gridStep
    }
    gy += gridStep
}
ctx.restoreGState()

// Speed lines streaking in from the left edge toward the icon, tapered like the icon's own streaks.
struct Streak { var y: CGFloat; var x0: CGFloat; var x1: CGFloat; var width: CGFloat; var alpha: CGFloat }
let streaks = [
    Streak(y: 236, x0: 18, x1: 96, width: 8, alpha: 0.45),
    Streak(y: 284, x0: -10, x1: 112, width: 14, alpha: 0.75),
    Streak(y: 332, x0: 30, x1: 104, width: 10, alpha: 0.55),
    Streak(y: 392, x0: 4, x1: 90, width: 8, alpha: 0.35),
]
for s in streaks {
    let y = top(s.y)
    let path = CGMutablePath()
    let tail = s.width * 0.18
    path.move(to: CGPoint(x: s.x0, y: y + tail))
    path.addLine(to: CGPoint(x: s.x1, y: y + s.width / 2))
    path.addArc(center: CGPoint(x: s.x1, y: y), radius: s.width / 2, startAngle: .pi / 2, endAngle: -.pi / 2,
                clockwise: true)
    path.addLine(to: CGPoint(x: s.x0, y: y - tail))
    path.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14, color: rgb(0x22D3EE, 0.6 * s.alpha))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x5EEAF5, 0.2 * s.alpha))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x67E8F9, 0), rgb(0x67E8F9, 0.6 * s.alpha), rgb(0xCFFAFE, s.alpha)], [0, 0.6, 1]),
                           start: CGPoint(x: s.x0, y: y), end: CGPoint(x: s.x1 + s.width / 2, y: y), options: [])
    ctx.restoreGState()
}

// Vignette so the edges settle into the page.
ctx.drawRadialGradient(gradient([rgb(0x000000, 0), rgb(0x000000, 0.35)]),
                       startCenter: CGPoint(x: W * 0.45, y: H * 0.5), startRadius: 360,
                       endCenter: CGPoint(x: W * 0.45, y: H * 0.5), endRadius: 900, options: [.drawsAfterEndLocation])

// MARK: - Icon

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 48, color: rgb(0x020414, 0.55))
ctx.draw(icon, in: iconRect)
ctx.restoreGState()

// MARK: - Text

let textX: CGFloat = 548

// Wordmark: "Swift" in white, "Desk" in a cyan-to-sky gradient.
let wordFont = systemFont(size: 112, weight: 0.62)
let swiftPart = line("Swift", font: wordFont, color: rgb(0xFFFFFF), kern: -2.5)
let deskPart = line("Desk", font: wordFont, color: rgb(0xFFFFFF), kern: -2.5)
let wordBaseline = top(250)
draw(swiftPart, x: textX, baseline: wordBaseline, in: ctx)
let deskX = textX + width(of: swiftPart)
do {
    // Gradient fill for "Desk": render the glyphs as a clip by drawing them in text-clip mode.
    ctx.saveGState()
    ctx.setTextDrawingMode(.clip)
    draw(deskPart, x: deskX, baseline: wordBaseline, in: ctx)
    ctx.setTextDrawingMode(.fill)
    ctx.drawLinearGradient(gradient([Palette.cyan, Palette.sky, rgb(0x818CF8)], [0, 0.55, 1]),
                           start: CGPoint(x: deskX, y: wordBaseline + 80), end: CGPoint(x: deskX + width(of: deskPart), y: wordBaseline - 10),
                           options: [])
    ctx.restoreGState()
}

// Tagline, two lines.
let tagFont = systemFont(size: 33, weight: 0.23)
let tag1 = line("Open-source, low-latency remote desktop", font: tagFont, color: rgb(0xEEF2FF))
let tag2 = line("for macOS. Control one Mac from another.", font: tagFont, color: rgb(0xEEF2FF))
draw(tag1, x: textX + 4, baseline: top(314), in: ctx)
draw(tag2, x: textX + 4, baseline: top(358), in: ctx)

// Feature chips.
let chipFont = systemFont(size: 21, weight: 0.3)
let chips = ["Native Swift", "QUIC + TLS 1.3", "No accounts", "No cloud"]
var chipX = textX + 4
let chipTop: CGFloat = 402, chipHeight: CGFloat = 44
for label in chips {
    let l = line(label, font: chipFont, color: rgb(0xE0F7FF))
    let w = width(of: l) + 36
    let rect = CGRect(x: chipX, y: top(chipTop + chipHeight), width: w, height: chipHeight)
    let path = CGPath(roundedRect: rect, cornerWidth: chipHeight / 2, cornerHeight: chipHeight / 2, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x5B57EE, 0.40), rgb(0x22D3EE, 0.16)]),
                           start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setLineWidth(1.5)
    ctx.setStrokeColor(rgb(0x67E8F9, 0.45))
    ctx.strokePath()
    let ascent = CTFontGetAscent(chipFont), descent = CTFontGetDescent(chipFont)
    draw(l, x: rect.minX + 18, baseline: rect.midY - (ascent - descent) / 2, in: ctx)
    chipX += w + 12
}

// Small platform line under the chips.
let metaFont = systemFont(size: 19, weight: 0.0)
let meta = line("macOS 15+  ·  Apple silicon & Intel  ·  MIT licensed", font: metaFont, color: rgb(0xA5B4FC, 0.85),
                kern: 0.4)
draw(meta, x: textX + 6, baseline: top(494), in: ctx)

// MARK: - Output

try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("error: cannot write \(outURL.path)\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("error: cannot write \(outURL.path)\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(outURL.path)")
