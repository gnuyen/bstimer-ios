// Renders the 1024×1024 bsTimer app icon in the style of the csTimer logo.
// Usage (on a Mac): swift scripts/make-icon.swift CstimerApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import AppKit
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

ctx.setFillColor(rgb(0xc4ec84))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

let gap: CGFloat = 16
let cell = (CGFloat(size) - gap * 4) / 3
let radius: CGFloat = 26

func roundedRect(_ rect: CGRect, _ color: CGColor) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(0xc8b89a))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

let top: [UInt32] = [0xff0000, 0xffff00, 0x00ffff]
let bottom: [UInt32] = [0x00ff00, 0xf0f8d0, 0xff8000]
for (i, c) in top.enumerated() {
    roundedRect(CGRect(x: gap + CGFloat(i) * (cell + gap), y: gap, width: cell, height: cell), rgb(c))
}
for (i, c) in bottom.enumerated() {
    roundedRect(CGRect(x: gap + CGFloat(i) * (cell + gap), y: gap * 3 + cell * 2, width: cell, height: cell), rgb(c))
}
let band = CGRect(x: gap, y: gap * 2 + cell, width: CGFloat(size) - gap * 2, height: cell)
roundedRect(band, rgb(0x000000))

// Title, scaled to fill most of the band's width.
let title = "bsTimer" as NSString
let fontName = NSFont(name: "HelveticaNeue-CondensedBlack", size: 100) != nil ? "HelveticaNeue-CondensedBlack" : "Helvetica-Bold"
var font = NSFont(name: fontName, size: 100)!
let width = title.size(withAttributes: [.font: font]).width
font = NSFont(name: fontName, size: 100 * (band.width * 0.86) / width)!
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
let textSize = title.size(withAttributes: attrs)

let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gc
title.draw(at: NSPoint(x: band.midX - textSize.width / 2, y: band.midY - textSize.height / 2), withAttributes: attrs)
NSGraphicsContext.restoreGraphicsState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(outPath)") }
print("wrote \(outPath)")
