#!/usr/bin/env swift
import AppKit
import Foundation

/// Video-call mark on a full-bleed near-white square — same family as Grok / Coin Monitor.
/// macOS applies the squircle mask. Near-white + near-black keep Assets.car RGB (not
/// Monochrome), so IconServices fills edge-to-edge instead of mounting on a gray plate.

/// Classic filled video-camera: rounded body, lens cutout, side snout.
func videoCallPath(in rect: NSRect) -> NSBezierPath {
    let unit = min(rect.width, rect.height) / 16
    let originX = rect.midX - 8 * unit
    let originY = rect.midY - 8 * unit

    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: originX + x * unit, y: originY + y * unit)
    }

    func r(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: originX + x * unit, y: originY + y * unit, width: width * unit, height: height * unit)
    }

    let path = NSBezierPath()
    path.windingRule = .evenOdd

    // Camera body
    let body = NSBezierPath(
        roundedRect: r(1.4, 3.6, 9.4, 8.8),
        xRadius: 1.6 * unit,
        yRadius: 1.6 * unit
    )
    path.append(body)

    // Lens cutout (even-odd → hole)
    path.append(NSBezierPath(ovalIn: r(3.55, 5.75, 4.5, 4.5)))

    // Side viewfinder / snout (overlap body slightly so no hairline seam)
    let snout = NSBezierPath()
    snout.move(to: p(10.15, 5.4))
    snout.line(to: p(14.6, 3.5))
    snout.line(to: p(14.6, 12.5))
    snout.line(to: p(10.15, 10.6))
    snout.close()
    path.append(snout)

    return path
}

func drawIcon(size: Int, path: String) {
    let pixels = CGFloat(size)

    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("Failed to create context for \(size)\n", stderr)
        return
    }

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Full-bleed cool near-white (R≠G≠B → RGB in Assets.car).
    NSColor(srgbRed: 0.995, green: 0.997, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: pixels, height: pixels)).fill()

    let markInset = pixels * 0.16
    let drawRect = NSRect(
        x: markInset,
        y: markInset,
        width: pixels - markInset * 2,
        height: pixels - markInset * 2
    )

    NSColor(srgbRed: 0.02, green: 0.02, blue: 0.04, alpha: 1).setFill()
    videoCallPath(in: drawRect).fill()

    guard let cgImage = ctx.makeImage() else {
        fputs("Failed to make image for \(size)\n", stderr)
        return
    }
    writeOpaquePNG(cgImage, size: size, path: path)
}

/// Flattens to an opaque RGB PNG (no alpha) and writes it to `path`.
func writeOpaquePNG(_ cgImage: CGImage, size: Int, path: String) {
    let pixels = CGFloat(size)
    guard let rgbCtx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fputs("Failed to create opaque context for \(size)\n", stderr)
        return
    }
    rgbCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let opaque = rgbCtx.makeImage() else {
        fputs("Failed to make opaque image for \(size)\n", stderr)
        return
    }

    let rep = NSBitmapImageRep(cgImage: opaque)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed to create PNG data for \(size)\n", stderr)
        return
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("Saved \(path) (\(size)x\(size))")
    } catch {
        fputs("Failed to write \(path): \(error)\n", stderr)
    }
}

let sizes: [(size: Int, name: String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for (pixels, name) in sizes {
    drawIcon(size: pixels, path: "\(outputDir)/\(name).png")
}

print("All icons generated to \(outputDir)")
