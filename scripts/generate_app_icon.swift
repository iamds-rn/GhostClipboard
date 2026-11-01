#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

let iconsetPath = "Resources/AppIcon.iconset"
let icnsOutputPath = "Resources/AppIcon.icns"

let fileManager = FileManager.default
try? fileManager.removeItem(atPath: iconsetPath)
try fileManager.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func renderIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = nsCtx
    let cg = nsCtx.cgContext
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)

    // 1. macOS squircle background (#101114 -> #181A20)
    let inset = s * 0.08
    let cardRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = cardRect.width * 0.225
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)

    NSColor(calibratedRed: 0x14 / 255.0, green: 0x16 / 255.0, blue: 0x1C / 255.0, alpha: 1.0).setFill()
    cardPath.fill()

    // Subtle border stroke (#30343D)
    NSColor(calibratedRed: 0x30 / 255.0, green: 0x34 / 255.0, blue: 0x3D / 255.0, alpha: 1.0).setStroke()
    cardPath.lineWidth = max(1.0, s * 0.018)
    cardPath.stroke()

    // 2. Inner clipboard board silhouette (#20232B)
    let boardWidth = cardRect.width * 0.54
    let boardHeight = cardRect.height * 0.62
    let boardRect = CGRect(
        x: (s - boardWidth) / 2.0,
        y: (s - boardHeight) / 2.0 - s * 0.02,
        width: boardWidth,
        height: boardHeight
    )
    let boardPath = NSBezierPath(roundedRect: boardRect, xRadius: s * 0.06, yRadius: s * 0.06)
    NSColor(calibratedRed: 0x20 / 255.0, green: 0x23 / 255.0, blue: 0x2B / 255.0, alpha: 1.0).setFill()
    boardPath.fill()

    // Top clipboard clip tab (#A6B7FF)
    let tabWidth = boardWidth * 0.44
    let tabHeight = s * 0.065
    let tabRect = CGRect(
        x: (s - tabWidth) / 2.0,
        y: boardRect.maxY - tabHeight * 0.45,
        width: tabWidth,
        height: tabHeight
    )
    let tabPath = NSBezierPath(roundedRect: tabRect, xRadius: tabHeight * 0.4, yRadius: tabHeight * 0.4)
    NSColor(calibratedRed: 0xA6 / 255.0, green: 0xB7 / 255.0, blue: 0xFF / 255.0, alpha: 1.0).setFill()
    tabPath.fill()

    // 3. Central Security Shield emblem (#A6B7FF left half + #65C99A right half)
    let shieldW = boardWidth * 0.60
    let shieldH = boardHeight * 0.56
    let cx = s / 2.0
    let cy = boardRect.midY - s * 0.015
    let topY = cy + shieldH * 0.48
    let midY = cy + shieldH * 0.08
    let botY = cy - shieldH * 0.48
    let leftX = cx - shieldW * 0.5
    let rightX = cx + shieldW * 0.5

    let shieldPath = NSBezierPath()
    shieldPath.move(to: NSPoint(x: cx, y: topY))
    shieldPath.line(to: NSPoint(x: rightX, y: topY - shieldH * 0.14))
    shieldPath.line(to: NSPoint(x: rightX, y: midY))
    shieldPath.curve(
        to: NSPoint(x: cx, y: botY),
        controlPoint1: NSPoint(x: rightX, y: cy - shieldH * 0.25),
        controlPoint2: NSPoint(x: cx + shieldW * 0.18, y: botY + shieldH * 0.06)
    )
    shieldPath.curve(
        to: NSPoint(x: leftX, y: midY),
        controlPoint1: NSPoint(x: cx - shieldW * 0.18, y: botY + shieldH * 0.06),
        controlPoint2: NSPoint(x: leftX, y: cy - shieldH * 0.25)
    )
    shieldPath.line(to: NSPoint(x: leftX, y: topY - shieldH * 0.14))
    shieldPath.close()

    NSColor(calibratedRed: 0xA6 / 255.0, green: 0xB7 / 255.0, blue: 0xFF / 255.0, alpha: 1.0).setFill()
    shieldPath.fill()

    // Right-half darker accent inside shield for "shield.lefthalf.filled" aesthetic
    NSGraphicsContext.saveGraphicsState()
    shieldPath.addClip()
    let rightHalfRect = CGRect(x: cx, y: botY, width: shieldW, height: shieldH * 1.2)
    NSColor(calibratedRed: 0x52 / 255.0, green: 0x6D / 255.0, blue: 0xE8 / 255.0, alpha: 1.0).setFill()
    NSBezierPath(rect: rightHalfRect).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for spec in specs {
    if let pngData = renderIcon(size: spec.pixels) {
        let outURL = URL(fileURLWithPath: iconsetPath).appendingPathComponent(spec.name)
        try pngData.write(to: outURL)
    }
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetPath, "-o", icnsOutputPath]
try proc.run()
proc.waitUntilExit()

try? fileManager.removeItem(atPath: iconsetPath)

if proc.terminationStatus == 0 {
    print("Generated native macOS icon at \(icnsOutputPath)")
} else {
    fputs("iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(1)
}
