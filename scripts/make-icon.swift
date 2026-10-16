// Renders the 1024×1024 bsTimer app icon: a stopwatch whose face is a scrambled cube face,
// above the name.
// Usage (on a Mac): swift scripts/make-icon.swift CstimerApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import AppKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// No alpha channel: iOS app icons must be opaque.
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Draw in a top-left origin so rows read top to bottom.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// 1. Background vertical gradient.
let gradientColors = [rgb(0x22304d), rgb(0x121a2b)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: gradientColors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: 1024), options: [])

func fillCircle(center: CGPoint, radius: CGFloat, color: CGColor) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let path = CGPath(ellipseIn: rect, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func strokeCircle(center: CGPoint, radius: CGFloat, color: CGColor, width: CGFloat) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let path = CGPath(ellipseIn: rect, transform: nil)
    ctx.addPath(path)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.strokePath()
}

func fillRoundedRect(_ rect: CGRect, cornerRadius: CGFloat, color: CGColor) {
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func strokeRoundedRect(_ rect: CGRect, cornerRadius: CGFloat, color: CGColor, width: CGFloat) {
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.strokePath()
}

// The stopwatch is drawn at 78% size in the upper part, leaving room for the name below:
// y' = 30 + 0.78 * y, centred horizontally.
ctx.saveGState()
ctx.translateBy(x: 512, y: 30)
ctx.scaleBy(x: 0.78, y: 0.78)
ctx.translateBy(x: -512, y: 0)

// 3. Crown (drawn before the body so the circle overlaps its bottom edge).
let crownRect = CGRect(x: 452, y: 120, width: 120, height: 80)
fillRoundedRect(crownRect, cornerRadius: 18, color: rgb(0xf4f1e8))
strokeRoundedRect(crownRect, cornerRadius: 18, color: rgb(0xffffff), width: 16)

// Small stem.
let stemRect = CGRect(x: 487, y: 190, width: 50, height: 25)
fillRoundedRect(stemRect, cornerRadius: 0, color: rgb(0xf4f1e8))

// 4. Two side buttons (drawn before the body circle).
func drawSideButton(angle: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 560)
    ctx.rotate(by: angle)
    let rect = CGRect(x: -35, y: -(360 + 30) - 23, width: 70, height: 46)
    fillRoundedRect(rect, cornerRadius: 14, color: rgb(0xf4f1e8))
    strokeRoundedRect(rect, cornerRadius: 14, color: rgb(0xffffff), width: 12)
    ctx.restoreGState()
}
drawSideButton(angle: -45 * .pi / 180)
drawSideButton(angle: 45 * .pi / 180)

// 2. Stopwatch body.
let bodyCenter = CGPoint(x: 512, y: 560)
let bodyRadius: CGFloat = 360
fillCircle(center: bodyCenter, radius: bodyRadius, color: rgb(0xf4f1e8))
strokeCircle(center: bodyCenter, radius: bodyRadius, color: rgb(0xffffff), width: 28)

// 5. Cube face inside the stopwatch.
let backingSide: CGFloat = 440
let backingRect = CGRect(x: 512 - backingSide / 2, y: 560 - backingSide / 2, width: backingSide, height: backingSide)
fillRoundedRect(backingRect, cornerRadius: 48, color: rgb(0x111111))

let gap: CGFloat = 14
let stickerSide = (backingSide - 4 * gap) / 3
let stickerRadius: CGFloat = 22
let stickers: [[UInt32]] = [
    [0xffffff, 0xff5a36, 0x2f7df6],
    [0xffd500, 0x1fbf5b, 0xffffff],
    [0xff8a00, 0xffd500, 0xff5a36]
]
for (row, rowColors) in stickers.enumerated() {
    for (col, color) in rowColors.enumerated() {
        let x = backingRect.minX + gap + CGFloat(col) * (stickerSide + gap)
        let y = backingRect.minY + gap + CGFloat(row) * (stickerSide + gap)
        let rect = CGRect(x: x, y: y, width: stickerSide, height: stickerSide)
        fillRoundedRect(rect, cornerRadius: stickerRadius, color: rgb(color))
    }
}

// 6. Timer hand.
let handAngle: CGFloat = 30 * .pi / 180
let handRadius: CGFloat = 250
let handEnd = CGPoint(x: 512 + handRadius * sin(handAngle), y: 560 - handRadius * cos(handAngle))

ctx.setLineCap(.round)
ctx.setStrokeColor(rgb(0x111111))
ctx.setLineWidth(22)
ctx.move(to: bodyCenter)
ctx.addLine(to: handEnd)
ctx.strokePath()

ctx.setStrokeColor(rgb(0xffffff))
ctx.setLineWidth(10)
ctx.move(to: bodyCenter)
ctx.addLine(to: handEnd)
ctx.strokePath()

// Centre dot.
fillCircle(center: bodyCenter, radius: 26, color: rgb(0x111111))
fillCircle(center: bodyCenter, radius: 12, color: rgb(0xffffff))
ctx.restoreGState()

// 7. The name, in the band below the stopwatch (y 790...960), white, scaled to 74% of the width.
let title = "bsTimer" as NSString
let fontName = NSFont(name: "HelveticaNeue-Bold", size: 100) != nil ? "HelveticaNeue-Bold" : "Helvetica-Bold"
var font = NSFont(name: fontName, size: 100)!
font = NSFont(name: fontName, size: 100 * (1024 * 0.74) / title.size(withAttributes: [.font: font]).width)!
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
let textSize = title.size(withAttributes: attrs)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
title.draw(at: NSPoint(x: 512 - textSize.width / 2, y: 875 - textSize.height / 2), withAttributes: attrs)
NSGraphicsContext.restoreGraphicsState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(outPath)") }
print("wrote \(outPath)")
