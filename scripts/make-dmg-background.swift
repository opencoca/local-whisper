#!/usr/bin/env swift
//
// make-dmg-background.swift
//
// One-shot Core Graphics PNG generator for the Sage.is Talking DMG background.
// Output: 540×380 PNG with a soft gradient, "Drag → Applications" guidance,
// and a subtle arrow glyph between the icon positions.
//
// Usage: swift scripts/make-dmg-background.swift assets/dmg_background.png
//
// The generated PNG is committed at `assets/dmg_background.png` and consumed
// by `scripts/release.sh` via `create-dmg --background`. `make setup`
// regenerates the file if it's missing.

import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: \(args[0]) <output.png>\n".utf8))
    exit(2)
}
let outPath = args[1]

// DMG window content area. create-dmg passes window-size 540x380 to Finder;
// the background needs to match that exactly or it tiles/clips.
let width = 540
let height = 380

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("Failed to create CGContext\n".utf8))
    exit(1)
}

// --- Soft off-white linear gradient (top a touch warmer than bottom) ---
let top    = CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1.0)
let bottom = CGColor(red: 0.93, green: 0.93, blue: 0.92, alpha: 1.0)
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [top, bottom] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: CGFloat(height)),
    end:   CGPoint(x: 0, y: 0),
    options: []
)

// --- Subtle horizontal arrow between the two icon slots (140 and 400 at y≈190) ---
// Drawn in coordinates where (0,0) is bottom-left.
let arrowY: CGFloat = 190
let arrowStart = CGPoint(x: 215, y: arrowY)
let arrowEnd   = CGPoint(x: 325, y: arrowY)

ctx.setStrokeColor(CGColor(red: 0.60, green: 0.60, blue: 0.58, alpha: 0.55))
ctx.setLineWidth(2)
ctx.setLineCap(.round)
ctx.move(to: arrowStart)
ctx.addLine(to: arrowEnd)
ctx.strokePath()

// Arrowhead.
let headSize: CGFloat = 8
ctx.move(to: arrowEnd)
ctx.addLine(to: CGPoint(x: arrowEnd.x - headSize, y: arrowEnd.y + headSize * 0.7))
ctx.move(to: arrowEnd)
ctx.addLine(to: CGPoint(x: arrowEnd.x - headSize, y: arrowEnd.y - headSize * 0.7))
ctx.strokePath()

// --- Caption text under the arrow ("Drag → Applications") ---
let caption = "Drag Sage.is Talking to Applications"
let fontSize: CGFloat = 13
let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
    ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
let captionColor = CGColor(red: 0.45, green: 0.45, blue: 0.43, alpha: 1.0)

let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: captionColor,
]
let attributed = NSAttributedString(string: caption, attributes: attrs)
let line = CTLineCreateWithAttributedString(attributed)
let lineBounds = CTLineGetImageBounds(line, ctx)
let textX = (CGFloat(width) - lineBounds.width) / 2
let textY: CGFloat = 130  // below the icons

ctx.textPosition = CGPoint(x: textX, y: textY)
CTLineDraw(line, ctx)

// --- Title/header at the top ---
let title = "Sage.is Talking"
let titleFontSize: CGFloat = 22
let titleFont = CTFontCreateUIFontForLanguage(.system, titleFontSize, nil)
    ?? CTFontCreateWithName("Helvetica-Bold" as CFString, titleFontSize, nil)
let titleColor = CGColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0)

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: titleColor,
]
let titleAttributed = NSAttributedString(string: title, attributes: titleAttrs)
let titleLine = CTLineCreateWithAttributedString(titleAttributed)
let titleBounds = CTLineGetImageBounds(titleLine, ctx)
let titleX = (CGFloat(width) - titleBounds.width) / 2
let titleY: CGFloat = 320

ctx.textPosition = CGPoint(x: titleX, y: titleY)
CTLineDraw(titleLine, ctx)

// --- Save as PNG ---
guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("Failed to make CGImage\n".utf8))
    exit(1)
}

let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(
    at: outURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

guard let dest = CGImageDestinationCreateWithURL(
    outURL as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    FileHandle.standardError.write(Data("Failed to create image destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("Failed to write PNG\n".utf8))
    exit(1)
}

print("Wrote \(outPath) — \(width)×\(height)")
