import AppKit
import CoreGraphics
import Foundation

@MainActor
func writeIcon(pixels: Int, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "PaddockIcon", code: 1)
    }
    let context = graphics.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let space = CGColorSpaceCreateDeviceRGB()
    let tile = CGPath(roundedRect: CGRect(x: 78, y: 78, width: 868, height: 868),
                      cornerWidth: 196, cornerHeight: 196, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                      color: CGColor(gray: 0, alpha: 0.28))
    context.addPath(tile)
    context.setFillColor(CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let surface = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 1),
        CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1),
        CGColor(red: 0.065, green: 0.07, blue: 0.09, alpha: 1)
    ] as CFArray, locations: [0, 0.5, 1])!
    context.drawLinearGradient(surface, start: CGPoint(x: 340, y: 960),
                               end: CGPoint(x: 680, y: 100),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    context.addPath(tile)
    context.setLineWidth(2)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    context.strokePath()

    let monogram = CGMutablePath()
    monogram.move(to: CGPoint(x: 340, y: 268))
    monogram.addLine(to: CGPoint(x: 340, y: 708))
    monogram.addCurve(to: CGPoint(x: 385, y: 752),
                      control1: CGPoint(x: 340, y: 738), control2: CGPoint(x: 355, y: 752))
    monogram.addLine(to: CGPoint(x: 548, y: 752))
    monogram.addCurve(to: CGPoint(x: 698, y: 602),
                      control1: CGPoint(x: 638, y: 752), control2: CGPoint(x: 698, y: 694))
    monogram.addCurve(to: CGPoint(x: 548, y: 452),
                      control1: CGPoint(x: 698, y: 510), control2: CGPoint(x: 638, y: 452))
    monogram.addLine(to: CGPoint(x: 456, y: 452))
    let stroke = monogram.copy(strokingWithWidth: 100, lineCap: .round,
                               lineJoin: .round, miterLimit: 10)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -5), blur: 18,
                      color: CGColor(red: 0.8, green: 0.03, blue: 0.02, alpha: 0.18))
    context.addPath(stroke)
    context.setFillColor(CGColor(red: 0.93, green: 0.16, blue: 0.18, alpha: 1))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(stroke)
    context.clip()
    let red = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 1, green: 0.39, blue: 0.34, alpha: 1),
        CGColor(red: 0.94, green: 0.16, blue: 0.20, alpha: 1),
        CGColor(red: 0.77, green: 0.045, blue: 0.11, alpha: 1)
    ] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(red, start: CGPoint(x: 510, y: 810),
                               end: CGPoint(x: 510, y: 190),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PaddockIcon", code: 2)
    }
    try png.write(to: url, options: .atomic)
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift generate-icon.swift <output.iconset>\n", stderr)
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try writeIcon(pixels: size, to: directory.appendingPathComponent("icon_\(size)x\(size).png"))
    try writeIcon(pixels: size * 2, to: directory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
