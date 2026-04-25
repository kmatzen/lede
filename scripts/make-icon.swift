#!/usr/bin/env swift
// Generates Resources/AppIcon.icns from scratch — a bell glyph on a
// warm gradient rounded square. Replace with a designed icon when you can.
//
// Usage: ./scripts/make-icon.swift  (run from repo root)

import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: "Resources")
let iconsetDir = outDir.appendingPathComponent("AppIcon.iconset")
let icnsURL = outDir.appendingPathComponent("AppIcon.icns")

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func renderIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    defer { image.unlockFocus() }

    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded-square background with a warm linear gradient (sun-fade).
    let radius = s * 0.225
    let path = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
        cornerWidth: radius, cornerHeight: radius, transform: nil
    )
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.99, green: 0.71, blue: 0.36, alpha: 1).cgColor, // top: amber
        NSColor(calibratedRed: 0.93, green: 0.36, blue: 0.27, alpha: 1).cgColor, // bottom: ember
    ] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    ctx.restoreGState()

    // Bell glyph centered (SF Symbol rendered in white).
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: s * 0.55, weight: .semibold)
    let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig)?
        .tinted(.white)
    if let bell {
        let bellSize = bell.size
        let x = (s - bellSize.width) / 2
        let y = (s - bellSize.height) / 2 - s * 0.02 // optical centering nudge
        bell.draw(at: NSPoint(x: x, y: y),
                  from: .zero, operation: .sourceOver, fraction: 1)
    }

    return image
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        rect.fill(using: .sourceOver)
        draw(in: rect, from: rect, operation: .destinationIn, fraction: 1)
        img.unlockFocus()
        return img
    }
    func pngData() -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}

// macOS .iconset naming convention: pairs of (size, suffix) for @1x and @2x.
struct Variant { let size: Int; let name: String }
let variants: [Variant] = [
    .init(size: 16,   name: "icon_16x16.png"),
    .init(size: 32,   name: "icon_16x16@2x.png"),
    .init(size: 32,   name: "icon_32x32.png"),
    .init(size: 64,   name: "icon_32x32@2x.png"),
    .init(size: 128,  name: "icon_128x128.png"),
    .init(size: 256,  name: "icon_128x128@2x.png"),
    .init(size: 256,  name: "icon_256x256.png"),
    .init(size: 512,  name: "icon_256x256@2x.png"),
    .init(size: 512,  name: "icon_512x512.png"),
    .init(size: 1024, name: "icon_512x512@2x.png"),
]

for v in variants {
    let img = renderIcon(size: v.size)
    guard let data = img.pngData() else { continue }
    try data.write(to: iconsetDir.appendingPathComponent(v.name))
}

// Build .icns with Apple's iconutil.
let proc = Process()
proc.launchPath = "/usr/bin/iconutil"
proc.arguments = ["--convert", "icns", iconsetDir.path, "--output", icnsURL.path]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus == 0 {
    print("✓ Wrote \(icnsURL.path)")
} else {
    FileHandle.standardError.write(Data("iconutil failed (\(proc.terminationStatus))\n".utf8))
    exit(1)
}

// Leave the iconset folder in place so subsequent runs are fast and so
// designers can hand-edit individual sizes if they want.
